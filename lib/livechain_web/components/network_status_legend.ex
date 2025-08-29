defmodule LivechainWeb.Components.NetworkStatusLegend do
  use Phoenix.Component

  def legend(assigns) do
    ~H"""
    <!-- Network Status Legend (positioned relative to full dashboard) -->
    <div class="bg-gray-900/95 absolute right-4 bottom-4 z-30 min-w-max rounded-lg border border-gray-600 p-4 shadow-xl backdrop-blur-sm">
      <h4 class="mb-3 text-xs font-semibold text-white">Network Status</h4>
      <div class="space-y-2.5">
        <!-- Provider Status -->
        <div class="flex items-center space-x-2 text-xs text-gray-300">
          <div class="h-3 w-3 flex-shrink-0 rounded-full bg-emerald-400"></div>
          <span>Connected</span>
        </div>
        <div class="flex items-center space-x-2 text-xs text-gray-300">
          <div class="h-3 w-3 flex-shrink-0 rounded-full bg-yellow-400"></div>
          <span>Connecting/Reconnecting</span>
        </div>
        <div class="flex items-center space-x-2 text-xs text-gray-300">
          <div class="h-3 w-3 flex-shrink-0 rounded-full bg-red-400"></div>
          <span>Disconnected</span>
        </div>
        <!-- Racing Flag Indicator -->
        <div class="flex items-center space-x-2 text-xs text-gray-300">
          <div class="relative flex flex-shrink-0 items-center">
            <div class="h-3 w-3 rounded-full bg-purple-600"></div>
            <svg
              class="absolute h-2.5 w-2.5 text-yellow-300"
              fill="currentColor"
              viewBox="0 0 24 24"
              style="top: 0.25px; left: 0.25px;"
            >
              <path d="M3 3v18l7-3 7 3V3H3z" />
            </svg>
          </div>
          <span>Fastest average latency</span>
        </div>
        <!-- Reconnect Attempts Badge -->
        <div class="mt-3 flex items-center space-x-2 border-t border-gray-700 pt-2.5 text-xs text-gray-300">
          <div class="relative flex flex-shrink-0 items-center">
            <div class="h-3 w-3 rounded-full bg-gray-600"></div>
            <div class="absolute -top-1 -right-1 flex h-4 w-4 items-center justify-center rounded-full bg-yellow-500">
              <span class="text-[10px] font-bold leading-none text-white">3</span>
            </div>
          </div>
          <span>Reconnect attempts</span>
        </div>
      </div>
    </div>
    """
  end
end