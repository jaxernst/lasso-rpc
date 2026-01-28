defmodule Lasso.Events.CircuitEvent do
  @moduledoc """
  Typed struct for circuit breaker state change events.

  Published to profile-scoped PubSub topics for dashboard updates.

  ## Event Source Fields

  - `source_node` - Erlang node atom (e.g., `:"lasso@iad.internal"`), opaque identifier
  - `source_node_id` - Human-readable node identity label (e.g., `"iad"`, `"us-east-1"`),
    set via `LASSO_NODE_ID` env var. Used for state partitioning and dashboard filtering.
  """

  @type state :: :closed | :open | :half_open

  @type t :: %__MODULE__{
          ts: pos_integer(),
          profile: String.t(),
          source_node: node(),
          source_node_id: String.t(),
          chain: String.t(),
          provider_id: String.t(),
          transport: atom(),
          from: state(),
          to: state(),
          reason: atom(),
          error: map() | nil
        }

  defstruct [
    :ts,
    :profile,
    :source_node,
    :source_node_id,
    :chain,
    :provider_id,
    :transport,
    :from,
    :to,
    :reason,
    :error
  ]

  @doc """
  Creates a new circuit event.
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
      from: attrs[:from],
      to: attrs[:to],
      reason: attrs[:reason],
      error: attrs[:error]
    }
  end

  defp get_source_node_id do
    Lasso.Cluster.Topology.get_self_node_id()
  end

  @doc """
  Returns the profile-scoped topic for circuit events.
  """
  @spec topic(String.t()) :: String.t()
  def topic(profile), do: "circuit:events:#{profile}"
end
