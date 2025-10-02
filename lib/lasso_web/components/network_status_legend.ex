defmodule LassoWeb.Components.NetworkStatusLegend do
  use Phoenix.Component

  def legend(assigns) do
    ~H"""
    <div class="bg-gray-900/20 border-gray-700/50 absolute bottom-4 left-1/2 -translate-x-1/2 transform rounded-lg border p-4 shadow-xl backdrop-blur-sm">
      <div class="flex justify-center gap-3">
        <!-- Healthy Status -->
        <div class="flex items-center space-x-1.5 text-xs text-gray-300">
          <div class="h-2.5 w-2.5 flex-shrink-0 rounded-full bg-emerald-400"></div>
          <span>Healthy</span>
        </div>
        
    <!-- Connecting/Recovery States -->
        <div class="flex items-center space-x-1.5 text-xs text-gray-300">
          <div class="h-2.5 w-2.5 flex-shrink-0 rounded-full bg-amber-400"></div>
          <span>Connecting</span>
        </div>

        <div class="flex items-center space-x-1.5 text-xs text-gray-300">
          <div class="h-2.5 w-2.5 flex-shrink-0 rounded-full bg-blue-400"></div>
          <span>Recovering</span>
        </div>
        
    <!-- Problem States -->
        <div class="flex items-center space-x-1.5 text-xs text-gray-300">
          <div class="h-2.5 w-2.5 flex-shrink-0 rounded-full bg-orange-400"></div>
          <span>Unhealthy</span>
        </div>

        <div class="flex items-center space-x-1.5 text-xs text-gray-300">
          <div class="h-2.5 w-2.5 flex-shrink-0 rounded-full bg-purple-400"></div>
          <span>Rate Limited</span>
        </div>

        <div class="flex items-center space-x-1.5 text-xs text-gray-300">
          <div class="h-2.5 w-2.5 flex-shrink-0 rounded-full bg-red-500"></div>
          <span>Circuit Open</span>
        </div>

        <div class="flex items-center space-x-1.5 text-xs text-gray-300">
          <div class="h-2.5 w-2.5 flex-shrink-0 rounded-full bg-gray-400"></div>
          <span>Unknown</span>
        </div>
      </div>
    </div>
    """
  end
end
