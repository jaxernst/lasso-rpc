defmodule LivechainWeb.Components.NetworkStatusLegend do
  use Phoenix.Component

  def legend(assigns) do
    ~H"""
    <div class="bg-gray-900/20 border-gray-700/50 absolute bottom-4 left-1/2 -translate-x-1/2 transform rounded-lg border p-4 shadow-xl backdrop-blur-sm">
      <div class="flex justify-center gap-5">
        <!-- Healthy Status -->
        <div class="flex items-center space-x-1.5 text-xs text-gray-300">
          <div class="h-2.5 w-2.5 flex-shrink-0 rounded-full bg-emerald-400"></div>
          <span>Healthy</span>
        </div>
        
    <!-- Warning States -->

        <div class="flex items-center space-x-1.5 text-xs text-gray-300">
          <div class="h-2.5 w-2.5 flex-shrink-0 rounded-full bg-gray-300"></div>
          <span>Connecting</span>
        </div>
        
    <!-- Problem States -->
        <div class="flex items-center space-x-1.5 text-xs text-gray-300">
          <div class="h-2.5 w-2.5 flex-shrink-0 rounded-full bg-yellow-400"></div>
          <span>Unstable</span>
        </div>
        <div class="flex items-center space-x-1.5 text-xs text-gray-300">
          <div class="h-2.5 w-2.5 flex-shrink-0 rounded-full bg-orange-400"></div>
          <span>Unhealthy</span>
        </div>
        <div class="flex items-center space-x-1.5 text-xs text-gray-300">
          <div class="h-2.5 w-2.5 flex-shrink-0 rounded-full bg-red-500"></div>
          <span>Circuit Open - Failed</span>
        </div>
      </div>
    </div>
    """
  end
end
