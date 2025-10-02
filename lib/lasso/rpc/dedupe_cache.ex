defmodule Lasso.RPC.DedupeCache do
  @moduledoc """
  Bounded, O(1) membership deduplication cache with optional time-based eviction.

  Stores generic items (terms) in a MapSet alongside a map of insertion timestamps.
  Maintains a compact queue of insertion order keys to support LRU-like trimming.

  Eviction policy:
  - Limit by max_items (drop oldest first)
  - Optionally evict items older than max_age_ms during periodic cleanup

  All operations are side-effect free and return updated struct for state threading.
  """

  @enforce_keys [:items, :timestamps, :order, :max_items, :max_age_ms]
  defstruct items: MapSet.new(),
            timestamps: %{},
            order: :queue.new(),
            max_items: 256,
            max_age_ms: 30_000

  @type t :: %__MODULE__{
          items: MapSet.t(),
          timestamps: %{optional(term()) => non_neg_integer()},
          order: :queue.queue(),
          max_items: pos_integer(),
          max_age_ms: non_neg_integer()
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      items: MapSet.new(),
      timestamps: %{},
      order: :queue.new(),
      max_items: Keyword.get(opts, :max_items, 256),
      max_age_ms: Keyword.get(opts, :max_age_ms, 30_000)
    }
  end

  @spec member?(t(), term()) :: boolean()
  def member?(%__MODULE__{items: items}, item), do: MapSet.member?(items, item)

  @spec put(t(), term(), non_neg_integer()) :: t()
  def put(cache = %__MODULE__{}, item, now_ms) do
    if MapSet.member?(cache.items, item) do
      cache
    else
      cache
      |> do_put(item, now_ms)
      |> trim_overflow()
    end
  end

  @spec cleanup(t(), non_neg_integer()) :: t()
  def cleanup(cache = %__MODULE__{max_age_ms: max_age}, now_ms) when max_age > 0 do
    expire_before = now_ms - max_age
    remove_while_old(cache, expire_before)
  end

  def cleanup(cache, _now_ms), do: cache

  # Internal helpers

  defp do_put(cache, item, now_ms) do
    %__MODULE__{
      cache
      | items: MapSet.put(cache.items, item),
        timestamps: Map.put(cache.timestamps, item, now_ms),
        order: :queue.in(item, cache.order)
    }
  end

  defp trim_overflow(
         cache = %__MODULE__{items: items, order: order, timestamps: ts, max_items: max}
       )
       when max > 0 do
    if MapSet.size(items) <= max do
      cache
    else
      case :queue.out(order) do
        {{:value, oldest}, new_order} ->
          if MapSet.member?(items, oldest) do
            %__MODULE__{
              cache
              | items: MapSet.delete(items, oldest),
                timestamps: Map.delete(ts, oldest),
                order: new_order
            }
            |> trim_overflow()
          else
            # Should not happen often; continue popping until size within bounds
            %__MODULE__{cache | order: new_order} |> trim_overflow()
          end

        {:empty, _} ->
          cache
      end
    end
  end

  defp remove_while_old(
         cache = %__MODULE__{order: order, timestamps: ts, items: items},
         expire_before
       ) do
    case :queue.out(order) do
      {{:value, item}, new_order} ->
        case Map.get(ts, item) do
          nil ->
            remove_while_old(%__MODULE__{cache | order: new_order}, expire_before)

          inserted when inserted < expire_before ->
            cache1 = %__MODULE__{
              cache
              | items: MapSet.delete(items, item),
                timestamps: Map.delete(ts, item),
                order: new_order
            }

            remove_while_old(cache1, expire_before)

          _recent ->
            # Put back and stop; order beyond this should be newer
            %__MODULE__{cache | order: :queue.in_r(item, new_order)}
        end

      {:empty, _} ->
        cache
    end
  end
end
