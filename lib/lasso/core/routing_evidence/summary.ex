defmodule Lasso.RPC.RoutingEvidence.Summary do
  @moduledoc """
  Immutable routing-evidence summary consumed by performance strategies.

  Storage layout, qualification thresholds, and publication cadence belong to the evidence backend.
  """

  @type state :: :qualified | :unqualified | :provisional | :stale

  @type t :: %__MODULE__{
          upstream_instance_id: String.t(),
          chain_id: pos_integer(),
          transport: :http | :ws,
          workload_key: atom(),
          state: state(),
          comparable_attempts: non_neg_integer(),
          usable_successes: non_neg_integer(),
          successful_mean_latency_ms: number() | nil,
          successful_p95_latency_ms: number() | nil,
          last_observed_at_ms: integer() | nil,
          oldest_observed_at_ms: integer() | nil,
          support_source: atom(),
          generation: non_neg_integer()
        }

  @enforce_keys [
    :upstream_instance_id,
    :chain_id,
    :transport,
    :workload_key,
    :state,
    :support_source,
    :generation
  ]
  defstruct @enforce_keys ++
              [
                comparable_attempts: 0,
                usable_successes: 0,
                successful_mean_latency_ms: nil,
                successful_p95_latency_ms: nil,
                last_observed_at_ms: nil,
                oldest_observed_at_ms: nil
              ]
end
