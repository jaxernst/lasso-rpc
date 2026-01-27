defmodule Lasso.Events.RoutingDecision do
  @moduledoc """
  Typed struct for routing decision events.

  Published to profile-scoped PubSub topics to enable multi-tenant
  dashboard subscriptions without cross-tenant data leakage.
  """

  @type t :: %__MODULE__{
          ts: pos_integer(),
          request_id: String.t(),
          profile: String.t(),
          source_node: node(),
          source_region: String.t(),
          chain: String.t(),
          method: String.t(),
          strategy: String.t(),
          provider_id: String.t(),
          transport: atom(),
          duration_ms: non_neg_integer(),
          result: :success | :error,
          failover_count: non_neg_integer()
        }

  defstruct [
    :ts,
    :request_id,
    :profile,
    :source_node,
    :source_region,
    :chain,
    :method,
    :strategy,
    :provider_id,
    :transport,
    :duration_ms,
    :result,
    failover_count: 0
  ]

  @doc """
  Creates a new routing decision event.
  """
  @spec new(Keyword.t()) :: t()
  def new(attrs) do
    %__MODULE__{
      ts: attrs[:ts] || System.system_time(:millisecond),
      request_id: attrs[:request_id],
      profile: attrs[:profile] || "default",
      source_node: node(),
      source_region: get_source_region(),
      chain: attrs[:chain],
      method: attrs[:method],
      strategy: to_string(attrs[:strategy]),
      provider_id: attrs[:provider_id],
      transport: attrs[:transport],
      duration_ms: attrs[:duration_ms],
      result: attrs[:result],
      failover_count: attrs[:failover_count] || 0
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
  Returns the profile-scoped topic for routing decisions.
  """
  @spec topic(String.t()) :: String.t()
  def topic(profile), do: "routing:decisions:#{profile}"
end
