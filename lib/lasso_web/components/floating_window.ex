defmodule LassoWeb.Components.FloatingWindow do
  @moduledoc """
  Composable floating window component library for building collapsible,
  positioned overlay panels with consistent styling and behavior.

  ## Design Philosophy

  This module provides functional, composable primitives for building floating
  windows rather than a single monolithic component. This allows for:

  - Flexible content composition
  - Consistent styling and behavior
  - Easy customization per use case
  - Minimal duplication

  ## Core Components

  - `container/1` - Outer positioned wrapper
  - `window/1` - Main window with glass morphism styling
  - `header/1` - Collapsible header with status indicators
  - `body/1` - Scrollable content area
  - `footer/1` - Fixed footer for actions
  - `section/1` - Content section with optional borders

  ## Usage Example

  ```elixir
  <.floating_window
    id="my-window"
    position={:top_right}
    collapsed={@collapsed}
    on_toggle="toggle_window"
  >
    <:header>
      <.status_indicator status={:connected} />
      <span>My Window Title</span>
      <%= if @collapsed do %>
        <span class="text-xs text-gray-400">{@preview_info}</span>
      <% end %>
    </:header>

    <:body>
      <!-- Your content here -->
    </:body>

    <:footer>
      <button>Action</button>
    </:footer>
  </.floating_window>
  ```
  """

  use Phoenix.Component

  @type position :: :top_left | :top_right | :bottom_left | :bottom_right | :center
  @type size :: :sm | :md | :lg | :xl | :auto
  @type status :: :healthy | :degraded | :error | :info

  # ============================================================================
  # Main Floating Window Component
  # ============================================================================

  @doc """
  Main floating window component that composes container, window, header, body, and footer.

  ## Attributes

  - `id` - Required unique identifier
  - `position` - Window position (:top_left, :top_right, :bottom_left, :bottom_right)
  - `collapsed` - Boolean controlling collapsed state
  - `on_toggle` - Event name for toggle action (optional)
  - `size` - Size preset when collapsed/expanded (optional)
  - `class` - Additional CSS classes

  ## Slots

  - `header` - Header content (required)
  - `collapsed_preview` - Content shown when collapsed (optional)
  - `body` - Main body content shown when expanded (optional)
  - `footer` - Footer content shown when expanded (optional)
  """
  attr(:id, :string, required: true)

  attr(:position, :atom,
    default: :top_right,
    values: [:top_left, :top_right, :bottom_left, :bottom_right, :center]
  )

  attr(:collapsed, :boolean, default: false)
  attr(:on_toggle, :string, default: nil)
  attr(:on_toggle_target, :string, default: nil)
  attr(:size, :map, default: %{collapsed: "w-96 h-12", expanded: "w-[36rem] max-h-[80vh]"})
  attr(:class, :string, default: "")
  attr(:z_index, :string, default: "z-30")

  slot :header, required: true do
    attr(:class, :string)
  end

  slot :collapsed_preview, required: false do
    attr(:class, :string)
  end

  slot :body, required: false do
    attr(:class, :string)
  end

  slot :footer, required: false do
    attr(:class, :string)
  end

  def floating_window(assigns) do
    # Calculate arrow direction based on window position
    {collapsed_arrow, expanded_arrow} =
      case assigns.position do
        :top_left -> {"↘", "↖"}
        :top_right -> {"↙", "↗"}
        :bottom_left -> {"↗", "↙"}
        :bottom_right -> {"↖", "↘"}
        :center -> {"↙", "↗"}
      end

    assigns =
      assigns
      |> assign(:collapsed_arrow, collapsed_arrow)
      |> assign(:expanded_arrow, expanded_arrow)

    ~H"""
    <.window_container id={@id} position={@position} z_index={@z_index} class={@class}>
      <.window_frame
        collapsed={@collapsed}
        collapsed_size={@size.collapsed}
        expanded_size={@size.expanded}
      >
        <!-- Header -->
        <.window_header
          collapsed={@collapsed}
          on_toggle={@on_toggle}
          on_toggle_target={@on_toggle_target}
          collapsed_arrow={@collapsed_arrow}
          expanded_arrow={@expanded_arrow}
        >
          {render_slot(@header)}
        </.window_header>
        
    <!-- Collapsed preview content -->
        <%= if @collapsed and @collapsed_preview != [] do %>
          <div class={@collapsed_preview[:class] || ""}>
            {render_slot(@collapsed_preview)}
          </div>
        <% end %>
        
    <!-- Body (only when expanded) -->
        <%= unless @collapsed do %>
          <%= if @body != [] do %>
            <.window_body>
              {render_slot(@body)}
            </.window_body>
          <% end %>
          
    <!-- Footer (optional) -->
          <%= if @footer != [] do %>
            <.window_footer>
              {render_slot(@footer)}
            </.window_footer>
          <% end %>
        <% end %>
      </.window_frame>
    </.window_container>
    """
  end

  # ============================================================================
  # Primitive Components
  # ============================================================================

  @doc """
  Positioned container wrapper for floating windows.
  Handles absolute positioning and pointer events.
  """
  attr(:id, :string, required: true)
  attr(:position, :atom, default: :top_right)
  attr(:z_index, :string, default: "z-30")
  attr(:class, :string, default: "")
  slot(:inner_block, required: true)

  def window_container(assigns) do
    position_class =
      case assigns.position do
        :top_left -> "top-4 left-4"
        :top_right -> "top-4 right-4"
        :bottom_left -> "bottom-4 left-4"
        :bottom_right -> "bottom-4 right-4"
        :center -> "top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2"
      end

    assigns = assign(assigns, :position_class, position_class)

    ~H"""
    <div
      id={@id <> "-container"}
      class={["pointer-events-none absolute", @position_class, @z_index, @class]}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Main window frame with glass morphism styling and size transitions.
  """
  attr(:collapsed, :boolean, default: false)
  attr(:collapsed_size, :string, default: "w-96 h-12")
  attr(:expanded_size, :string, default: "w-[36rem] max-h-[80vh]")
  attr(:class, :string, default: "")
  slot(:inner_block, required: true)

  def window_frame(assigns) do
    ~H"""
    <div class={["border-gray-700/60 bg-gray-900/90 pointer-events-auto overflow-hidden rounded-xl border shadow-2xl backdrop-blur-lg transition-all duration-300", if(@collapsed, do: @collapsed_size, else: @expanded_size), @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Window header with collapse/expand functionality.
  """
  attr(:collapsed, :boolean, default: false)
  attr(:on_toggle, :string, default: nil)
  attr(:on_toggle_target, :string, default: nil)
  attr(:collapsed_arrow, :string, default: "↘")
  attr(:expanded_arrow, :string, default: "↖")
  attr(:class, :string, default: "")
  slot(:inner_block, required: true)

  def window_header(assigns) do
    ~H"""
    <div class={["border-gray-700/50 flex items-center justify-between border-b px-3 py-2", @class]}>
      <div class="flex min-w-0 flex-1 items-center gap-2">
        {render_slot(@inner_block)}
      </div>

      <%= if @on_toggle do %>
        <div class="ml-2 flex items-center gap-2">
          <button
            phx-click={@on_toggle}
            phx-target={@on_toggle_target}
            class="bg-gray-800/60 rounded px-2 py-1 text-xs text-gray-200 transition-all hover:bg-gray-700/60"
          >
            <div class="transition-opacity duration-200">
              {if @collapsed, do: @collapsed_arrow, else: @expanded_arrow}
            </div>
          </button>
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  Scrollable window body content area.
  """
  attr(:class, :string, default: "")
  attr(:max_height, :string, default: "max-h-[70vh]")
  slot(:inner_block, required: true)

  def window_body(assigns) do
    ~H"""
    <div class={[@max_height, "overflow-auto", @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Fixed footer section for actions or summary info.
  """
  attr(:class, :string, default: "")
  slot(:inner_block, required: true)

  def window_footer(assigns) do
    ~H"""
    <div class={["border-gray-700/50 border-t p-3", @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Content section with optional borders and padding.
  Useful for organizing content within window body.
  """
  attr(:title, :string, default: nil)
  attr(:border, :atom, default: :bottom, values: [:none, :top, :bottom, :both, :all])
  attr(:class, :string, default: "")
  slot(:inner_block, required: true)

  def window_section(assigns) do
    border_class =
      case assigns.border do
        :none -> ""
        :top -> "border-t border-gray-700/50"
        :bottom -> "border-b border-gray-700/50"
        :both -> "border-y border-gray-700/50"
        :all -> "border border-gray-700/50 rounded-lg"
      end

    assigns = assign(assigns, :border_class, border_class)

    ~H"""
    <div class={[@border_class, "p-4", @class]}>
      <%= if @title do %>
        <h4 class="mb-3 text-sm font-semibold text-gray-300">{@title}</h4>
      <% end %>
      {render_slot(@inner_block)}
    </div>
    """
  end

  # ============================================================================
  # Helper Components
  # ============================================================================

  @doc """
  Status indicator dot with predefined colors.
  """
  attr(:status, :atom, default: :info, values: [:healthy, :degraded, :error, :warning, :info])
  attr(:animated, :boolean, default: false)
  attr(:size, :string, default: "h-2 w-2")
  attr(:class, :string, default: "")

  def status_indicator(assigns) do
    color_class =
      case assigns.status do
        :healthy -> "bg-emerald-400"
        :degraded -> "bg-yellow-400"
        :error -> "bg-red-400"
        :warning -> "bg-orange-400"
        :info -> "bg-sky-400"
      end

    assigns = assign(assigns, :color_class, color_class)

    ~H"""
    <div class={[@size, "flex-shrink-0 rounded-full", @color_class, if(@animated, do: "animate-pulse"), @class]}>
    </div>
    """
  end

  @doc """
  Collapsible panel within a window section.
  """
  attr(:id, :string, required: true)
  attr(:title, :string, required: true)
  attr(:expanded, :boolean, default: false)
  attr(:on_toggle, :string, required: true)
  attr(:class, :string, default: "")
  slot(:inner_block, required: true)

  def collapsible_panel(assigns) do
    ~H"""
    <div class={["bg-gray-800/60 border-gray-700/70 rounded border", @class]}>
      <button
        type="button"
        phx-click={@on_toggle}
        phx-value-panel={@id}
        class="flex w-full items-center justify-between px-3 py-2 text-left"
      >
        <div class="flex items-center gap-2">
          <svg
            class={["h-3 w-3 transition-transform", if(@expanded, do: "rotate-90 text-sky-300", else: "text-gray-400")]}
            viewBox="0 0 20 20"
            fill="currentColor"
          >
            <path d="M6 6l6 4-6 4V6z" />
          </svg>
          <span class="text-sm text-white">{@title}</span>
        </div>
      </button>

      <%= if @expanded do %>
        <div class="border-gray-700/60 border-t p-3">
          {render_slot(@inner_block)}
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  Metric card for displaying KPIs.
  """
  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:value_class, :string, default: "text-sky-400")
  attr(:class, :string, default: "")

  def metric_card(assigns) do
    ~H"""
    <div class={["bg-gray-800/50 overflow-hidden rounded-lg p-3 text-center", @class]}>
      <div class="text-[11px] truncate leading-tight text-gray-400">{@label}</div>
      <div class="flex h-6 items-center justify-center">
        <div class={["text-lg font-bold", @value_class]}>{@value}</div>
      </div>
    </div>
    """
  end

  @doc """
  Grid layout for metrics.
  """
  attr(:cols, :integer, default: 4)
  attr(:class, :string, default: "")
  slot(:inner_block, required: true)

  def metrics_grid(assigns) do
    grid_cols =
      case assigns.cols do
        2 -> "grid-cols-2"
        3 -> "grid-cols-3"
        4 -> "grid-cols-2 md:grid-cols-4"
        _ -> "grid-cols-2 md:grid-cols-4"
      end

    assigns = assign(assigns, :grid_cols, grid_cols)

    ~H"""
    <div class={["grid gap-3", @grid_cols, @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Event feed with auto-scrolling behavior.
  """
  attr(:id, :string, required: true)
  attr(:events, :list, default: [])
  attr(:max_height, :string, default: "max-h-80")
  attr(:empty_message, :string, default: "No recent events")
  attr(:class, :string, default: "")
  slot(:event, required: false)

  def event_feed(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="TerminalFeed"
      class={["flex flex-col-reverse gap-1 overflow-y-auto", @max_height, @class]}
    >
      <%= if length(@events) > 0 do %>
        <%= for event <- @events do %>
          {render_slot(@event, event)}
        <% end %>
      <% else %>
        <div class="py-4 text-center text-xs text-gray-500">
          {@empty_message}
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  Action button group for footers.
  """
  attr(:align, :atom, default: :right, values: [:left, :right, :between])
  attr(:class, :string, default: "")
  slot(:inner_block, required: true)

  def action_group(assigns) do
    align_class =
      case assigns.align do
        :left -> "justify-start"
        :right -> "justify-end"
        :between -> "justify-between"
      end

    assigns = assign(assigns, :align_class, align_class)

    ~H"""
    <div class={["flex items-center gap-2", @align_class, @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end
end
