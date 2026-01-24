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
      source_region: Application.get_env(:lasso, :cluster_region) || "unknown",
      chain: attrs[:chain],
      provider_id: attrs[:provider_id],
      transport: attrs[:transport],
      status: attrs[:status],
      previous_status: attrs[:previous_status],
      reason: attrs[:reason],
      latency_ms: attrs[:latency_ms]
    }
  end

  @doc """
  Returns the profile-scoped topic for provider health events.
  """
  @spec topic(String.t()) :: String.t()
  def topic(profile), do: "provider_health:#{profile}"
end
