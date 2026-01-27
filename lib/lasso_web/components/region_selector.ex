defmodule LassoWeb.Components.RegionSelector do
  @moduledoc """
  Reusable region selector component for switching between aggregate and per-region views.

  Supports highlighting regions with issues (e.g., open circuit breakers) via the
  `regions_with_issues` attribute.

  Automatically switches from horizontal tabs to a dropdown selector when the number
  of regions exceeds a configurable threshold.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  attr(:id, :string, required: true)
  attr(:regions, :list, required: true)
  attr(:selected, :string, required: true)
  attr(:show_aggregate, :boolean, default: true)
  attr(:target, :any, default: nil)
  attr(:event, :string, default: "select_region")
  attr(:show_count, :boolean, default: true)
  attr(:regions_with_issues, :list, default: [])
  attr(:mode, :atom, default: :auto, values: [:auto, :tabs, :dropdown])
  attr(:threshold, :integer, default: 3)

  def region_selector(assigns) do
    assigns =
      assigns
      |> assign(:active_count, length(assigns.regions))
      |> assign(:effective_mode, compute_effective_mode(assigns))
      |> assign(:issues_count, length(assigns.regions_with_issues))

    case assigns.effective_mode do
      :tabs -> render_tabs(assigns)
      :dropdown -> render_dropdown(assigns)
    end
  end

  defp compute_effective_mode(assigns) do
    case assigns.mode do
      :tabs ->
        :tabs

      :dropdown ->
        :dropdown

      :auto ->
        total_items = length(assigns.regions) + if(assigns.show_aggregate, do: 1, else: 0)
        if total_items > assigns.threshold, do: :dropdown, else: :tabs
    end
  end

  defp render_tabs(assigns) do
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

  defp render_dropdown(assigns) do
    selected_region_has_issues =
      assigns.selected != "aggregate" and assigns.selected in assigns.regions_with_issues

    assigns = assign(assigns, :selected_region_has_issues, selected_region_has_issues)

    ~H"""
    <div class="flex items-stretch border-gray-800" id={@id}>
      <div class="flex-1 min-w-0 flex items-stretch">
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

        <div class={[
          "relative border-r border-gray-800",
          if(@selected == "aggregate", do: "border-b", else: "")
        ]}>
          <button
            id={"#{@id}-trigger"}
            phx-click={toggle_dropdown(@id)}
            aria-haspopup="listbox"
            aria-expanded="false"
            aria-controls={"#{@id}-panel"}
            class={[
              "px-4 py-2 text-xs font-medium transition-all border-gray-800 border-t whitespace-nowrap",
              "flex items-center gap-2 hover:bg-gray-800/30",
              if(@selected != "aggregate",
                do: "text-sky-300 bg-gray-900/50",
                else: "text-gray-500"
              ),
              @selected_region_has_issues && "text-red-400"
            ]}
          >
            <span class="capitalize">
              {if @selected == "aggregate", do: "Select region...", else: @selected}
            </span>
            <svg class="h-3 w-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M19 9l-7 7-7-7"
              />
            </svg>
          </button>

          <.dropdown_panel
            id={@id}
            regions={@regions}
            selected={@selected}
            target={@target}
            event={@event}
            regions_with_issues={@regions_with_issues}
          />
        </div>

        <div class="flex-1 border-b border-gray-800"></div>
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

  attr(:id, :string, required: true)
  attr(:regions, :list, required: true)
  attr(:selected, :string, required: true)
  attr(:target, :any, default: nil)
  attr(:event, :string, default: "select_region")
  attr(:regions_with_issues, :list, default: [])

  defp dropdown_panel(assigns) do
    ~H"""
    <div
      id={"#{@id}-panel"}
      phx-click-away={hide_dropdown(@id)}
      role="listbox"
      class={[
        "absolute top-full left-0 mt-2 min-w-[160px]",
        "ring-black/50 rounded-lg border border-gray-700 bg-gray-900 shadow-xl ring-1",
        "z-50 overflow-hidden",
        "hidden"
      ]}
    >
      <button
        :for={region <- @regions}
        phx-click={hide_dropdown(@id, JS.push(@event, value: %{region: region}, target: @target))}
        role="option"
        aria-selected={to_string(region == @selected)}
        class={[
          "flex w-full items-center justify-between gap-3 px-3 py-3 text-left text-xs capitalize",
          "transition-colors hover:bg-gray-800",
          region == @selected && "bg-sky-500/10 text-sky-300",
          region != @selected && "text-gray-300",
          region in @regions_with_issues && region != @selected && "text-red-400"
        ]}
      >
        <span>{region}</span>
        <div class="flex items-center gap-2">
          <span
            :if={region in @regions_with_issues}
            class="w-1.5 h-1.5 rounded-full bg-red-500 flex-shrink-0"
          />
          <svg
            :if={region == @selected}
            class="h-3.5 w-3.5 flex-none text-sky-400"
            fill="currentColor"
            viewBox="0 0 20 20"
          >
            <path
              fill-rule="evenodd"
              d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z"
              clip-rule="evenodd"
            />
          </svg>
        </div>
      </button>
    </div>
    """
  end

  defp toggle_dropdown(id) do
    %JS{}
    |> JS.toggle(
      to: "##{id}-panel",
      in:
        {"transition ease-out duration-200", "opacity-0 -translate-y-1",
         "opacity-100 translate-y-0"},
      out:
        {"transition ease-in duration-150", "opacity-100 translate-y-0",
         "opacity-0 -translate-y-1"}
    )
    |> JS.toggle_attribute({"aria-expanded", "true", "false"}, to: "##{id}-trigger")
  end

  defp hide_dropdown(id, js \\ %JS{}) do
    js
    |> JS.hide(
      to: "##{id}-panel",
      transition:
        {"transition ease-in duration-150", "opacity-100 translate-y-0",
         "opacity-0 -translate-y-1"}
    )
    |> JS.set_attribute({"aria-expanded", "false"}, to: "##{id}-trigger")
  end
end
