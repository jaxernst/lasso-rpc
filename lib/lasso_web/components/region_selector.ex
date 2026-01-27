defmodule LassoWeb.Components.RegionSelector do
  @moduledoc """
  Reusable region selector component for switching between aggregate and per-region views.

  Supports highlighting regions with issues (e.g., open circuit breakers) via the
  `regions_with_issues` attribute.
  """
  use Phoenix.Component

  attr(:id, :string, required: true)
  attr(:regions, :list, required: true)
  attr(:selected, :string, required: true)
  attr(:show_aggregate, :boolean, default: true)
  attr(:target, :any, default: nil)
  attr(:event, :string, default: "select_region")
  attr(:show_count, :boolean, default: true)
  attr(:regions_with_issues, :list, default: [])

  def region_selector(assigns) do
    assigns = assign(assigns, :active_count, length(assigns.regions))

    ~H"""
    <div class="flex items-stretch border-gray-800" id={@id}>
      <div class="flex-1 min-w-0 overflow-x-auto">
        <div class="flex flex-nowrap flex-shrink-0">
          <button
            :if={@show_aggregate}
            phx-click={@event}
            phx-value-region="aggregate"
            phx-target={@target}
            class={[
              "px-4 py-2 text-xs font-medium transition-all border-gray-800 border-t relative whitespace-nowrap",
              if(@selected == "aggregate",
                do: "text-sky-300 border-r bg-gray-900/50",
                else: "text-gray-500 border-r border-b hover:text-gray-300 hover:bg-gray-800/30"
              )
            ]}
          >
            Aggregate
            <span
              :if={length(@regions_with_issues) > 0}
              class="absolute top-1.5 right-1.5 w-1.5 h-1.5 rounded-full bg-red-500"
            />
          </button>
          <button
            :for={region <- @regions}
            phx-click={@event}
            phx-value-region={region}
            phx-target={@target}
            class={[
              "px-4 py-2 text-xs font-medium transition-all border-gray-800 border-t capitalize relative whitespace-nowrap",
              if(@selected == region,
                do: "text-sky-300 border-r bg-gray-900/50",
                else: "text-gray-500 border-r border-b hover:text-gray-300 hover:bg-gray-800/30"
              ),
              if(region in @regions_with_issues and @selected != region,
                do: "text-red-400",
                else: ""
              )
            ]}
          >
            {region}
            <span
              :if={region in @regions_with_issues}
              class="absolute top-1.5 right-1.5 w-1.5 h-1.5 rounded-full bg-red-500"
            />
          </button>
        </div>
      </div>
      <div
        :if={@show_count}
        class="px-4 py-2 text-xs text-gray-500 border-b border-gray-800 text-right flex-shrink-0"
      >
        {@active_count}/{@active_count} regions
      </div>
    </div>
    """
  end
end
