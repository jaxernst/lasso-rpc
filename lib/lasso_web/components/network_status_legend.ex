defmodule LassoWeb.Components.NetworkStatusLegend do
  @moduledoc """
  Network status legend component showing provider health indicators.

  Status hierarchy (ordered by severity):
  1. Rate Limited (🟣) - In cooldown (highest priority)
  2. Circuit Open (🔴) - Complete failure
  3. Degraded (🟠) - Has issues but trying
  4. Testing Recovery (🟡) - Circuit testing recovery
  5. Recovering (🟡) - WS recovering
  6. Lagging (🔵) - Lagging blocks
  7. Healthy (🟢) - Fully operational
  """
  use Phoenix.Component

  def legend(assigns) do
    ~H"""
    <div class="absolute bottom-4 right-4 flex items-center gap-3 lg:right-6 xl:left-1/2 xl:right-auto xl:-translate-x-1/2">
      <div class="bg-gray-900/20 border-gray-700/50 rounded-lg border p-4 shadow-xl backdrop-blur-sm">
        <div class="flex flex-wrap justify-end gap-3 xl:justify-center">
          <!-- Healthy Status -->
          <div
            class="flex items-center space-x-1.5 text-xs text-gray-300"
            title="All systems operational and synced"
          >
            <div class="h-2.5 w-2.5 flex-shrink-0 rounded-full bg-emerald-400"></div>
            <span>Healthy</span>
          </div>
          
    <!-- Lagging Status -->
          <div
            class="flex items-center space-x-1.5 text-xs text-gray-300"
            title="Responsive but lagging blocks behind network"
          >
            <div class="h-2.5 w-2.5 flex-shrink-0 rounded-full bg-sky-400"></div>
            <span>Lagging</span>
          </div>
          
    <!-- Recovering Status (covers both WS recovery and circuit half-open) -->
          <div
            class="flex items-center space-x-1.5 text-xs text-gray-300"
            title="Connection recovering or circuit testing recovery"
          >
            <div class="h-2.5 w-2.5 flex-shrink-0 rounded-full bg-amber-400"></div>
            <span>Recovering</span>
          </div>
          
    <!-- Degraded Status -->
          <div
            class="flex items-center space-x-1.5 text-xs text-gray-300"
            title="Experiencing issues but still trying"
          >
            <div class="h-2.5 w-2.5 flex-shrink-0 rounded-full bg-orange-400"></div>
            <span>Degraded</span>
          </div>
          
    <!-- Rate Limited Status -->
          <div
            class="flex items-center space-x-1.5 text-xs text-gray-300"
            title="Rate limited, in cooldown (takes priority over circuit open)"
          >
            <div class="h-2.5 w-2.5 flex-shrink-0 rounded-full bg-purple-400"></div>
            <span>Rate Limited</span>
          </div>
          
    <!-- Circuit Open Status -->
          <div
            class="flex items-center space-x-1.5 text-xs text-gray-300"
            title="Circuit breaker open, complete failure"
          >
            <div class="h-2.5 w-2.5 flex-shrink-0 rounded-full bg-red-500"></div>
            <span>Circuit Open</span>
          </div>
        </div>
      </div>

      <div
        class="flex items-center space-x-1.5 text-xs text-gray-300 pl-1"
        title="Provider supports WebSocket subscriptions"
      >
        <div class="flex h-3 w-3 flex-shrink-0 items-center justify-center rounded-full bg-blue-600">
          <svg class="h-2 w-2 text-white" fill="currentColor" viewBox="0 0 24 24">
            <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.94-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z" />
          </svg>
        </div>
        <span>WS</span>
      </div>
    </div>
    """
  end
end
