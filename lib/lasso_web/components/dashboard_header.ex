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
      "relative z-20 flex-shrink-0 transition-all duration-500 ease-in-out",
      if(@active_tab == "docs", do: "", else: "border-gray-700/50 border-b")
    ]}>
      <div class="relative flex items-center justify-between px-6 py-3">
        <!-- Left: Logo -->
        <a href="/" class="group flex items-center gap-2">
          <img
            src={~p"/images/lasso-logo.png"}
            alt="Lasso Logo"
            class="h-8 w-8 transition-transform group-hover:rotate-6 group-hover:scale-110"
          />
          <span class="text-2xl font-bold text-white">Lasso</span>
          <span class="text-[8px] text-emerald-400/90 flex -translate-y-1 items-center gap-1 font-medium">
            <span class="relative flex h-1.5 w-1.5">
              <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-emerald-400 opacity-75">
              </span>
              <span class="relative inline-flex h-1.5 w-1.5 rounded-full bg-emerald-500"></span>
            </span>
            RPC
          </span>
        </a>
        
    <!-- Right: Nav Tabs + Divider + Profile Selector -->
        <div class="flex items-center gap-1">
          <!-- Nav Tabs -->
          <nav class="hidden items-center gap-1 md:flex">
            <%= for tab <- @tabs do %>
              <button
                phx-click="switch_tab"
                phx-value-tab={tab.id}
                class={[
                  "relative px-3 py-2 text-sm font-medium transition-colors",
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
              show_create_cta={true}
            />
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
