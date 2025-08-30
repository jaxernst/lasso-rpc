defmodule LivechainWeb.Dashboard.StatusHelpers do
  @moduledoc """
  Status-related helper functions for providers and events.
  Enhanced with comprehensive status classification logic.
  """

  @doc """
  Determine the comprehensive status of a provider based on multiple factors:
  - Circuit breaker state
  - Health check status
  - Connection status  
  - Rate limiting
  - Failure patterns
  """
  def determine_provider_status(provider) do
    circuit_state = Map.get(provider, :circuit_state, :closed)
    health_status = Map.get(provider, :health_status, :unknown)
    connection_status = Map.get(provider, :status, :unknown)
    consecutive_failures = Map.get(provider, :consecutive_failures, 0)
    reconnect_attempts = Map.get(provider, :reconnect_attempts, 0)
    is_in_cooldown = Map.get(provider, :is_in_cooldown, false)

    cond do
      # Circuit breaker is open - provider is effectively failed
      circuit_state == :open ->
        :circuit_open

      # Rate limited/cooldown state
      connection_status == :rate_limited or is_in_cooldown ->
        :rate_limited

      # Provider has failed too many times
      consecutive_failures >= 10 ->
        :failed

      # Health checks are specifically failing
      health_status == :unhealthy ->
        :unhealthy

      # Connection issues with frequent reconnects
      reconnect_attempts >= 5 and health_status != :healthy ->
        :unstable

      # Normal connecting state (initial connection)
      connection_status == :connecting and reconnect_attempts < 3 ->
        :connecting

      # Healthy and connected
      connection_status in [:connected, :healthy] and health_status in [:healthy, :connected] ->
        :connected

      # Circuit breaker in recovery mode
      circuit_state == :half_open ->
        :recovering

      # Default fallback
      true ->
        :unknown
    end
  end

  @doc "Get provider status label with enhanced classifications"
  def provider_status_label(provider) do
    case determine_provider_status(provider) do
      :circuit_open -> "CIRCUIT OPEN"
      :rate_limited -> "RATE LIMITED"
      :failed -> "FAILED"
      :unhealthy -> "UNHEALTHY"
      :unstable -> "UNSTABLE"
      :connecting -> "CONNECTING"
      :connected -> "HEALTHY"
      :recovering -> "RECOVERING"
      :unknown -> "UNKNOWN"
    end
  end

  @doc "Get provider status CSS text class with enhanced colors"
  def provider_status_class_text(provider) do
    case determine_provider_status(provider) do
      :circuit_open -> "text-red-500"      # 🔴 Critical failure
      :failed -> "text-red-400"            # 🔴 Failed
      :unhealthy -> "text-orange-400"      # 🟠 Unhealthy
      :unstable -> "text-yellow-400"       # 🟡 Unstable
      :rate_limited -> "text-purple-300"   # 🟣 Rate limited
      :connecting -> "text-gray-300"       # ⚪ Connecting
      :recovering -> "text-blue-400"       # 🔵 Recovering
      :connected -> "text-emerald-400"     # 🟢 Healthy
      :unknown -> "text-gray-400"          # ⚫ Unknown
    end
  end

  @doc "Get provider status indicator color (for dots/circles)"
  def provider_status_indicator_class(provider) do
    case determine_provider_status(provider) do
      :circuit_open -> "bg-red-500"
      :failed -> "bg-red-400" 
      :unhealthy -> "bg-orange-400"
      :unstable -> "bg-yellow-400"
      :rate_limited -> "bg-purple-400"
      :connecting -> "bg-gray-300"
      :recovering -> "bg-blue-400"
      :connected -> "bg-emerald-400"
      :unknown -> "bg-gray-400"
    end
  end

  @doc "Check if provider status is considered critical"
  def is_critical_status?(provider) do
    determine_provider_status(provider) in [:circuit_open, :failed]
  end

  @doc "Check if provider status needs attention"
  def needs_attention?(provider) do
    determine_provider_status(provider) in [:circuit_open, :failed, :unhealthy, :unstable]
  end

  @doc "Get status priority for sorting (lower = more critical)"
  def status_priority(provider) do
    case determine_provider_status(provider) do
      :circuit_open -> 1
      :failed -> 2
      :unhealthy -> 3
      :unstable -> 4
      :rate_limited -> 5
      :recovering -> 6
      :connecting -> 7
      :connected -> 8
      :unknown -> 9
    end
  end

  @doc "Get human-readable status explanation"
  def status_explanation(provider) do
    case determine_provider_status(provider) do
      :circuit_open -> "Circuit breaker is open due to repeated failures"
      :failed -> "Provider has failed too many consecutive requests"
      :unhealthy -> "Health checks are failing"
      :unstable -> "Frequent connection issues and reconnects"
      :rate_limited -> "Provider is rate limited or in cooldown"
      :connecting -> "Establishing initial connection"
      :recovering -> "Circuit breaker is testing recovery"
      :connected -> "All systems operational"
      :unknown -> "Status cannot be determined"
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