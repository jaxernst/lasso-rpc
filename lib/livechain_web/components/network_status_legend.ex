defmodule LivechainWeb.Components.NetworkStatusLegend do
  use Phoenix.Component

  def legend(assigns) do
    ~H"""
    <!-- Network Status Legend (positioned relative to full dashboard) -->
    <div class="bg-gray-900/95 border-gray-700/50 absolute right-4 bottom-4 z-30 min-w-max rounded-lg border p-4 shadow-xl backdrop-blur-sm">
      <h4 class="mb-3 text-xs font-semibold text-white">Provider Status</h4>
      <div class="space-y-2">
        <!-- Healthy Status -->
        <div class="flex items-center space-x-2 text-xs text-gray-300">
          <div class="h-2.5 w-2.5 flex-shrink-0 rounded-full bg-emerald-400"></div>
          <span>Healthy</span>
        </div>
        
    <!-- Warning States -->
        <div class="flex items-center space-x-2 text-xs text-gray-300">
          <div class="h-2.5 w-2.5 flex-shrink-0 rounded-full bg-blue-400"></div>
          <span>Recovering</span>
        </div>
        <div class="flex items-center space-x-2 text-xs text-gray-300">
          <div class="h-2.5 w-2.5 flex-shrink-0 rounded-full bg-gray-300"></div>
          <span>Connecting</span>
        </div>
        <div class="flex items-center space-x-2 text-xs text-gray-300">
          <div class="h-2.5 w-2.5 flex-shrink-0 rounded-full bg-purple-400"></div>
          <span>Rate Limited</span>
        </div>
        
    <!-- Problem States -->
        <div class="flex items-center space-x-2 text-xs text-gray-300">
          <div class="h-2.5 w-2.5 flex-shrink-0 rounded-full bg-yellow-400"></div>
          <span>Unstable</span>
        </div>
        <div class="flex items-center space-x-2 text-xs text-gray-300">
          <div class="h-2.5 w-2.5 flex-shrink-0 rounded-full bg-orange-400"></div>
          <span>Unhealthy</span>
        </div>
        <div class="flex items-center space-x-2 text-xs text-gray-300">
          <div class="h-2.5 w-2.5 flex-shrink-0 rounded-full bg-red-400"></div>
          <span>Failed</span>
        </div>
        <div class="flex items-center space-x-2 text-xs text-gray-300">
          <div class="h-2.5 w-2.5 flex-shrink-0 rounded-full bg-red-500"></div>
          <span>Circuit Open</span>
        </div>
      </div>
    </div>
    """
  end
end
