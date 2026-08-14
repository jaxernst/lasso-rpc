defmodule Lasso.Core.Support.CircuitBreaker.Snapshot do
  @moduledoc false

  alias Lasso.Core.Support.CircuitBreaker.Storage

  @type circuit_state :: :closed | :open | :half_open
  @type control_health :: :healthy | :degraded

  @enforce_keys [
    :breaker_id,
    :state,
    :generation,
    :epoch,
    :owner_pid,
    :ready?,
    :recovery_deadline_us,
    :half_open_capacity,
    :half_open_inflight,
    :control_health
  ]
  defstruct @enforce_keys ++
              [failure_count: 0, needs_success?: false]

  @type t :: %__MODULE__{
          breaker_id: {String.t(), :http | :ws},
          state: circuit_state(),
          generation: non_neg_integer(),
          epoch: pos_integer(),
          owner_pid: pid(),
          ready?: boolean(),
          recovery_deadline_us: integer() | nil,
          half_open_capacity: pos_integer(),
          half_open_inflight: non_neg_integer(),
          control_health: control_health(),
          failure_count: non_neg_integer(),
          needs_success?: boolean()
        }

  @spec lookup({String.t(), :http | :ws}) :: {:ok, t()} | :missing
  def lookup(breaker_id) do
    case :ets.lookup(Storage.snapshot_table(), breaker_id) do
      [{^breaker_id, %__MODULE__{} = snapshot}] -> {:ok, snapshot}
      _ -> :missing
    end
  end

  @spec put(t()) :: true
  def put(%__MODULE__{breaker_id: breaker_id} = snapshot) do
    :ets.insert(Storage.snapshot_table(), {breaker_id, snapshot})
  end
end
