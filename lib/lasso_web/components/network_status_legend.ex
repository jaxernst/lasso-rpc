defmodule LassoWeb.Components.NetworkStatusLegend do
  @moduledoc """
  Network status legend component showing provider health indicators.

  Transport is shown alongside status: a provider's connector is a single trace
  for HTTP and a doubled trace when it also serves WebSocket subscriptions.

  Status hierarchy (ordered by severity):
  1. Circuit Open (red) - Complete failure, removed from rotation
  2. Rate Limited (purple) - Quota or rate cooldown
  3. Degraded (orange) - One or more routes are impaired; others may remain available
  4. Recovering (amber) - WS recovering or circuit testing recovery
  5. Lagging (blue) - Lagging blocks
  6. Healthy (green) - Fully operational
  """
  use Phoenix.Component

  def legend(assigns) do
    ~H"""
    <div class="absolute bottom-4 right-4 hidden items-center gap-3 md:flex lg:right-6 xl:left-1/2 xl:right-auto xl:-translate-x-1/2">
      <div class="bg-gray-900/20 border-gray-700/50 rounded-lg border px-4 py-2 shadow-xl backdrop-blur-sm">
        <div class="flex flex-wrap justify-end gap-3 xl:justify-center">
          <!-- Healthy Status -->
          <div
            class="flex items-center space-x-1.5 whitespace-nowrap text-xs text-gray-300"
            title="Available evidence shows no current impairment in the selected scope; this does not verify every RPC method"
          >
            <div class="h-2.5 w-2.5 flex-shrink-0 rounded-[2px] bg-emerald-400"></div>
            <span>Healthy</span>
          </div>
          
    <!-- Lagging Status -->
          <div
            class="flex items-center space-x-1.5 whitespace-nowrap text-xs text-gray-300"
            title="Fresh head evidence is behind the profile's qualified reference beyond its configured tolerance"
          >
            <div class="h-2.5 w-2.5 flex-shrink-0 rounded-[2px] bg-sky-400"></div>
            <span>Lagging</span>
          </div>
          
    <!-- Recovering Status (covers both WS recovery and circuit half-open) -->
          <div
            class="flex items-center space-x-1.5 whitespace-nowrap text-xs text-gray-300"
            title="Connection recovering or circuit testing recovery"
          >
            <div class="h-2.5 w-2.5 flex-shrink-0 rounded-[2px] bg-amber-400"></div>
            <span>Recovering</span>
          </div>
          
    <!-- Degraded Status -->
          <div
            class="flex items-center space-x-1.5 whitespace-nowrap text-xs text-gray-300"
            title="One or more regions or transports are impaired; other routes may remain available"
          >
            <div class="h-2.5 w-2.5 flex-shrink-0 rounded-[2px] bg-orange-400"></div>
            <span>Degraded</span>
          </div>
          
    <!-- Rate Limited Status -->
          <div
            class="flex items-center space-x-1.5 whitespace-nowrap text-xs text-gray-300"
            title="Rate limited or quota exhausted, in cooldown"
          >
            <div class="h-2.5 w-2.5 flex-shrink-0 rounded-[2px] bg-purple-400"></div>
            <span>Rate Limited</span>
          </div>
          
    <!-- Circuit Open Status -->
          <div
            class="flex items-center space-x-1.5 whitespace-nowrap text-xs text-gray-300"
            title="All supported routes in the selected scope have open circuits and are excluded from normal routing"
          >
            <div class="h-2.5 w-2.5 flex-shrink-0 rounded-[2px] bg-red-500"></div>
            <span>Circuit Open</span>
          </div>
        </div>
      </div>

      <div class="bg-gray-900/20 border-gray-700/50 flex items-center gap-3 rounded-lg border px-3 py-2 shadow-xl backdrop-blur-sm">
        <div
          class="flex items-center space-x-1.5 whitespace-nowrap text-xs text-gray-300"
          title="HTTP only, no WebSocket subscriptions"
        >
          <svg class="h-2.5 w-4 flex-shrink-0" viewBox="0 0 16 10" aria-hidden="true">
            <path d="M0 5h16" stroke="#9ca3af" stroke-width="1.5" />
          </svg>
          <span>HTTP</span>
        </div>

        <div
          class="flex items-center space-x-1.5 whitespace-nowrap text-xs text-gray-300"
          title="WebSocket transport is configured, drawn as a doubled connector; subscription support is shown separately"
        >
          <svg class="h-2.5 w-4 flex-shrink-0" viewBox="0 0 16 10" aria-hidden="true">
            <path d="M0 2.5h16M0 7.5h16" stroke="#9ca3af" stroke-width="1.5" />
          </svg>
          <span>WebSocket</span>
        </div>
      </div>
    </div>
    """
  end
end
