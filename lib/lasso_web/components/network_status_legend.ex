defmodule LassoWeb.Components.NetworkStatusLegend do
  @moduledoc """
  Network status legend component showing provider health indicators.

  Status hierarchy (ordered by severity):
  1. Rate Limited (🟣) - In cooldown (highest priority)
  2. Circuit Open (🔴) - Complete failure
  3. Degraded (🟠) - Has issues but trying
  4. Testing Recovery (🔵) - Circuit testing
  5. Reconnecting (🟡) - WS reconnecting
  6. Syncing (🔵) - Lagging blocks
  7. Healthy (🟢) - Fully operational
  """
  use Phoenix.Component

  def legend(assigns) do
    ~H"""
    <div class="bg-gray-900/20 border-gray-700/50 absolute bottom-4 left-1/2 -translate-x-1/2 transform rounded-lg border p-4 shadow-xl backdrop-blur-sm">
      <div class="flex justify-center gap-3 flex-wrap">
        <!-- Healthy Status -->
        <div class="flex items-center space-x-1.5 text-xs text-gray-300" title="All systems operational and synced">
          <div class="h-2.5 w-2.5 flex-shrink-0 rounded-full bg-emerald-400"></div>
          <span>Healthy</span>
        </div>

        <!-- Syncing Status -->
        <div class="flex items-center space-x-1.5 text-xs text-gray-300" title="Responsive but lagging blocks">
          <div class="h-2.5 w-2.5 flex-shrink-0 rounded-full bg-sky-400"></div>
          <span>Syncing</span>
        </div>

        <!-- Reconnecting Status -->
        <div class="flex items-center space-x-1.5 text-xs text-gray-300" title="WebSocket connection lost, reconnecting">
          <div class="h-2.5 w-2.5 flex-shrink-0 rounded-full bg-amber-400"></div>
          <span>Reconnecting</span>
        </div>

        <!-- Testing Recovery Status -->
        <div class="flex items-center space-x-1.5 text-xs text-gray-300" title="Circuit breaker testing recovery">
          <div class="h-2.5 w-2.5 flex-shrink-0 rounded-full bg-blue-400"></div>
          <span>Testing Recovery</span>
        </div>

        <!-- Degraded Status -->
        <div class="flex items-center space-x-1.5 text-xs text-gray-300" title="Experiencing issues but still trying">
          <div class="h-2.5 w-2.5 flex-shrink-0 rounded-full bg-orange-400"></div>
          <span>Degraded</span>
        </div>

        <!-- Rate Limited Status -->
        <div class="flex items-center space-x-1.5 text-xs text-gray-300" title="Rate limited, in cooldown (takes priority over circuit open)">
          <div class="h-2.5 w-2.5 flex-shrink-0 rounded-full bg-purple-400"></div>
          <span>Rate Limited</span>
        </div>

        <!-- Circuit Open Status -->
        <div class="flex items-center space-x-1.5 text-xs text-gray-300" title="Circuit breaker open, complete failure">
          <div class="h-2.5 w-2.5 flex-shrink-0 rounded-full bg-red-500"></div>
          <span>Circuit Open</span>
        </div>
      </div>
    </div>
    """
  end
end
