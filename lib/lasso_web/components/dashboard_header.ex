defmodule LassoWeb.Components.DashboardHeader do
  @moduledoc "Dashboard header component with tab navigation."
  use LassoWeb, :html

  attr(:active_tab, :string, required: true, doc: "currently active tab")
  attr(:vm_metrics_enabled, :boolean, default: true, doc: "whether VM metrics tab is enabled")
  attr(:profiles, :list, default: [], doc: "list of available profiles")
  attr(:selected_profile, :string, default: nil, doc: "currently selected profile")

  def header(assigns) do
    tabs = [
      %{id: "overview", label: "Dashboard"},
      %{id: "metrics", label: "Metrics"}
    ]

    tabs =
      if assigns.vm_metrics_enabled, do: tabs ++ [%{id: "system", label: "System"}], else: tabs

    assigns = assign(assigns, :tabs, tabs)

    ~H"""
    <div class={[
      "relative z-20 flex-shrink-0 bg-[#181e2c]",
      if(@active_tab == "docs", do: "", else: "border-gray-700/50 border-b")
    ]}>
      <div class="relative flex flex-wrap items-center justify-between gap-3 px-4 py-3 md:px-6">
        <!-- Left: Logo -->
        <a href="/" class="group flex items-center gap-2">
          <img src={~p"/images/brand/lasso-loop-mark.svg"} alt="" class="h-5 w-auto opacity-90" />
          <span class="text-lg font-semibold tracking-tight text-white/90">Lasso</span>
          <span class="self-start mt-1 text-[7px] font-bold tracking-[0.14em] text-purple-400/80">
            RPC
          </span>
          <span class="ml-2 hidden text-[10px] text-gray-500 sm:inline">Self-hosted</span>
        </a>
        
    <!-- Right: Nav Tabs + Divider + Profile Selector -->
        <div class="flex items-center gap-1">
          <!-- Nav Tabs -->
          <nav class="flex items-center gap-1" aria-label="Dashboard views">
            <%= for tab <- @tabs do %>
              <button
                phx-click="switch_tab"
                phx-value-tab={tab.id}
                aria-current={if @active_tab == tab.id, do: "page", else: nil}
                class={[
                  "relative px-2 py-2 text-xs md:px-3 md:text-sm font-medium transition-colors",
                  if(@active_tab == tab.id,
                    do: "text-white",
                    else: "text-gray-400 hover:text-gray-200"
                  )
                ]}
              >
                {tab.label}
                <%= if @active_tab == tab.id do %>
                  <span class="absolute inset-x-0 -bottom-3 h-0.5 rounded-full bg-purple-500"></span>
                <% end %>
              </button>
            <% end %>
          </nav>

          <%= if @selected_profile && length(@profiles) > 0 do %>
            <!-- Vertical Divider -->
            <div class="bg-gray-700/60 mx-3 hidden h-6 w-px md:block"></div>

            <LassoWeb.Components.ProfileSelector.profile_selector
              profiles={@profiles}
              selected_profile={@selected_profile}
            />
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
