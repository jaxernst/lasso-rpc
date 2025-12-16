defmodule Lasso.RPC.RateLimitState do
  @moduledoc """
  Explicit rate limit state management with Retry-After support.

  This module decouples rate limit tracking from circuit breaker state.
  Rate limits are time-based (with known recovery times from Retry-After headers),
  while circuit breakers are count-based with heuristic recovery.

  ## Key Differences from Circuit Breaker

  - Rate limits have **known expiration times** (from Retry-After headers)
  - Rate limits clear **automatically** when time expires
  - Rate limits are **independent** of circuit breaker state
  - A provider can be rate-limited without circuit breaker being open

  ## Usage

      # Initialize for a provider
      state = RateLimitState.new()

      # Record a rate limit with Retry-After
      state = RateLimitState.record_rate_limit(state, :http, 30_000)

      # Check if rate limited
      RateLimitState.rate_limited?(state, :http)  # true

      # After 30 seconds...
      RateLimitState.rate_limited?(state, :http)  # false (auto-cleared)
  """

  @type transport :: :http | :ws

  @type t :: %__MODULE__{
          http_limited_until: integer() | nil,
          ws_limited_until: integer() | nil,
          http_retry_after_ms: pos_integer() | nil,
          ws_retry_after_ms: pos_integer() | nil
        }

  @enforce_keys []
  defstruct http_limited_until: nil,
            ws_limited_until: nil,
            http_retry_after_ms: nil,
            ws_retry_after_ms: nil

  @default_retry_after_ms 30_000

  @doc """
  Creates a new rate limit state with no active limits.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{}
  end

  @doc """
  Records a rate limit for a specific transport.

  The `retry_after_ms` parameter specifies how long until the rate limit expires.
  If nil, uses a default of #{@default_retry_after_ms}ms.

  ## Parameters

  - `state` - Current rate limit state
  - `transport` - :http or :ws
  - `retry_after_ms` - Milliseconds until rate limit expires (from Retry-After header)
  - `now_ms` - Current monotonic time in milliseconds (optional, defaults to now)

  ## Examples

      iex> state = RateLimitState.new()
      iex> state = RateLimitState.record_rate_limit(state, :http, 60_000)
      iex> RateLimitState.rate_limited?(state, :http)
      true
  """
  @spec record_rate_limit(t(), transport(), pos_integer() | nil, integer() | nil) :: t()
  def record_rate_limit(state, transport, retry_after_ms \\ nil, now_ms \\ nil) do
    now = now_ms || System.monotonic_time(:millisecond)
    retry_ms = retry_after_ms || @default_retry_after_ms
    limited_until = now + retry_ms

    case transport do
      :http ->
        %{state | http_limited_until: limited_until, http_retry_after_ms: retry_ms}

      :ws ->
        %{state | ws_limited_until: limited_until, ws_retry_after_ms: retry_ms}
    end
  end

  @doc """
  Checks if a transport is currently rate limited.

  Automatically returns false if the rate limit has expired.

  ## Parameters

  - `state` - Current rate limit state
  - `transport` - :http or :ws
  - `now_ms` - Current monotonic time in milliseconds (optional)
  """
  @spec rate_limited?(t(), transport(), integer() | nil) :: boolean()
  def rate_limited?(state, transport, now_ms \\ nil) do
    now = now_ms || System.monotonic_time(:millisecond)
    limited_until = get_limited_until(state, transport)

    limited_until != nil and now < limited_until
  end

  @doc """
  Returns the remaining time (in ms) until rate limit expires for a transport.

  Returns nil if not rate limited or if rate limit has expired.
  """
  @spec time_remaining(t(), transport(), integer() | nil) :: pos_integer() | nil
  def time_remaining(state, transport, now_ms \\ nil) do
    now = now_ms || System.monotonic_time(:millisecond)
    limited_until = get_limited_until(state, transport)

    if limited_until != nil and now < limited_until do
      limited_until - now
    else
      nil
    end
  end

  @doc """
  Clears the rate limit for a specific transport.

  Typically called when a successful request goes through, indicating
  the rate limit has lifted.
  """
  @spec clear_rate_limit(t(), transport()) :: t()
  def clear_rate_limit(state, transport) do
    case transport do
      :http ->
        %{state | http_limited_until: nil, http_retry_after_ms: nil}

      :ws ->
        %{state | ws_limited_until: nil, ws_retry_after_ms: nil}
    end
  end

  @doc """
  Clears all rate limits.
  """
  @spec clear_all(t()) :: t()
  def clear_all(_state) do
    new()
  end

  @doc """
  Checks if any transport is currently rate limited.
  """
  @spec any_rate_limited?(t(), integer() | nil) :: boolean()
  def any_rate_limited?(state, now_ms \\ nil) do
    rate_limited?(state, :http, now_ms) or rate_limited?(state, :ws, now_ms)
  end

  @doc """
  Returns the rate limit state as a map suitable for serialization/display.

  Only includes active (non-expired) rate limits.
  """
  @spec to_map(t(), integer() | nil) :: map()
  def to_map(state, now_ms \\ nil) do
    now = now_ms || System.monotonic_time(:millisecond)

    %{
      http: rate_limit_info(state, :http, now),
      ws: rate_limit_info(state, :ws, now)
    }
  end

  @doc """
  Extracts retry_after_ms from a JError's data field if present.
  """
  @spec extract_retry_after(map() | nil) :: pos_integer() | nil
  def extract_retry_after(nil), do: nil

  def extract_retry_after(%{retry_after_ms: ms}) when is_integer(ms) and ms > 0, do: ms
  def extract_retry_after(%{"retry_after_ms" => ms}) when is_integer(ms) and ms > 0, do: ms

  def extract_retry_after(data) when is_map(data) do
    # Also check for :retry_after (seconds) and convert to ms
    cond do
      Map.has_key?(data, :retry_after) ->
        case data[:retry_after] do
          s when is_integer(s) -> s * 1000
          _ -> nil
        end

      Map.has_key?(data, "retry_after") ->
        case data["retry_after"] do
          s when is_integer(s) -> s * 1000
          _ -> nil
        end

      true ->
        nil
    end
  end

  def extract_retry_after(_), do: nil

  # Private helpers

  defp get_limited_until(state, :http), do: state.http_limited_until
  defp get_limited_until(state, :ws), do: state.ws_limited_until

  defp rate_limit_info(state, transport, now) do
    if rate_limited?(state, transport, now) do
      %{
        limited: true,
        remaining_ms: time_remaining(state, transport, now),
        retry_after_ms:
          case transport do
            :http -> state.http_retry_after_ms
            :ws -> state.ws_retry_after_ms
          end
      }
    else
      %{limited: false}
    end
  end
end
