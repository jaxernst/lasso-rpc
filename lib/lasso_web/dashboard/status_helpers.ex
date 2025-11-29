defmodule LassoWeb.Dashboard.StatusHelpers do
  @moduledoc """
  Status-related helper functions for providers and events.
  Enhanced with comprehensive status classification logic including block sync validation.
  """

  alias Lasso.RPC.ChainState

  # Configuration: maximum blocks a provider can lag behind before showing as "syncing"
  # Read from application config at runtime
  defp lag_threshold_blocks do
    Application.get_env(:lasso, :dashboard_status, [])
    |> Keyword.get(:lag_threshold_blocks, 10)
  end

  @doc """
  Determine the comprehensive status of a provider based on multiple factors:
  - Rate limiting (highest priority - even if circuit open)
  - Circuit breaker state
  - Block sync status (for healthy providers)
  - WebSocket reconnection attempts
  - Health check status
  - Failure patterns

  Returns one of:
  - :healthy - All systems operational, synced
  - :lagging - Responsive but lagging blocks
  - :recovering - WebSocket recovering connection
  - :degraded - Has issues but still trying
  - :rate_limited - In cooldown (takes priority even over circuit open)
  - :circuit_open - Complete failure
  - :testing_recovery - Circuit testing recovery
  - :unknown - Cannot determine (rare)
  """
  def determine_provider_status(provider) do
    circuit_state = Map.get(provider, :circuit_state, :closed)
    health_status = Map.get(provider, :health_status, :unknown)
    connection_status = Map.get(provider, :status, :unknown)
    consecutive_failures = Map.get(provider, :consecutive_failures, 0)
    reconnect_attempts = Map.get(provider, :reconnect_attempts, 0)
    ws_status = Map.get(provider, :ws_status)
    chain = Map.get(provider, :chain)
    provider_id = Map.get(provider, :id)
    reconnect_grace_until = Map.get(provider, :reconnect_grace_until)

    # Check rate limit state from RateLimitState (primary source, auto-expires)
    http_rate_limited = Map.get(provider, :http_rate_limited, false)
    ws_rate_limited = Map.get(provider, :ws_rate_limited, false)
    is_rate_limited = http_rate_limited or ws_rate_limited

    # Fallback to legacy is_in_cooldown for backwards compatibility
    is_in_cooldown = Map.get(provider, :is_in_cooldown, false)

    cond do
      # 1. Rate limited (from RateLimitState) - highest priority, auto-expires
      is_rate_limited or health_status == :rate_limited or is_in_cooldown ->
        :rate_limited

      # 2. Circuit breaker is open - complete failure
      circuit_state == :open ->
        :circuit_open

      # 3. Circuit breaker testing recovery
      circuit_state == :half_open ->
        :testing_recovery

      # 4. WebSocket actively recovering or in grace period after reconnection
      reconnect_attempts > 0 and
          (ws_status in [:disconnected, :connecting] or in_reconnect_grace?(reconnect_grace_until)) ->
        :recovering

      # 5. Healthy - check block sync status
      health_status == :healthy ->
        case check_block_lag(chain, provider_id) do
          :synced -> :healthy
          :lagging -> :lagging
          # Fail-open: if no lag data, show as healthy
          :unavailable -> :healthy
        end

      # 6. Degraded states (consolidated from unhealthy, unstable, misconfigured)
      health_status in [:unhealthy, :misconfigured, :degraded] ->
        :degraded

      # Provider has significant failures but circuit not yet open
      consecutive_failures >= 3 and consecutive_failures < 10 ->
        :degraded

      # 7. Initial connection states (only during startup)
      health_status == :connecting or connection_status == :connecting ->
        :recovering

      # 8. Fallback to connection_status for compatibility
      connection_status == :connected ->
        # Double-check block lag even for legacy status
        case check_block_lag(chain, provider_id) do
          :synced -> :healthy
          :lagging -> :lagging
          :unavailable -> :healthy
        end

      connection_status in [:disconnected, :rate_limited] ->
        :degraded

      # 9. Default fallback
      true ->
        :unknown
    end
  end

  @doc """
  Check if a provider is lagging behind the best known block height.

  Returns:
  - :synced - Within acceptable lag threshold
  - :lagging - Beyond lag threshold
  - :unavailable - No lag data available (fail-open)
  """
  def check_block_lag(chain, provider_id) when is_binary(chain) and is_binary(provider_id) do
    threshold = lag_threshold_blocks()

    # If threshold is 0, disable lag checking (always return :synced)
    if threshold == 0 do
      :synced
    else
      case ChainState.provider_lag(chain, provider_id) do
        {:ok, lag} when lag >= -threshold ->
          # Lag is within threshold (negative lag = blocks behind)
          # lag >= -10 means provider is at most 10 blocks behind
          :synced

        {:ok, _lag} ->
          # Provider is lagging beyond threshold
          :lagging

        {:error, _reason} ->
          # Lag data unavailable - fail open (don't penalize provider)
          :unavailable
      end
    end
  end

  def check_block_lag(_chain, _provider_id), do: :unavailable

  # Check if the provider is still in reconnection grace period.
  # During this period, we show "Reconnecting" status even if reconnected successfully,
  # giving the provider time to stabilize.
  defp in_reconnect_grace?(nil), do: false

  defp in_reconnect_grace?(grace_until) when is_integer(grace_until) do
    System.monotonic_time(:millisecond) < grace_until
  end

  @doc "Get provider status label with enhanced classifications"
  def provider_status_label(provider) do
    case determine_provider_status(provider) do
      :circuit_open -> "CIRCUIT OPEN"
      :testing_recovery -> "TESTING RECOVERY"
      :rate_limited -> "RATE LIMITED"
      :recovering -> "RECOVERING"
      :degraded -> "DEGRADED"
      :lagging -> "LAGGING"
      :healthy -> "HEALTHY"
      :unknown -> "UNKNOWN"
    end
  end

  @doc "Get provider status CSS text class with enhanced colors"
  def provider_status_class_text(provider) do
    case determine_provider_status(provider) do
      # 🔴 Critical failure
      :circuit_open -> "text-red-500"
      # 🟡 Testing recovery (amber - same as recovering)
      :testing_recovery -> "text-amber-400"
      # 🟣 Rate limited
      :rate_limited -> "text-purple-300"
      # 🟡 Recovering
      :recovering -> "text-amber-400"
      # 🟠 Degraded
      :degraded -> "text-orange-400"
      # 🔵 Lagging
      :lagging -> "text-sky-400"
      # 🟢 Healthy
      :healthy -> "text-emerald-400"
      # ⚫ Unknown
      :unknown -> "text-gray-400"
    end
  end

  @doc "Get provider status indicator color (for dots/circles)"
  def provider_status_indicator_class(provider) do
    case determine_provider_status(provider) do
      :circuit_open -> "bg-red-500"
      :testing_recovery -> "bg-amber-400"
      :rate_limited -> "bg-purple-400"
      :recovering -> "bg-amber-400"
      :degraded -> "bg-orange-400"
      :lagging -> "bg-sky-400"
      :healthy -> "bg-emerald-400"
      :unknown -> "bg-gray-400"
    end
  end

  @doc "Check if provider status is considered critical"
  def is_critical_status?(provider) do
    determine_provider_status(provider) == :circuit_open
  end

  @doc "Check if provider status needs attention"
  def needs_attention?(provider) do
    determine_provider_status(provider) in [:circuit_open, :degraded, :rate_limited]
  end

  @doc "Get status priority for sorting (lower = more critical)"
  def status_priority(provider) do
    case determine_provider_status(provider) do
      :rate_limited -> 1
      :circuit_open -> 2
      :degraded -> 3
      :testing_recovery -> 4
      :recovering -> 5
      :lagging -> 6
      :healthy -> 7
      :unknown -> 8
    end
  end

  @doc "Get human-readable status explanation"
  def status_explanation(provider) do
    chain = Map.get(provider, :chain)
    provider_id = Map.get(provider, :id)
    circuit_state = Map.get(provider, :circuit_state, :closed)

    # Get rate limit info from new RateLimitState fields
    http_rate_limited = Map.get(provider, :http_rate_limited, false)
    ws_rate_limited = Map.get(provider, :ws_rate_limited, false)
    rate_limit_remaining = Map.get(provider, :rate_limit_remaining, %{})

    case determine_provider_status(provider) do
      :circuit_open ->
        # Check if also rate limited
        if http_rate_limited or ws_rate_limited do
          "Circuit breaker is open due to rate limiting. Provider is in cooldown and not accepting requests."
        else
          "Circuit breaker is open due to repeated failures. Provider is not accepting requests."
        end

      :testing_recovery ->
        "Circuit breaker is in half-open state, testing if provider has recovered."

      :rate_limited ->
        circuit_also_open = circuit_state == :open

        # Build message from rate limit remaining times
        http_remaining_ms = Map.get(rate_limit_remaining, :http)
        ws_remaining_ms = Map.get(rate_limit_remaining, :ws)

        base_msg =
          cond do
            http_remaining_ms && ws_remaining_ms ->
              http_sec = div(http_remaining_ms, 1000)
              ws_sec = div(ws_remaining_ms, 1000)
              "Provider is rate limited (HTTP: #{http_sec}s, WS: #{ws_sec}s remaining)."

            http_remaining_ms ->
              remaining_sec = div(http_remaining_ms, 1000)
              "Provider HTTP is rate limited for #{remaining_sec}s."

            ws_remaining_ms ->
              remaining_sec = div(ws_remaining_ms, 1000)
              "Provider WebSocket is rate limited for #{remaining_sec}s."

            true ->
              "Provider is rate limited."
          end

        # Note if circuit is also open
        if circuit_also_open do
          base_msg <> " Circuit breaker is also open."
        else
          base_msg
        end

      :recovering ->
        attempts = Map.get(provider, :reconnect_attempts, 0)
        "WebSocket connection lost. Recovering (attempt #{attempts})..."

      :degraded ->
        failures = Map.get(provider, :consecutive_failures, 0)
        "Provider is experiencing issues (#{failures} consecutive failures). Still attempting requests."

      :lagging ->
        case ChainState.provider_lag(chain, provider_id) do
          {:ok, lag} when lag < 0 ->
            blocks_behind = abs(lag)
            "Provider is responsive but lagging #{blocks_behind} blocks behind the network head."
          _ ->
            "Provider is responsive but lagging behind the network."
        end

      :healthy ->
        "All systems operational. Provider is healthy and synced."

      :unknown ->
        "Status cannot be determined. Check provider configuration and connectivity."
    end
  end

  @doc "Get provider status breakdown for summary"
  def status_breakdown(providers) when is_list(providers) do
    providers
    |> Enum.group_by(&determine_provider_status/1)
    |> Enum.map(fn {status, provider_list} ->
      {status, length(provider_list)}
    end)
    |> Enum.into(%{})
  end

  @doc "Get severity text CSS class"
  def severity_text_class(:debug), do: "text-gray-400"
  def severity_text_class(:info), do: "text-sky-300"
  def severity_text_class(:warn), do: "text-yellow-300"
  def severity_text_class(:error), do: "text-red-400"
  def severity_text_class(_), do: "text-gray-400"
end
