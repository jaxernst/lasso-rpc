defmodule Lasso.BlockSync.ObservationProjection do
  @moduledoc """
  Time-aligns block observations before comparing them with newer evidence.

  A raw height describes a provider at its observation time. Comparing an older
  HTTP sample directly with a streaming head creates false lag on fast chains.
  Fresh HTTP samples therefore receive bounded advancement credit for elapsed
  time. WebSocket observations remain direct evidence and receive no inferred
  advancement. A projection never advances past an observed reference height.
  """

  @type projection :: %{
          raw_height: integer() | nil,
          height: integer() | nil,
          raw_lag: integer() | nil,
          lag: integer() | nil,
          credit_blocks: non_neg_integer(),
          age_ms: non_neg_integer() | nil,
          estimated?: boolean(),
          evidence: :observed | :estimated | :stale | :unavailable
        }

  @spec project(map(), non_neg_integer(), integer()) :: projection()
  def project(observation, block_time_ms, now_ms \\ System.system_time(:millisecond))

  def project(observation, block_time_ms, now_ms)
      when is_map(observation) and is_integer(now_ms) do
    raw_height = Map.get(observation, :height)
    raw_lag = Map.get(observation, :lag)
    age_ms = observation_age_ms(observation, now_ms)
    stale? = stale_for_age?(observation, age_ms)

    credit_blocks = advancement_credit(observation, raw_lag, age_ms, stale?, block_time_ms)

    %{
      raw_height: raw_height,
      height: advance_height(raw_height, credit_blocks),
      raw_lag: raw_lag,
      lag: advance_lag(raw_lag, credit_blocks),
      credit_blocks: credit_blocks,
      age_ms: age_ms,
      estimated?: credit_blocks > 0,
      evidence: evidence(raw_height, stale?, credit_blocks)
    }
  end

  def project(_observation, _block_time_ms, _now_ms),
    do: %{
      raw_height: nil,
      height: nil,
      raw_lag: nil,
      lag: nil,
      credit_blocks: 0,
      age_ms: nil,
      estimated?: false,
      evidence: :unavailable
    }

  @spec projected_lag(map(), non_neg_integer(), integer()) :: integer() | nil
  def projected_lag(observation, block_time_ms, now_ms \\ System.system_time(:millisecond))

  def projected_lag(observation, block_time_ms, now_ms),
    do: project(observation, block_time_ms, now_ms).lag

  @doc "Time-aligns an observation toward, but never beyond, an observed reference height."
  @spec align_height(map(), integer(), non_neg_integer(), integer()) :: projection()
  def align_height(
        observation,
        observed_height,
        block_time_ms,
        now_ms \\ System.system_time(:millisecond)
      )

  def align_height(observation, observed_height, block_time_ms, now_ms)
      when is_map(observation) and is_integer(observed_height) do
    lag =
      case Map.get(observation, :height) do
        height when is_integer(height) -> height - observed_height
        _missing -> nil
      end

    observation
    |> Map.put(:lag, lag)
    |> project(block_time_ms, now_ms)
  end

  @spec stale?(map(), integer()) :: boolean()
  def stale?(observation, now_ms) when is_map(observation) and is_integer(now_ms),
    do: stale_for_age?(observation, observation_age_ms(observation, now_ms))

  defp stale_for_age?(observation, age_ms) do
    case {age_ms, Map.get(observation, :stale_after_ms)} do
      {age, stale_after_ms}
      when is_integer(age) and is_integer(stale_after_ms) and stale_after_ms > 0 ->
        age > stale_after_ms

      _ ->
        false
    end
  end

  defp observation_age_ms(observation, now_ms) do
    case Map.get(observation, :observed_at_ms) do
      observed_at_ms when is_integer(observed_at_ms) -> max(0, now_ms - observed_at_ms)
      _ -> nil
    end
  end

  defp advancement_credit(observation, raw_lag, age_ms, false, block_time_ms)
       when is_integer(raw_lag) and raw_lag < 0 and is_integer(age_ms) and
              is_integer(block_time_ms) and block_time_ms > 0 do
    if Map.get(observation, :source) in [:http, "http"] do
      observation
      |> credit_window_ms()
      |> credit_for_age(age_ms, block_time_ms, raw_lag)
    else
      0
    end
  end

  defp advancement_credit(_observation, _raw_lag, _age_ms, _stale?, _block_time_ms), do: 0

  defp credit_window_ms(%{credit_window_ms: value}) when is_integer(value) and value > 0,
    do: value

  defp credit_window_ms(%{stale_after_ms: value}) when is_integer(value) and value > 0,
    do: div(value, 3)

  defp credit_window_ms(_observation), do: 0

  defp credit_for_age(credit_window_ms, age_ms, block_time_ms, raw_lag)
       when credit_window_ms > 0 do
    age_ms
    |> min(credit_window_ms)
    |> div(block_time_ms)
    |> min(abs(raw_lag))
  end

  defp credit_for_age(_credit_window_ms, _age_ms, _block_time_ms, _raw_lag), do: 0

  defp advance_height(height, credit) when is_integer(height), do: height + credit
  defp advance_height(_height, _credit), do: nil

  defp advance_lag(lag, credit) when is_integer(lag), do: lag + credit
  defp advance_lag(_lag, _credit), do: nil

  defp evidence(_height, true, _credit), do: :stale
  defp evidence(height, _stale, _credit) when not is_integer(height), do: :unavailable
  defp evidence(_height, _stale, credit) when credit > 0, do: :estimated
  defp evidence(_height, _stale, _credit), do: :observed
end
