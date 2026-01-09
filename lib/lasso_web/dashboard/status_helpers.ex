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
    fields = extract_status_fields(provider)

    cond do
      rate_limited?(fields) ->
        :rate_limited

      fields.circuit_state == :open ->
        :circuit_open

      fields.circuit_state == :half_open ->
        :testing_recovery

      ws_recovering?(fields) ->
        :recovering

      fields.health_status == :healthy ->
        block_lag_to_status(fields.chain, fields.provider_id)

      fields.health_status in [:unhealthy, :misconfigured, :degraded] ->
        :degraded

      fields.consecutive_failures in 3..9 ->
        :degraded

      fields.health_status == :connecting or fields.connection_status == :connecting ->
        :recovering

      fields.connection_status == :connected ->
        block_lag_to_status(fields.chain, fields.provider_id)

      fields.connection_status in [:disconnected, :rate_limited] ->
        :degraded

      true ->
        :unknown
    end
  end

  defp extract_status_fields(provider) do
    %{
      circuit_state: Map.get(provider, :circuit_state, :closed),
      health_status: Map.get(provider, :health_status, :unknown),
      connection_status: Map.get(provider, :status, :unknown),
      consecutive_failures: Map.get(provider, :consecutive_failures, 0),
      chain: Map.get(provider, :chain),
      provider_id: Map.get(provider, :id),
      http_rate_limited: Map.get(provider, :http_rate_limited, false),
      ws_rate_limited: Map.get(provider, :ws_rate_limited, false),
      is_in_cooldown: Map.get(provider, :is_in_cooldown, false),
      reconnect_attempts: Map.get(provider, :reconnect_attempts, 0),
      ws_status: Map.get(provider, :ws_status),
      reconnect_grace_until: Map.get(provider, :reconnect_grace_until)
    }
  end

  defp rate_limited?(fields) do
    fields.http_rate_limited or
      fields.ws_rate_limited or
      fields.health_status == :rate_limited or
      fields.is_in_cooldown
  end

  defp ws_recovering?(fields) do
    fields.reconnect_attempts > 0 and
      (fields.ws_status in [:disconnected, :connecting] or
         in_reconnect_grace?(fields.reconnect_grace_until))
  end

  defp block_lag_to_status(chain, provider_id) do
    case check_block_lag(chain, provider_id) do
      :synced -> :healthy
      :lagging -> :lagging
      :degraded_no_data -> :degraded
      :unavailable -> :healthy
    end
  end

  @doc """
  Check if a provider is lagging behind the best known block height.

  Returns:
  - :synced - Within acceptable lag threshold
  - :lagging - Beyond lag threshold
  - :degraded_no_data - Block height polling is failing (distinct from startup transient)
  - :unavailable - No lag data available (fail-open for startup/transient)
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
          # No lag data - check if HTTP polling is persistently failing
          case check_block_height_source_status(chain, provider_id) do
            :polling_failing -> :degraded_no_data
            _ -> :unavailable
          end
      end
    end
  end

  def check_block_lag(_chain, _provider_id), do: :unavailable

  @doc """
  Check the status of block height tracking for a provider.

  Returns:
  - :ok - Block height tracking is working (has recent height data)
  - :polling_failing - No recent height data
  """
  def check_block_height_source_status(chain, provider_id)
      when is_binary(chain) and is_binary(provider_id) do
    alias Lasso.BlockSync.Registry, as: BlockSyncRegistry

    # Check if we have recent height data for this provider
    case BlockSyncRegistry.get_height(chain, provider_id) do
      {:ok, {_height, timestamp, _source, _meta}} ->
        # Check if data is recent (within 60 seconds)
        age = System.system_time(:millisecond) - timestamp

        if age < 60_000 do
          :ok
        else
          :polling_failing
        end

      {:error, :not_found} ->
        # No height data yet - provider may still be initializing
        :ok
    end
  catch
    :exit, _ -> :ok
  end

  def check_block_height_source_status(_chain, _provider_id), do: :ok

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
      :circuit_open -> "Circuit Open"
      :testing_recovery -> "Recovering"
      :rate_limited -> "Rate Limited"
      :recovering -> "Recovering"
      :degraded -> "Degraded"
      :lagging -> "Lagging"
      :healthy -> "Healthy"
      :unknown -> "Unknown"
    end
  end

  @doc """
  Get comprehensive color scheme for a provider status.
  Returns a map with all color variants for consistent styling across the UI.

  Keys:
  - :hex - Hex color code (for SVG/canvas)
  - :text - Text color class
  - :bg - Background color class
  - :bg_muted - Muted/transparent background class
  - :border - Border color class
  - :dot - Status indicator dot class
  """
  def status_color_scheme(status) do
    case status do
      :circuit_open ->
        %{
          hex: "#dc2626",
          text: "text-red-500",
          bg: "bg-red-500",
          bg_muted: "bg-red-900/40",
          border: "border-red-500",
          dot: "bg-red-500"
        }

      :testing_recovery ->
        %{
          hex: "#f59e0b",
          text: "text-amber-400",
          bg: "bg-amber-400",
          bg_muted: "bg-amber-900/30",
          border: "border-gray-600",
          dot: "bg-amber-400"
        }

      :rate_limited ->
        %{
          hex: "#8b5cf6",
          text: "text-purple-300",
          bg: "bg-purple-400",
          bg_muted: "bg-purple-900/30",
          border: "border-purple-500",
          dot: "bg-purple-400"
        }

      :recovering ->
        %{
          hex: "#f59e0b",
          text: "text-amber-400",
          bg: "bg-amber-400",
          bg_muted: "bg-amber-900/30",
          border: "border-gray-600",
          dot: "bg-amber-400"
        }

      :degraded ->
        %{
          hex: "#f97316",
          text: "text-orange-400",
          bg: "bg-orange-400",
          bg_muted: "bg-orange-900/30",
          border: "border-orange-500",
          dot: "bg-orange-400"
        }

      :lagging ->
        %{
          hex: "#38bdf8",
          text: "text-sky-400",
          bg: "bg-sky-400",
          bg_muted: "bg-sky-900/30",
          border: "border-sky-500",
          dot: "bg-sky-400"
        }

      :healthy ->
        %{
          hex: "#10b981",
          text: "text-emerald-400",
          bg: "bg-emerald-400",
          bg_muted: "bg-emerald-900/30",
          border: "border-gray-600",
          dot: "bg-emerald-400"
        }

      :unknown ->
        %{
          hex: "#6b7280",
          text: "text-gray-400",
          bg: "bg-gray-400",
          bg_muted: "bg-gray-900/30",
          border: "border-gray-600",
          dot: "bg-gray-400"
        }
    end
  end

  @doc "Get provider status CSS text class with enhanced colors"
  def provider_status_class_text(provider) do
    provider |> determine_provider_status() |> status_color_scheme() |> Map.get(:text)
  end

  @doc "Get provider status indicator color (for dots/circles)"
  def provider_status_indicator_class(provider) do
    provider |> determine_provider_status() |> status_color_scheme() |> Map.get(:dot)
  end

  @doc "Get provider status badge classes (background + border for pill badges)"
  def provider_status_badge_class(provider) do
    case determine_provider_status(provider) do
      :healthy -> "bg-emerald-500/10 border-emerald-500/30 text-emerald-400"
      :lagging -> "bg-sky-500/10 border-sky-500/30 text-sky-400"
      :recovering -> "bg-amber-500/10 border-amber-500/30 text-amber-400"
      :testing_recovery -> "bg-amber-500/10 border-amber-500/30 text-amber-400"
      :degraded -> "bg-orange-500/10 border-orange-500/30 text-orange-400"
      :rate_limited -> "bg-purple-500/10 border-purple-500/30 text-purple-400"
      :circuit_open -> "bg-red-500/10 border-red-500/30 text-red-400"
      :unknown -> "bg-gray-500/10 border-gray-500/30 text-gray-400"
    end
  end

  @doc "Check if provider status is considered critical"
  def critical_status?(provider) do
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
