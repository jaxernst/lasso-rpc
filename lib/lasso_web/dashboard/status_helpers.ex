defmodule LassoWeb.Dashboard.StatusHelpers do
  @moduledoc """
  Status-related helper functions for providers and events.
  Enhanced with comprehensive status classification logic including block sync validation.
  """

  alias Lasso.BlockSync.Registry, as: BlockSyncRegistry
  alias Lasso.Providers.LagCalculation

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
        block_lag_to_status(fields.chain, fields.instance_id || fields.provider_id)

      fields.health_status in [:unhealthy, :misconfigured, :degraded] ->
        :degraded

      fields.consecutive_failures in 3..9 ->
        :degraded

      fields.health_status == :connecting or fields.connection_status == :connecting ->
        :recovering

      fields.connection_status == :connected ->
        block_lag_to_status(fields.chain, fields.instance_id || fields.provider_id)

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
      instance_id: Map.get(provider, :instance_id),
      http_rate_limited: Map.get(provider, :http_rate_limited, false),
      ws_rate_limited: Map.get(provider, :ws_rate_limited, false),
      is_in_cooldown: Map.get(provider, :is_in_cooldown, false),
      reconnect_attempts: Map.get(provider, :reconnect_attempts, 0),
      ws_status: Map.get(provider, :ws_status)
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
      fields.ws_status in [:disconnected, :reconnecting]
  end

  defp block_lag_to_status(chain, provider_id) do
    case check_block_lag(chain, provider_id) do
      :synced -> :healthy
      :lagging -> :lagging
      :degraded_no_data -> :healthy
      :unavailable -> :healthy
    end
  end

  @doc """
  Check if a provider is lagging behind the best known block height.

  Uses optimistic lag calculation to fairly evaluate HTTP providers on fast chains.
  Optimistic lag credits providers for blocks that likely arrived since the last poll,
  preventing unfair "lagging" status on chains like Arbitrum (0.25s blocks).

  Returns:
  - :synced - Within acceptable lag threshold
  - :lagging - Beyond lag threshold
  - :degraded_no_data - Block height polling is failing (distinct from startup transient)
  - :unavailable - No lag data available (fail-open for startup/transient)
  """
  def check_block_lag(chain, provider_id) when is_binary(chain) and is_binary(provider_id) do
    threshold = lag_threshold_blocks()

    if threshold == 0 do
      :synced
    else
      case calculate_optimistic_lag(chain, provider_id) do
        {:ok, optimistic_lag} when optimistic_lag >= -threshold ->
          :synced

        {:ok, _optimistic_lag} ->
          :lagging

        {:error, _reason} ->
          case check_block_height_source_status(chain, provider_id) do
            :polling_failing -> :degraded_no_data
            _ -> :unavailable
          end
      end
    end
  end

  def check_block_lag(_chain, _provider_id), do: :unavailable

  @doc """
  Calculate optimistic lag that accounts for observation delay.

  With HTTP polling always running (see BlockSync.Worker), the registry
  always has reasonably fresh data. This formula credits providers for
  blocks that likely arrived since the last observation.

  The 30s cap prevents runaway values in edge cases.
  """
  def calculate_optimistic_lag(chain, provider_id) do
    block_time_ms = LagCalculation.get_block_time_ms(chain)

    case LagCalculation.calculate_optimistic_lag(chain, provider_id, block_time_ms) do
      {:ok, optimistic_lag, _raw_lag} -> {:ok, optimistic_lag}
      error -> error
    end
  end

  @doc """
  Get block_time_ms for a chain. Prefers dynamic measurement, falls back to config.
  """
  def get_block_time_ms(chain) do
    LagCalculation.get_block_time_ms(chain)
  end

  @doc """
  Check the status of block height tracking for a provider.

  Returns:
  - :ok - Block height tracking is working (has recent height data)
  - :polling_failing - No recent height data
  """
  def check_block_height_source_status(chain, provider_id)
      when is_binary(chain) and is_binary(provider_id) do
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

  @doc "Get provider status breakdown for summary"
  def status_breakdown(providers) when is_list(providers) do
    providers
    |> Enum.group_by(&determine_provider_status/1)
    |> Map.new(fn {status, provider_list} -> {status, length(provider_list)} end)
  end

  @doc "Get severity text CSS class"
  def severity_text_class(:debug), do: "text-gray-400"
  def severity_text_class(:info), do: "text-sky-300"
  def severity_text_class(:warn), do: "text-yellow-300"
  def severity_text_class(:error), do: "text-red-400"
  def severity_text_class(_), do: "text-gray-400"
end
