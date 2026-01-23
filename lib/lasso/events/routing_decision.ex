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
      source_region: System.get_env("CLUSTER_REGION") || "unknown",
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

  @doc """
  Returns the profile-scoped topic for routing decisions.
  """
  @spec topic(String.t()) :: String.t()
  def topic(profile), do: "routing:decisions:#{profile}"
end
