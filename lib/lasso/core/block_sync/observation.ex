defmodule Lasso.BlockSync.Observation do
  @moduledoc """
  Reads block-height evidence under the instance's effective freshness contract.
  """

  alias Lasso.BlockSync.{Registry, Worker}

  @default_stale_after_ms 60_000

  @type t :: %{
          height: non_neg_integer(),
          observed_at_ms: integer(),
          source: :http | :ws,
          metadata: map(),
          stale_after_ms: pos_integer(),
          age_ms: non_neg_integer()
        }

  @spec read(pos_integer(), String.t(), integer()) ::
          {:ok, t()} | {:error, :not_found | {:stale, t()}}
  def read(chain_id, instance_id, now_ms \\ System.system_time(:millisecond))
      when is_integer(chain_id) and chain_id > 0 and is_binary(instance_id) and
             is_integer(now_ms) do
    case Registry.get_height(chain_id, instance_id) do
      {:ok, {height, observed_at_ms, source, metadata}} ->
        stale_after_ms =
          case Map.get(metadata, :stale_after_ms) do
            value when is_integer(value) and value > 0 -> value
            _missing_or_invalid -> stale_after_ms(instance_id, chain_id, source)
          end

        observation = %{
          height: height,
          observed_at_ms: observed_at_ms,
          source: source,
          metadata: metadata,
          stale_after_ms: stale_after_ms,
          age_ms: max(0, now_ms - observed_at_ms)
        }

        if fresh?(observation, now_ms),
          do: {:ok, observation},
          else: {:error, {:stale, observation}}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @spec fresh?(map(), integer()) :: boolean()
  def fresh?(observation, now_ms \\ System.system_time(:millisecond))
      when is_map(observation) and is_integer(now_ms) do
    observed_at_ms = Map.get(observation, :observed_at_ms, Map.get(observation, :timestamp))
    stale_after_ms = Map.get(observation, :stale_after_ms, @default_stale_after_ms)

    is_integer(observed_at_ms) and is_integer(stale_after_ms) and stale_after_ms > 0 and
      now_ms - observed_at_ms <= stale_after_ms
  end

  @spec stale_after_ms(String.t(), pos_integer(), :http | :ws | nil) :: pos_integer()
  def stale_after_ms(instance_id, chain_id, source \\ nil)
      when is_binary(instance_id) and is_integer(chain_id) and chain_id > 0 and
             source in [:http, :ws, nil] do
    config = Worker.load_config(instance_id, chain_id)

    poll_window_ms =
      positive(Map.get(config, :poll_interval_ms), div(@default_stale_after_ms, 3)) * 3

    new_heads_window_ms =
      positive(Map.get(config, :staleness_threshold_ms), @default_stale_after_ms)

    case source do
      :http -> poll_window_ms
      :ws -> new_heads_window_ms
      nil -> max(poll_window_ms, new_heads_window_ms)
    end
  rescue
    _error -> @default_stale_after_ms
  catch
    :exit, _reason -> @default_stale_after_ms
  end

  defp positive(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive(_value, fallback), do: fallback
end
