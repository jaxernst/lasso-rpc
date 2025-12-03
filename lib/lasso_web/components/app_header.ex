defmodule LassoWeb.Components.DashboardHeader do
  use Phoenix.Component
  import LassoWeb.CoreComponents

  attr(:active_tab, :string, required: true, doc: "currently active tab")

  def header(assigns) do
    ~H"""
    <div class={["relative z-20 flex-shrink-0 transition-all duration-500 ease-in-out", if(@active_tab == "docs", do: "", else: "animate-fade-in-border border-gray-700/50 border-b")]}>
      <div class="relative flex items-center justify-between px-6 py-4">
        <!-- Title Section -->
        <div class="flex items-center space-x-4">
          <div class="relative">
            <div class="absolute inset-0 rounded-2xl bg-gradient-to-r from-purple-600 to-purple-400 opacity-5 blur-lg">
            </div>
            <div class="relative rounded-2xl ">
              <a href="/" class="group flex cursor-pointer items-center space-x-3">
                <div class="relative">
                  <svg
                    class="h-6 w-6 transition-transform group-hover:rotate-6 group-hover:scale-110 sm:h-7 sm:w-7"
                    viewBox="0 0 24 24"
                    fill="none"
                  >
                    <path
                      d="M13 2L4 14h7v8l9-12h-7V2z"
                      fill="url(#lightning-gradient)"
                    />
                    <defs>
                      <linearGradient id="lightning-gradient" x1="0%" y1="0%" x2="100%" y2="100%">
                        <stop offset="0%" stop-color="#a78bfa" />
                        <stop offset="100%" stop-color="#7c3aed" />
                      </linearGradient>
                    </defs>
                  </svg>
                </div>
                <div>
                  <div class="flex gap-1 text-2xl font-bold text-white sm:text-3xl">
                    Lasso
                    <div class="ml-.5 text-[9px] text-emerald-400/90 flex -translate-y-1.5 items-center gap-1 align-super">
                      <span class="relative flex h-2 w-2">
                        <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-emerald-400 opacity-75">
                        </span>
                        <span class="relative inline-flex h-2 w-2 rounded-full bg-emerald-500"></span>
                      </span>
                      RPC
                    </div>
                  </div>
                </div>
              </a>
            </div>
          </div>
        </div>
        
    <!-- Navigation Tabs -->
        <div class="flex items-center gap-4">
          <div class="hidden md:block">
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
          
    <!-- Navigation and Actions -->
          <div class="flex items-center gap-4">
            <!-- Home / Landing -->
            <a
              href="/"
              class={["group bg-gray-900/60 border-gray-700/60 relative flex h-10 w-10 items-center justify-center rounded-lg border backdrop-blur-sm transition-colors hover:border-purple-500/60 hover:bg-purple-500/10", if(@active_tab == "docs",
    do: "border-purple-500/80 bg-purple-500/10",
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
          </div>
        </div>
      </div>
    </div>
    """
  end
end
