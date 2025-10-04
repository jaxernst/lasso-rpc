defmodule Lasso.RPC.HealthPolicy do
  @moduledoc """
  Provider health policy: separates availability from performance signals for routing.

  Availability (single axis): :up | :limited | :down | :misconfigured
  Performance signals: rolling success rate, latency EMA, optional head-lag
  """

  @derive {Jason.Encoder, only: [:availability, :cooldown_until, :consecutive_failures]}
  alias Lasso.JSONRPC.Error, as: JError

  @type context :: :health_check | :live_traffic
  @type availability :: :up | :limited | :down | :misconfigured
  @type method :: String.t()

  @type method_signals :: %{}

  @type t :: %__MODULE__{
          availability: availability(),
          cooldown_until: integer() | nil,
          consecutive_failures: non_neg_integer(),
          by_method: %{optional(method()) => method_signals()},
          config: %{
            failure_threshold: non_neg_integer(),
            base_cooldown_ms: non_neg_integer(),
            max_cooldown_ms: non_neg_integer(),
            ema_alpha: float()
          }
        }

  defstruct availability: :up,
            cooldown_until: nil,
            consecutive_failures: 0,
            by_method: %{},
            config: %{
              failure_threshold: 3,
              base_cooldown_ms: 1_000,
              max_cooldown_ms: 300_000,
              ema_alpha: 0.1
            }

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      config:
        Map.merge(
          %{
            failure_threshold: 3,
            base_cooldown_ms: 1_000,
            max_cooldown_ms: 300_000,
            ema_alpha: 0.1
          },
          Map.new(opts)
        )
    }
  end

  @spec apply_event(t(), {:success, non_neg_integer(), method() | nil}) :: t()
  def apply_event(%__MODULE__{} = s, {:success, _latency_ms, _method}) do
    %{
      s
      | consecutive_failures: 0,
        availability: normalize_availability_after_success(s.availability),
        cooldown_until: if(s.cooldown_until, do: nil, else: nil)
    }
  end

  @spec apply_event(t(), {:failure, JError.t(), context, method() | nil, integer()}) :: t()
  def apply_event(%__MODULE__{} = s, {:failure, %JError{} = jerr, context, _method, now_ms}) do
    cond do
      jerr.category == :rate_limit ->
        {cooldown_until, availability} = compute_cooldown(now_ms, s)

        %{
          s
          | availability: availability,
            cooldown_until: cooldown_until,
            by_method: s.by_method
        }

      context == :health_check and jerr.category == :client_error ->
        %{s | availability: :misconfigured, by_method: s.by_method}

      true ->
        cf = s.consecutive_failures + 1
        availability = if cf >= s.config.failure_threshold, do: :down, else: :up

        %{
          s
          | consecutive_failures: cf,
            availability: availability,
            by_method: s.by_method
        }
    end
  end

  @spec availability(t()) :: availability()
  def availability(%__MODULE__{availability: a}), do: a

  @spec availability(t(), method()) :: availability()
  def availability(%__MODULE__{} = s, _method), do: s.availability

  @spec cooldown?(t(), integer()) :: boolean()
  def cooldown?(%__MODULE__{cooldown_until: nil}, _now_ms), do: false
  def cooldown?(%__MODULE__{cooldown_until: until_ms}, now_ms), do: now_ms < until_ms

  defp compute_cooldown(now_ms, s) do
    base = s.config.base_cooldown_ms
    maxc = s.config.max_cooldown_ms
    count = s.consecutive_failures + 1
    ms = min(trunc(base * :math.pow(2, count)), maxc)
    {now_ms + ms, :limited}
  end

  defp normalize_availability_after_success(:limited), do: :up
  defp normalize_availability_after_success(other), do: other

  # Backwards-compatible decision used by ProviderPool
  @doc false
  @spec decide_failure_status(JError.t(), context, non_neg_integer(), non_neg_integer()) ::
          :misconfigured | :unhealthy | :degraded
  def decide_failure_status(%JError{} = jerr, context, consecutive_failures, failure_threshold) do
    cond do
      context == :health_check and jerr.category == :client_error -> :misconfigured
      consecutive_failures >= failure_threshold -> :unhealthy
      true -> :degraded
    end
  end
end
