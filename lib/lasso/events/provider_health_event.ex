defmodule Lasso.Events.ProviderHealthEvent do
  @moduledoc """
  Typed struct for provider health status change events.

  Published to profile-scoped PubSub topics for dashboard updates.

  ## Event Source Fields

  - `source_node` - Erlang node atom (e.g., `:"lasso@iad.internal"`), opaque identifier
  - `source_node_id` - Human-readable node identity label (e.g., `"iad"`, `"us-east-1"`),
    set via `LASSO_NODE_ID` env var. Used for state partitioning and dashboard filtering.
  """

  @type health_status :: :healthy | :unhealthy | :degraded | :unknown

  @type t :: %__MODULE__{
          ts: pos_integer(),
          profile: String.t(),
          source_node: node(),
          source_node_id: String.t(),
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
    :source_node_id,
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
      source_node_id: get_source_node_id(),
      chain: attrs[:chain],
      provider_id: attrs[:provider_id],
      transport: attrs[:transport],
      status: attrs[:status],
      previous_status: attrs[:previous_status],
      reason: attrs[:reason],
      latency_ms: attrs[:latency_ms]
    }
  end

  defp get_source_node_id do
    Lasso.Cluster.Topology.get_self_node_id()
  end

  @doc """
  Returns the profile-scoped topic for provider health events.
  """
  @spec topic(String.t()) :: String.t()
  def topic(profile), do: "provider_health:#{profile}"
end
