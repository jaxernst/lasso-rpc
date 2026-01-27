defmodule Lasso.Events.ProviderHealthEvent do
  @moduledoc """
  Typed struct for provider health status change events.

  Published to profile-scoped PubSub topics for dashboard updates.
  """

  @type health_status :: :healthy | :unhealthy | :degraded | :unknown

  @type t :: %__MODULE__{
          ts: pos_integer(),
          profile: String.t(),
          source_node: node(),
          source_region: String.t(),
          chain: String.t(),
          provider_id: String.t(),
          transport: atom(),
          status: health_status(),
          previous_status: health_status() | nil,
          reason: String.t() | nil,
          latency_ms: non_neg_integer() | nil
        }

  defstruct [
    :ts,
    :profile,
    :source_node,
    :source_region,
    :chain,
    :provider_id,
    :transport,
    :status,
    :previous_status,
    :reason,
    :latency_ms
  ]

  @doc """
  Creates a new provider health event.
  """
  @spec new(Keyword.t()) :: t()
  def new(attrs) do
    %__MODULE__{
      ts: attrs[:ts] || System.system_time(:millisecond),
      profile: attrs[:profile] || "default",
      source_node: node(),
      source_region: get_source_region(),
      chain: attrs[:chain],
      provider_id: attrs[:provider_id],
      transport: attrs[:transport],
      status: attrs[:status],
      previous_status: attrs[:previous_status],
      reason: attrs[:reason],
      latency_ms: attrs[:latency_ms]
    }
  end

  defp get_source_region do
    case Application.get_env(:lasso, :cluster_region) do
      region when is_binary(region) and region != "" -> region
      _ -> generate_node_id()
    end
  end

  defp generate_node_id do
    # Extract hostname portion (after @) for region identification
    # Must match Topology.generate_node_id/0 and BenchmarkStore.extract_region_from_node/0
    node()
    |> Atom.to_string()
    |> String.split("@")
    |> List.last()
    |> case do
      nil -> "unknown"
      "" -> "unknown"
      region -> region
    end
  end

  @doc """
  Returns the profile-scoped topic for provider health events.
  """
  @spec topic(String.t()) :: String.t()
  def topic(profile), do: "provider_health:#{profile}"
end
