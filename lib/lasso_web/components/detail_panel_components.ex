defmodule LassoWeb.Components.DetailPanelComponents do
  @moduledoc """
  Shared UI components for detail panels (provider, chain, etc.).

  These are reusable function components extracted from the dashboard
  to reduce duplication and provide consistent styling.
  """

  use Phoenix.Component

  # ============================================================================
  # Status Badge
  # ============================================================================

  @doc """
  Status badge pill with indicator dot and text.

  ## Examples

      <.status_badge status={:healthy} />
      <.status_badge status={:degraded} label="Partial" />
      <.status_badge status={:down} />
  """
  attr :status, :atom, required: true, values: [:healthy, :degraded, :down, :unknown]
  attr :label, :string, default: nil
  attr :class, :string, default: ""

  def status_badge(assigns) do
    {badge_class, indicator_class, default_label} =
      case assigns.status do
        :healthy ->
          {"bg-emerald-500/10 border-emerald-500/30 text-emerald-400", "bg-emerald-400", "Healthy"}

        :degraded ->
          {"bg-yellow-500/10 border-yellow-500/30 text-yellow-400", "bg-yellow-400", "Degraded"}

        :down ->
          {"bg-red-500/10 border-red-500/30 text-red-400", "bg-red-400", "Down"}

        _ ->
          {"bg-gray-500/10 border-gray-500/30 text-gray-400", "bg-gray-400", "Unknown"}
      end

    assigns =
      assigns
      |> assign(:badge_class, badge_class)
      |> assign(:indicator_class, indicator_class)
      |> assign(:display_label, assigns.label || default_label)

    ~H"""
    <div class={[
      "flex items-center gap-1.5 px-2.5 py-1 rounded-full border text-xs font-medium",
      @badge_class,
      @class
    ]}>
      <div class={["h-1.5 w-1.5 rounded-full animate-pulse", @indicator_class]}></div>
      <span>{@display_label}</span>
    </div>
    """
  end

  # ============================================================================
  # Section Header
  # ============================================================================

  @doc """
  Uppercase tracking section header.

  ## Examples

      <.section_header title="Performance" />
      <.section_header title="Circuit Breaker" class="mb-4" />
  """
  attr :title, :string, required: true
  attr :class, :string, default: "mb-3"

  def section_header(assigns) do
    ~H"""
    <h4 class={["text-xs font-semibold uppercase tracking-wider text-gray-500", @class]}>
      {@title}
    </h4>
    """
  end

  # ============================================================================
  # Metrics Strip
  # ============================================================================

  @doc """
  Horizontal metrics strip with dividers (used in chain details).

  ## Examples

      <.metrics_strip>
        <:metric label="Latency p50" value="45ms" />
        <:metric label="Success" value="99.2%" value_class="text-emerald-400" />
      </.metrics_strip>
  """
  attr :class, :string, default: ""

  slot :metric, required: true do
    attr :label, :string, required: true
    attr :value, :string, required: true
    attr :value_class, :string
  end

  def metrics_strip(assigns) do
    ~H"""
    <div class={[
      "grid divide-x divide-gray-800 border-b border-gray-800 bg-gray-900/30",
      "grid-cols-#{length(@metric)}",
      @class
    ]}>
      <%= for metric <- @metric do %>
        <div class="p-3 text-center hover:bg-gray-800/30 transition-colors">
          <div class="text-[10px] uppercase tracking-wider text-gray-500 font-semibold mb-1">
            {metric.label}
          </div>
          <div class={["text-sm font-bold font-mono", metric[:value_class] || "text-sky-400"]}>
            {metric.value}
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ============================================================================
  # Metrics Grid
  # ============================================================================

  @doc """
  Grid of metric cards with borders (used in provider details).

  ## Examples

      <.metrics_grid>
        <:metric label="p50" value="45ms" />
        <:metric label="p95" value="120ms" />
        <:metric label="Success" value="99.2%" value_class="text-emerald-400" />
        <:metric label="Traffic" value="24.5%" />
      </.metrics_grid>
  """
  attr :cols, :integer, default: 4
  attr :class, :string, default: ""

  slot :metric, required: true do
    attr :label, :string, required: true
    attr :value, :string, required: true
    attr :value_class, :string
  end

  def metrics_grid(assigns) do
    grid_class =
      case assigns.cols do
        2 -> "grid-cols-2"
        3 -> "grid-cols-3"
        4 -> "grid-cols-4"
        _ -> "grid-cols-4"
      end

    assigns = assign(assigns, :grid_class, grid_class)

    ~H"""
    <div class={["grid gap-3", @grid_class, @class]}>
      <%= for metric <- @metric do %>
        <div class="bg-gray-800/50 rounded-lg p-3 text-center border border-gray-800">
          <div class="text-[10px] text-gray-500 mb-1">{metric.label}</div>
          <div class={["text-lg font-bold", metric[:value_class] || "text-white"]}>
            {metric.value}
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ============================================================================
  # Panel Section
  # ============================================================================

  @doc """
  Bordered section container for panel content.

  ## Examples

      <.panel_section>
        <.section_header title="Sync Status" />
        <p>Content here</p>
      </.panel_section>
  """
  attr :class, :string, default: ""
  attr :border, :boolean, default: true
  slot :inner_block, required: true

  def panel_section(assigns) do
    ~H"""
    <div class={[
      "p-4",
      @border && "border-b border-gray-800",
      @class
    ]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  # ============================================================================
  # Circuit Breaker Visualization
  # ============================================================================

  @doc """
  Circuit breaker state visualization with state machine dots.

  ## Examples

      <.circuit_breaker_row label="HTTP" state={:closed} />
      <.circuit_breaker_row label="WS" state={:half_open} connected={false} />
  """
  attr :label, :string, required: true
  attr :state, :atom, required: true, values: [:closed, :half_open, :open]
  attr :connected, :boolean, default: nil
  attr :class, :string, default: ""

  def circuit_breaker_row(assigns) do
    status_text =
      cond do
        assigns.state == :open -> "Open"
        assigns.state == :half_open -> "Half-open"
        assigns.connected == true -> "Connected"
        assigns.connected == false -> "Disconnected"
        assigns.state == :closed -> "Connected"
        true -> "Unknown"
      end

    status_class =
      cond do
        assigns.state == :open -> "text-red-400"
        assigns.state == :half_open -> "text-yellow-400"
        assigns.connected == true -> "text-emerald-400"
        assigns.connected == false -> "text-gray-400"
        assigns.state == :closed -> "text-emerald-400"
        true -> "text-gray-400"
      end

    assigns =
      assigns
      |> assign(:status_text, status_text)
      |> assign(:status_class, status_class)

    ~H"""
    <div class={["flex items-center gap-3", @class]}>
      <span class="w-10 text-xs text-gray-400">{@label}</span>
      <div class="flex-1 flex items-center gap-1">
        <div class={[
          "w-3 h-3 rounded-full border-2",
          if(@state == :closed, do: "bg-emerald-500 border-emerald-400", else: "border-gray-600")
        ]}>
        </div>
        <div class="flex-1 h-0.5 bg-gray-700"></div>
        <div class={[
          "w-3 h-3 rounded-full border-2",
          if(@state == :half_open, do: "bg-yellow-500 border-yellow-400", else: "border-gray-600")
        ]}>
        </div>
        <div class="flex-1 h-0.5 bg-gray-700"></div>
        <div class={[
          "w-3 h-3 rounded-full border-2",
          if(@state == :open, do: "bg-red-500 border-red-400", else: "border-gray-600")
        ]}>
        </div>
      </div>
      <span class={["w-20 text-xs text-right", @status_class]}>
        {@status_text}
      </span>
    </div>
    """
  end

  @doc """
  Circuit breaker state labels row (shown below the visualization).
  """
  attr :class, :string, default: ""

  def circuit_breaker_labels(assigns) do
    ~H"""
    <div class={["flex items-center gap-3 pb-3", @class]}>
      <span class="w-10"></span>
      <div class="flex-1 flex items-center gap-1 pl-1.5">
        <span class="text-[10px] text-gray-600 text-center">closed</span>
        <div class="flex-1"></div>
        <span class="text-[10px] text-gray-600 text-center">half-open</span>
        <div class="flex-1"></div>
        <span class="text-[10px] text-gray-600 text-center">open</span>
      </div>
      <span class="w-20"></span>
    </div>
    """
  end

  # ============================================================================
  # Alert Item
  # ============================================================================

  @doc """
  Alert item with severity indicator.

  ## Examples

      <.alert_item severity={:error} message="HTTP circuit OPEN" />
      <.alert_item severity={:warn} message="WS circuit recovering" />
  """
  attr :severity, :atom, required: true, values: [:error, :warn, :info]
  attr :message, :string, required: true
  attr :detail, :map, default: nil
  attr :class, :string, default: ""

  def alert_item(assigns) do
    {border_class, dot_class} =
      case assigns.severity do
        :error -> {"border-l-red-500", "bg-red-500"}
        :warn -> {"border-l-yellow-500", "bg-yellow-500"}
        _ -> {"border-l-blue-500", "bg-blue-500"}
      end

    assigns =
      assigns
      |> assign(:border_class, border_class)
      |> assign(:dot_class, dot_class)

    ~H"""
    <div class={["bg-gray-800/40 rounded-lg border-l-2 p-2", @border_class, @class]}>
      <div class="flex items-center gap-2">
        <div class={["w-2 h-2 rounded-full shrink-0", @dot_class]}></div>
        <span class="text-xs text-gray-200 font-medium">{@message}</span>
      </div>
      <%= if @detail do %>
        <div class="mt-1.5 ml-4 text-[11px] text-gray-400">
          <%= if @detail[:message] do %>
            <div class="text-gray-300 mb-1">{@detail[:message]}</div>
          <% end %>
          <div class="flex flex-wrap gap-1.5">
            <%= if @detail[:code] do %>
              <span class="px-1.5 py-0.5 rounded bg-red-900/30 text-red-400 font-mono">
                ERR {@detail[:code]}
              </span>
            <% end %>
            <%= if @detail[:category] do %>
              <span class="px-1.5 py-0.5 rounded bg-gray-700/50 text-gray-400">
                {@detail[:category]}
              </span>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ============================================================================
  # Progress Bar
  # ============================================================================

  @doc """
  Progress bar with status-based coloring.

  ## Examples

      <.progress_bar value={95} status={:healthy} />
      <.progress_bar value={75} status={:degraded} />
  """
  attr :value, :float, required: true
  attr :status, :atom, default: :healthy, values: [:healthy, :degraded, :down]
  attr :class, :string, default: ""

  def progress_bar(assigns) do
    bar_class =
      case assigns.status do
        :healthy -> "bg-emerald-500/60"
        :degraded -> "bg-yellow-500/60"
        :down -> "bg-red-500/60"
      end

    assigns = assign(assigns, :bar_class, bar_class)

    ~H"""
    <div class={["h-2 bg-gray-800 rounded-full overflow-hidden", @class]}>
      <div class={["h-full rounded-full transition-all", @bar_class]} style={"width: #{@value}%"} />
    </div>
    """
  end
end
