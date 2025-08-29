defmodule LivechainWeb.Components.DashboardHeader do
  use Phoenix.Component
  import LivechainWeb.CoreComponents

  attr :active_tab, :string, required: true, doc: "currently active tab"

  def header(assigns) do
    ~H"""
    <!-- Header -->
    <div class="border-gray-700/50 relative flex-shrink-0 border-b">
      <div class="relative flex items-center justify-between p-6">
        <!-- Title Section -->
        <div class="flex items-center space-x-4">
          <div class="relative">
            <div class="absolute inset-0 rounded-2xl bg-gradient-to-r from-purple-600 to-purple-400 opacity-10 blur-xl">
            </div>
            <div class="relative rounded-2xl ">
              <div class="flex items-center space-x-3">
                <div class="relative">
                  <div class="flex h-8 w-8 items-center justify-center rounded-lg bg-gradient-to-br from-purple-400 to-purple-600 shadow-lg">
                    <svg
                      class="h-5 w-5 text-white"
                      fill="none"
                      stroke="currentColor"
                      viewBox="0 0 24 24"
                    >
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2"
                        d="M13 10V3L4 14h7v7l9-11h-7z"
                      />
                    </svg>
                  </div>
                  <div class="absolute inset-0 animate-ping rounded-lg bg-gradient-to-br from-purple-400 to-purple-600 opacity-20">
                  </div>
                </div>
                <div>
                  <div class="text-lg font-bold text-white">Lasso RPC</div>
                  <div class="text-xs text-gray-400">
                    <span class="text-emerald-400">LIVE</span> • Orchestration Dashboard
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>

        <!-- Navigation Tabs -->
        <.tab_switcher
          id="main-tabs"
          tabs={[
            %{id: "overview", label: "Dashboard", icon: "M13 10V3L4 14h7v7l9-11h-7z"},
            %{id: "benchmarks", label: "Benchmarks", icon: "M3 3h18M9 7l6-3M9 17l6-3"},
            %{id: "system", label: "System", icon: "M15 4m0 13V4m-6 3l6-3"}
          ]}
          active_tab={@active_tab}
        />
      </div>
    </div>
    """
  end
end