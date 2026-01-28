defmodule Lasso.Events.CircuitEvent do
  @moduledoc """
  Typed struct for circuit breaker state change events.

  Published to profile-scoped PubSub topics for dashboard updates.
  """

  @type state :: :closed | :open | :half_open

  @type t :: %__MODULE__{
          ts: pos_integer(),
          profile: String.t(),
          source_node: node(),
          source_region: String.t(),
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
    :source_region,
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
      source_region: get_source_region(),
      chain: attrs[:chain],
      provider_id: attrs[:provider_id],
      transport: attrs[:transport],
      from: attrs[:from],
      to: attrs[:to],
      reason: attrs[:reason],
      error: attrs[:error]
    }
  end

  defp get_source_region do
    Lasso.Cluster.Topology.get_self_region()
  end

  @doc """
  Returns the profile-scoped topic for circuit events.
  """
  @spec topic(String.t()) :: String.t()
  def topic(profile), do: "circuit:events:#{profile}"
end
