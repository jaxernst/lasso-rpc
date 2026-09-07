defmodule Lasso.Benchmarking.Persistence do
  @moduledoc """
  Stores hourly benchmark snapshots as JSON files for historical analysis.

  Snapshots are grouped by profile and chain under a directory selected at
  build time by `LASSO_SNAPSHOTS_DIR` (default: `priv/benchmark_snapshots`).
  Configure a persistent volume to
  retain them across container replacements.
  """

  require Logger

  @snapshots_dir System.get_env("LASSO_SNAPSHOTS_DIR") || "priv/benchmark_snapshots"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Saves a performance snapshot to file storage.
  """
  @spec save_snapshot(String.t(), String.t(), map()) :: :ok
  def save_snapshot(profile, chain_name, snapshot_data) do
    GenServer.cast(__MODULE__, {:save_snapshot, profile, chain_name, snapshot_data})
  end

  @doc """
  Loads historical snapshots for a profile and chain within a time range.
  """
  @spec load_snapshots(String.t(), String.t(), non_neg_integer()) :: [map()]
  def load_snapshots(profile, chain_name, hours_back \\ 24) do
    GenServer.call(__MODULE__, {:load_snapshots, profile, chain_name, hours_back})
  end

  @doc """
  Gets a summary of available snapshot data.
  """
  @spec get_snapshot_summary() :: map()
  def get_snapshot_summary do
    GenServer.call(__MODULE__, :get_summary)
  end

  @doc """
  Cleans up old snapshot files (older than specified days).
  """
  @spec cleanup_old_snapshots(non_neg_integer()) :: :ok
  def cleanup_old_snapshots(days_to_keep \\ 7) do
    GenServer.cast(__MODULE__, {:cleanup_snapshots, days_to_keep})
  end

  # GenServer callbacks

  use GenServer

  @impl true
  def init(_opts) do
    File.mkdir_p!(@snapshots_dir)
    schedule_cleanup()

    {:ok, %{}}
  end

  @impl true
  def handle_cast({:save_snapshot, profile, chain_name, snapshot_data}, state) do
    timestamp = System.system_time(:second)
    filename = "#{profile}_#{chain_name}_#{timestamp}.json"
    filepath = Path.join(@snapshots_dir, filename)

    snapshot_with_metadata = %{
      profile: profile,
      chain_name: chain_name,
      timestamp: timestamp,
      datetime: DateTime.utc_now() |> DateTime.to_iso8601(),
      data: snapshot_data
    }

    case Jason.encode(snapshot_with_metadata, pretty: true) do
      {:ok, json_data} ->
        case File.write(filepath, json_data) do
          :ok ->
            Logger.debug("Saved benchmark snapshot: #{filename}")

          {:error, reason} ->
            Logger.error("Failed to save benchmark snapshot #{filename}: #{reason}")
        end

      {:error, reason} ->
        Logger.error("Failed to encode benchmark snapshot: #{reason}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:cleanup_snapshots, days_to_keep}, state) do
    cutoff_timestamp = System.system_time(:second) - days_to_keep * 24 * 60 * 60

    case File.ls(@snapshots_dir) do
      {:ok, files} ->
        files_to_delete =
          files
          |> Enum.filter(fn filename ->
            case extract_timestamp_from_filename(filename) do
              {:ok, timestamp} -> timestamp < cutoff_timestamp
              _ -> false
            end
          end)

        Enum.each(files_to_delete, fn filename ->
          filepath = Path.join(@snapshots_dir, filename)

          case File.rm(filepath) do
            :ok ->
              Logger.debug("Deleted old snapshot: #{filename}")

            {:error, reason} ->
              Logger.error("Failed to delete old snapshot #{filename}: #{reason}")
          end
        end)

        if files_to_delete != [] do
          Logger.info("Cleaned up #{length(files_to_delete)} old benchmark snapshots")
        end

      {:error, reason} ->
        Logger.error("Failed to list snapshot files: #{reason}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:load_snapshots, profile, chain_name, hours_back}, _from, state) do
    cutoff_timestamp = System.system_time(:second) - hours_back * 60 * 60

    snapshots =
      case File.ls(@snapshots_dir) do
        {:ok, files} ->
          files
          |> Enum.filter(fn filename ->
            String.starts_with?(filename, "#{profile}_#{chain_name}_") and
              String.ends_with?(filename, ".json")
          end)
          |> Enum.map(&load_snapshot_file(&1, cutoff_timestamp))
          |> Enum.filter(&(&1 != nil))
          |> Enum.map(fn {:ok, data} -> data end)
          |> Enum.sort_by(fn data -> Map.get(data, "timestamp", 0) end, :desc)

        {:error, reason} ->
          Logger.error("Failed to list snapshot files: #{reason}")
          []
      end

    {:reply, snapshots, state}
  end

  @impl true
  def handle_call(:get_summary, _from, state) do
    summary =
      case File.ls(@snapshots_dir) do
        {:ok, files} ->
          json_files = Enum.filter(files, &String.ends_with?(&1, ".json"))

          chains =
            json_files
            |> Enum.map(&extract_chain_from_filename/1)
            |> Enum.filter(&(&1 != nil))
            |> Enum.uniq()

          oldest_timestamp =
            json_files
            |> Enum.map(&extract_timestamp_from_filename/1)
            |> Enum.filter(fn
              {:ok, _} -> true
              _ -> false
            end)
            |> Enum.map(fn {:ok, ts} -> ts end)
            |> case do
              [] -> nil
              timestamps -> Enum.min(timestamps)
            end

          %{
            total_snapshots: length(json_files),
            chains_tracked: chains,
            oldest_snapshot: oldest_timestamp,
            storage_directory: @snapshots_dir
          }

        {:error, reason} ->
          Logger.error("Failed to get snapshot summary: #{reason}")
          %{error: reason}
      end

    {:reply, summary, state}
  end

  @impl true
  def handle_info(:periodic_cleanup, state) do
    # Run cleanup every 6 hours
    GenServer.cast(__MODULE__, {:cleanup_snapshots, 7})
    schedule_cleanup()
    {:noreply, state}
  end

  # Private functions

  defp load_snapshot_file(filename, cutoff_timestamp) do
    filepath = Path.join(@snapshots_dir, filename)

    case File.read(filepath) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} ->
            if Map.get(data, "timestamp", 0) >= cutoff_timestamp do
              {:ok, data}
            else
              nil
            end

          {:error, _} ->
            Logger.warning("Failed to decode snapshot file: #{filename}")
            nil
        end

      {:error, _} ->
        Logger.warning("Failed to read snapshot file: #{filename}")
        nil
    end
  end

  defp extract_timestamp_from_filename(filename) do
    case String.split(filename, "_") do
      [_profile, _chain, timestamp_str] ->
        timestamp_str
        |> String.replace(".json", "")
        |> String.to_integer()
        |> then(&{:ok, &1})

      _ ->
        {:error, :invalid_format}
    end
  rescue
    _ -> {:error, :parse_error}
  end

  defp extract_chain_from_filename(filename) do
    case String.split(filename, "_") do
      [_profile, chain, _timestamp] -> chain
      _ -> nil
    end
  end

  defp schedule_cleanup do
    # Clean up every 6 hours
    Process.send_after(__MODULE__, :periodic_cleanup, 6 * 60 * 60 * 1000)
  end
end
