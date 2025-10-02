defmodule LassoWeb.Dashboard.Helpers do
  @moduledoc """
  General utility functions for the Dashboard LiveView.
  """

  @doc "Convert various number types to float"
  def to_float(value) when is_integer(value), do: value * 1.0
  def to_float(value) when is_float(value), do: value
  def to_float(_), do: 0.0

  @doc "Convert bytes to megabytes"
  def to_mb(bytes) when is_integer(bytes), do: Float.round(bytes / 1_048_576, 1)
  def to_mb(_), do: 0.0

  @doc "Format timestamp relative to current time"
  def format_timestamp(nil), do: "now"

  def format_timestamp(timestamp) when is_integer(timestamp) do
    now = System.system_time(:millisecond)
    diff = now - timestamp

    cond do
      diff < 1000 -> "now"
      diff < 60_000 -> "#{div(diff, 1000)}s ago"
      diff < 3_600_000 -> "#{div(diff, 60_000)}m ago"
      true -> "#{div(diff, 3_600_000)}h ago"
    end
  end

  def format_timestamp(_), do: "unknown"

  @doc "Format last seen timestamp"
  def format_last_seen(nil), do: "Never"

  def format_last_seen(timestamp) when is_integer(timestamp) and timestamp > 0 do
    case DateTime.from_unix(timestamp, :millisecond) do
      {:ok, datetime} -> datetime |> DateTime.to_time() |> to_string()
      {:error, _} -> "Invalid"
    end
  end

  def format_last_seen(_), do: "Unknown"

  @doc "Calculate percentiles for a list of values"
  def percentile_pair(values) when is_list(values) do
    sorted = Enum.sort(values)
    n = length(sorted)

    if n == 0 do
      {nil, nil}
    else
      p50 = percentile(sorted, 0.5)
      p95 = percentile(sorted, 0.95)
      {Float.round(p50, 1), Float.round(p95, 1)}
    end
  end

  @doc "Calculate a specific percentile from sorted values"
  def percentile([], _p), do: 0.0

  def percentile(sorted_values, p) do
    n = length(sorted_values)
    r = p * (n - 1)
    lower = :math.floor(r) |> trunc()
    upper = :math.ceil(r) |> trunc()

    if lower == upper do
      Enum.at(sorted_values, lower) * 1.0
    else
      lower_val = Enum.at(sorted_values, lower) * 1.0
      upper_val = Enum.at(sorted_values, upper) * 1.0
      frac = r - lower
      lower_val + frac * (upper_val - lower_val)
    end
  end

  @doc "Get the most recent routing decision for a chain or provider"
  def get_last_decision(routing_events, chain_name, provider_id \\ nil) do
    Enum.find(routing_events, fn e ->
      cond do
        provider_id -> e[:provider_id] == provider_id
        chain_name -> e[:chain] == chain_name
        true -> false
      end
    end)
  end

  @doc "Get chain ID from chain name using config"
  def get_chain_id(chain_name) do
    case Lasso.Config.ChainConfig.load_config() do
      {:ok, config} ->
        case Map.get(config.chains, chain_name) do
          %{chain_id: chain_id} -> to_string(chain_id)
          _ -> chain_name
        end

      _ ->
        chain_name
    end
  end

  @doc "Get available chains from configuration"
  def get_available_chains do
    case Lasso.Config.ChainConfig.load_config() do
      {:ok, config} ->
        config.chains
        |> Enum.map(fn {chain_name, chain_config} ->
          %{
            id: to_string(chain_config.chain_id),
            name: chain_name,
            display_name: chain_config.name
          }
        end)

      {:error, _} ->
        # Fallback to hardcoded values if config loading fails
        [
          %{id: "1", name: "ethereum", display_name: "Ethereum Mainnet"}
        ]
    end
  end

  @doc "Create a unified event structure"
  def as_event(kind, opts) when is_list(opts) do
    now_ms = System.system_time(:millisecond)

    %{
      id: System.unique_integer([:positive]),
      kind: kind,
      ts: DateTime.utc_now() |> DateTime.to_time() |> to_string(),
      ts_ms: now_ms,
      chain: Keyword.get(opts, :chain),
      provider_id: Keyword.get(opts, :provider_id),
      severity: Keyword.get(opts, :severity, :info),
      message: Keyword.get(opts, :message),
      meta: Keyword.get(opts, :meta, %{})
    }
  end

  @doc "Get strategy description"
  def get_strategy_description(strategy) do
    case strategy do
      "fastest" ->
        "Routes to the provider with lowest average latency based on real-time benchmarks"

      "leaderboard" ->
        "Uses racing-based performance scores to select the best provider"

      "priority" ->
        "Routes by configured provider priority order"

      "round-robin" ->
        "Distributes load evenly across all available providers"

      _ ->
        "Smart routing based on performance metrics"
    end
  end
end
