defmodule Livechain.EventProcessing.Manager do
  @moduledoc """
  Manager for Broadway event processing pipelines.

  This module provides a high-level interface for managing Broadway pipelines
  across different blockchain networks, handling their lifecycle and providing
  status information.
  """

  use GenServer
  require Logger

  defstruct [
    :pipelines,
    :stats
  ]

  @doc """
  Starts the EventProcessing Manager.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts a Broadway pipeline for a specific chain.
  """
  def start_pipeline(chain_name) do
    GenServer.call(__MODULE__, {:start_pipeline, chain_name})
  end

  @doc """
  Stops a Broadway pipeline for a specific chain.
  """
  def stop_pipeline(chain_name) do
    GenServer.call(__MODULE__, {:stop_pipeline, chain_name})
  end

  @doc """
  Gets the status of all running pipelines.
  """
  def get_pipeline_status do
    GenServer.call(__MODULE__, :get_pipeline_status)
  end

  @doc """
  Gets processing statistics for all pipelines.
  """
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    Logger.info("Starting EventProcessing Manager")

    # Subscribe to analytics metrics to track pipeline performance
    Phoenix.PubSub.subscribe(Livechain.PubSub, "analytics:metrics")

    state = %__MODULE__{
      pipelines: %{},
      stats: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:start_pipeline, chain_name}, _from, state) do
    case Map.get(state.pipelines, chain_name) do
      nil ->
        case start_broadway_pipeline(chain_name) do
          {:ok, pid} ->
            new_pipelines =
              Map.put(state.pipelines, chain_name, %{
                pid: pid,
                started_at: System.system_time(:millisecond),
                status: :running
              })

            new_state = %{state | pipelines: new_pipelines}

            Logger.info("Started Broadway pipeline for #{chain_name}")
            {:reply, {:ok, pid}, new_state}

          {:error, reason} ->
            Logger.error("Failed to start Broadway pipeline for #{chain_name}: #{reason}")
            {:reply, {:error, reason}, state}
        end

      %{status: :running} ->
        {:reply, {:error, :already_running}, state}

      %{status: :stopped} ->
        # Restart stopped pipeline
        case start_broadway_pipeline(chain_name) do
          {:ok, pid} ->
            updated_pipeline = %{
              pid: pid,
              started_at: System.system_time(:millisecond),
              status: :running
            }

            new_pipelines = Map.put(state.pipelines, chain_name, updated_pipeline)
            new_state = %{state | pipelines: new_pipelines}

            {:reply, {:ok, pid}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:stop_pipeline, chain_name}, _from, state) do
    case Map.get(state.pipelines, chain_name) do
      nil ->
        {:reply, {:error, :not_running}, state}

      %{pid: pid, status: :running} ->
        case stop_broadway_pipeline(pid) do
          :ok ->
            updated_pipeline = Map.put(state.pipelines[chain_name], :status, :stopped)
            new_pipelines = Map.put(state.pipelines, chain_name, updated_pipeline)
            new_state = %{state | pipelines: new_pipelines}

            Logger.info("Stopped Broadway pipeline for #{chain_name}")
            {:reply, :ok, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      %{status: :stopped} ->
        {:reply, {:error, :already_stopped}, state}
    end
  end

  @impl true
  def handle_call(:get_pipeline_status, _from, state) do
    status =
      state.pipelines
      |> Enum.map(fn {chain_name, pipeline_info} ->
        %{
          chain: chain_name,
          status: pipeline_info.status,
          started_at: pipeline_info.started_at,
          uptime_ms:
            if(pipeline_info.status == :running,
              do: System.system_time(:millisecond) - pipeline_info.started_at,
              else: 0
            ),
          stats: Map.get(state.stats, chain_name, %{})
        }
      end)

    {:reply, status, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    {:reply, state.stats, state}
  end

  @impl true
  def handle_info({:metrics_batch, metrics}, state) do
    # Update pipeline statistics from metrics
    new_stats =
      Enum.reduce(metrics, state.stats, fn metric, acc_stats ->
        # Extract chain from metric context if available
        chain = Map.get(metric, :chain, "unknown")

        current_chain_stats =
          Map.get(acc_stats, chain, %{
            events_processed: 0,
            total_usd_value: 0.0,
            last_updated: 0
          })

        updated_chain_stats = %{
          current_chain_stats
          | events_processed: current_chain_stats.events_processed + Map.get(metric, :count, 0),
            total_usd_value:
              current_chain_stats.total_usd_value + Map.get(metric, :total_usd_value, 0.0),
            last_updated: System.system_time(:millisecond)
        }

        Map.put(acc_stats, chain, updated_chain_stats)
      end)

    {:noreply, %{state | stats: new_stats}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    # Handle pipeline process crashes
    crashed_chain =
      state.pipelines
      |> Enum.find(fn {_chain, info} -> info.pid == pid end)

    case crashed_chain do
      {chain_name, _info} ->
        Logger.error("Broadway pipeline for #{chain_name} crashed: #{reason}")

        updated_pipeline = %{
          pid: nil,
          started_at: 0,
          status: :crashed,
          crash_reason: reason,
          crashed_at: System.system_time(:millisecond)
        }

        new_pipelines = Map.put(state.pipelines, chain_name, updated_pipeline)
        new_state = %{state | pipelines: new_pipelines}

        # Optionally restart automatically
        if should_auto_restart?(reason) do
          Logger.info("Auto-restarting Broadway pipeline for #{chain_name}")
          send(self(), {:restart_pipeline, chain_name})
        end

        {:noreply, new_state}

      nil ->
        Logger.warning("Unknown process crashed: #{inspect(pid)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:restart_pipeline, chain_name}, state) do
    # Auto-restart crashed pipeline
    case start_broadway_pipeline(chain_name) do
      {:ok, pid} ->
        updated_pipeline = %{
          pid: pid,
          started_at: System.system_time(:millisecond),
          status: :running
        }

        new_pipelines = Map.put(state.pipelines, chain_name, updated_pipeline)
        new_state = %{state | pipelines: new_pipelines}

        Logger.info("Successfully restarted Broadway pipeline for #{chain_name}")
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("Failed to restart Broadway pipeline for #{chain_name}: #{reason}")
        {:noreply, state}
    end
  end

  # Private functions

  defp start_broadway_pipeline(chain_name) do
    DynamicSupervisor.start_child(
      Livechain.EventProcessing.Supervisor,
      {Livechain.EventProcessing.Pipeline, chain_name}
    )
  end

  defp stop_broadway_pipeline(pid) when is_pid(pid) do
    try do
      DynamicSupervisor.terminate_child(Livechain.EventProcessing.Supervisor, pid)
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp should_auto_restart?(reason) do
    # Auto-restart for certain types of crashes
    case reason do
      :normal -> false
      :shutdown -> false
      {:shutdown, _} -> false
      # Restart for unexpected crashes
      _ -> true
    end
  end
end
