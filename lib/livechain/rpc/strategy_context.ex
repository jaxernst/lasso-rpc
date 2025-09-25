defmodule Livechain.RPC.StrategyContext do
  @moduledoc """
  Typed context passed to selection strategies after preparation.

  Contains common, strategy-agnostic fields. Individual strategies can
  populate optional fields during their `prepare_context/1` implementation.
  """

  alias Livechain.RPC.SelectionContext

  @enforce_keys [:chain, :now_ms, :timeout]
  defstruct [
    :chain,
    :now_ms,
    :timeout,
    :region_filter,
    # Optional fields populated by strategies
    :total_requests,
    :freshness_cutoff_ms,
    :min_calls,
    :min_success_rate
  ]

  @type t :: %__MODULE__{
          chain: String.t(),
          now_ms: integer(),
          timeout: non_neg_integer(),
          region_filter: String.t() | nil,
          total_requests: non_neg_integer() | nil,
          freshness_cutoff_ms: non_neg_integer() | nil,
          min_calls: non_neg_integer() | nil,
          min_success_rate: float() | nil
        }

  @doc """
  Builds the base strategy context from a validated selection context.
  """
  @spec new(SelectionContext.t()) :: t()
  def new(%SelectionContext{} = selection) do
    %__MODULE__{
      chain: selection.chain,
      now_ms: System.monotonic_time(:millisecond),
      timeout: selection.timeout,
      region_filter: selection.region_filter
    }
  end
end
