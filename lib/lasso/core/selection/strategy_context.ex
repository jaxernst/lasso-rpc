defmodule Lasso.RPC.StrategyContext do
  @moduledoc """
  Typed context passed to selection strategies after preparation.

  Contains common, strategy-agnostic fields. Individual strategies can
  populate optional fields during their `prepare_context/1` implementation.
  """

  @enforce_keys [:chain_id, :now_ms, :timeout]
  defstruct [
    :chain_id,
    :now_ms,
    :timeout,
    workload_key: :default
  ]

  @type t :: %__MODULE__{
          chain_id: pos_integer(),
          now_ms: integer(),
          timeout: non_neg_integer(),
          workload_key: atom()
        }

  @doc """
  Builds the base strategy context.
  """
  @spec new(pos_integer(), non_neg_integer()) :: t()
  def new(chain_id, timeout) when is_integer(chain_id) and chain_id > 0 and is_integer(timeout) do
    %__MODULE__{
      chain_id: chain_id,
      now_ms: System.monotonic_time(:millisecond),
      timeout: timeout
    }
  end
end
