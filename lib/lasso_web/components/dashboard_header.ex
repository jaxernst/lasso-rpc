defmodule LassoWeb.Components.DashboardHeader do
  use Phoenix.Component
  import LassoWeb.CoreComponents

  attr(:active_tab, :string, required: true, doc: "currently active tab")

  def header(assigns) do
    ~H"""
    <!-- Header -->
    <div class={["relative flex-shrink-0", if(@active_tab == "docs", do: "", else: "border-gray-700/50 border-b")]}>
      <div class="relative flex items-center justify-between px-6 py-4">
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
                  <div class="flex gap-1 text-lg font-bold text-white">
                    Lasso RPC
                    <div class="text-[9px] ml-.5 -translate-y-1.5 align-super text-emerald-400">
                      ● LIVE
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
        
    <!-- Navigation and Actions -->
        <div class="flex items-center gap-4">
          <!-- Home / Landing -->
          <a
            href="/docs"
            class={["group bg-gray-900/50 border-gray-700/50 relative flex h-10 w-10 items-center justify-center rounded-lg border backdrop-blur-sm transition-all hover:border-purple-500/60 hover:bg-purple-500/10", if(@active_tab == "docs",
    do: "border-purple-500/80 bg-purple-500/10 shadow-[0_0_20px_rgba(168,85,247,0.35)]",
    else: "")]}
            title="Home"
          >
            <div class="from-purple-500/0 to-purple-500/0 absolute inset-0 rounded-lg bg-gradient-to-br opacity-0 transition-opacity group-hover:from-purple-500/10 group-hover:to-purple-500/5 group-hover:opacity-100">
            </div>
            <svg
              class="relative z-10 h-5 w-5 text-gray-400 transition-colors group-hover:text-purple-400"
              fill="none"
              stroke="currentColor"
              viewBox="0 0 24 24"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M3 9.75L12 3l9 6.75V20a1 1 0 01-1 1h-5.25a.75.75 0 01-.75-.75V15a1 1 0 00-1-1H11a1 1 0 00-1 1v5.25A.75.75 0 019.25 21H4a1 1 0 01-1-1V9.75z"
              />
            </svg>
          </a>
          
    <!-- Navigation Tabs -->
          <.tab_switcher
            id="main-tabs"
            tabs={[
              %{id: "overview", label: "Dashboard", icon: "M13 10V3L4 14h7v7l9-11h-7z"},
              %{
                id: "metrics",
                label: "Provider Metrics",
                icon:
                  "M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z"
              },
              %{
                id: "system",
                label: "System Metrics",
                icon:
                  "M9 20l-5.447-2.724A1 1 0 013 16.382V5.618a1 1 0 011.447-.894L9 7m0 13l6-3m-6 3V7m6 10l4.553 2.276A1 1 0 0021 18.382V7.618a1 1 0 00-1.447-.894L15 4m0 13V4m-6 3l6-3"
              }
            ]}
            active_tab={@active_tab}
          />
        </div>
      </div>
    </div>
    """
  end
end
