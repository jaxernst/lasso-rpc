defmodule Lasso.Core.Support.CircuitBreaker.AdmissionReceipt do
  @moduledoc false

  @enforce_keys [:breaker_id, :kind, :generation, :epoch, :owner_pid]
  defstruct @enforce_keys ++ [token: nil, deadline_us: nil]

  @type kind :: :closed | :half_open | :legacy
  @type t :: %__MODULE__{
          breaker_id: {String.t(), :http | :ws},
          kind: kind(),
          generation: non_neg_integer(),
          epoch: pos_integer(),
          owner_pid: pid(),
          token: binary() | reference() | nil,
          deadline_us: integer() | nil
        }
end
