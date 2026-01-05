defmodule Lasso.Core.Support.ContinuityPolicy do
  @moduledoc """
  Pure helpers to determine backfill requirements and ranges.

  Policies for exceeding max_backfill_blocks can be configured per call.
  """

  @type policy :: :best_effort | :strict_abort | :warn_only

  @spec needed_block_range(integer() | nil, integer(), non_neg_integer(), policy()) ::
          {:none}
          | {:range, pos_integer(), pos_integer()}
          | {:exceeded, pos_integer(), pos_integer()}
  def needed_block_range(last_seen, head, max_backfill_blocks, _policy)
      when is_integer(last_seen) do
    if head <= last_seen + 1 do
      {:none}
    else
      from_n = last_seen + 1
      to_n = min(head, last_seen + max_backfill_blocks)
      if to_n < head, do: {:exceeded, from_n, to_n}, else: {:range, from_n, to_n}
    end
  end

  def needed_block_range(_last_seen, _head, _max, _policy), do: {:none}
end
