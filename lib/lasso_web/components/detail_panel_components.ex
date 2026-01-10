defmodule LassoWeb.Components.DetailPanelComponents do
  @moduledoc """
  Shared UI components for detail panels (provider, chain, etc.).
  """

  use Phoenix.Component

  @status_styles %{
    healthy: %{
      badge: "bg-emerald-500/10 border-emerald-500/30 text-emerald-400",
      indicator: "bg-emerald-400",
      label: "Healthy",
      bar: "bg-emerald-500/60"
    },
    degraded: %{
      badge: "bg-yellow-500/10 border-yellow-500/30 text-yellow-400",
      indicator: "bg-yellow-400",
      label: "Degraded",
      bar: "bg-yellow-500/60"
    },
    down: %{
      badge: "bg-red-500/10 border-red-500/30 text-red-400",
      indicator: "bg-red-400",
      label: "Down",
      bar: "bg-red-500/60"
    },
    unknown: %{
      badge: "bg-gray-500/10 border-gray-500/30 text-gray-400",
      indicator: "bg-gray-400",
      label: "Unknown",
      bar: "bg-gray-500/60"
    }
  }

  @severity_styles %{
    error: %{border: "border-l-red-500", dot: "bg-red-500", text: "text-red-400"},
    warn: %{border: "border-l-yellow-500", dot: "bg-yellow-500", text: "text-yellow-400"},
    info: %{border: "border-l-blue-500", dot: "bg-blue-500", text: "text-blue-400"}
  }

  attr(:status, :atom, required: true, values: [:healthy, :degraded, :down, :unknown])
  attr(:label, :string, default: nil)
  attr(:class, :string, default: "")

  def status_badge(assigns) do
    styles = Map.get(@status_styles, assigns.status, @status_styles.unknown)

    assigns =
      assigns
      |> assign(:badge_class, styles.badge)
      |> assign(:indicator_class, styles.indicator)
      |> assign(:display_label, assigns.label || styles.label)

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

  attr(:title, :string, required: true)
  attr(:class, :string, default: "mb-3")

  def section_header(assigns) do
    ~H"""
    <h4 class={["text-xs font-semibold uppercase tracking-wider text-gray-500", @class]}>
      {@title}
    </h4>
    """
  end

  attr(:class, :string, default: "")

  slot :metric, required: true do
    attr(:label, :string, required: true)
    attr(:value, :string, required: true)
    attr(:value_class, :string)
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

  attr(:cols, :integer, default: 4)
  attr(:class, :string, default: "")

  slot :metric, required: true do
    attr(:label, :string, required: true)
    attr(:value, :string, required: true)
    attr(:value_class, :string)
  end

  def metrics_grid(assigns) do
    grid_class =
      case assigns.cols do
        2 -> "grid-cols-2"
        3 -> "grid-cols-3"
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

  attr(:class, :string, default: "")
  attr(:border, :boolean, default: true)
  slot(:inner_block, required: true)

  def panel_section(assigns) do
    ~H"""
    <div class={["p-4", @border && "border-b border-gray-800", @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:state, :atom, required: true, values: [:closed, :half_open, :open])
  attr(:connected, :boolean, default: nil)
  attr(:class, :string, default: "")

  def circuit_breaker_row(assigns) do
    {status_text, status_class} = circuit_breaker_status(assigns.state, assigns.connected)

    assigns =
      assigns
      |> assign(:status_text, status_text)
      |> assign(:status_class, status_class)

    ~H"""
    <div class={["flex items-center gap-3", @class]}>
      <span class="w-10 text-xs text-gray-400">{@label}</span>
      <div class="flex-1 flex items-center gap-1">
        <.circuit_dot active={@state == :closed} color="emerald" />
        <div class="flex-1 h-0.5 bg-gray-700"></div>
        <.circuit_dot active={@state == :half_open} color="yellow" />
        <div class="flex-1 h-0.5 bg-gray-700"></div>
        <.circuit_dot active={@state == :open} color="red" />
      </div>
      <span class={["w-20 text-xs text-right", @status_class]}>
        {@status_text}
      </span>
    </div>
    """
  end

  attr(:active, :boolean, required: true)
  attr(:color, :string, required: true)

  defp circuit_dot(assigns) do
    active_class =
      case assigns.color do
        "emerald" -> "bg-emerald-500 border-emerald-400"
        "yellow" -> "bg-yellow-500 border-yellow-400"
        "red" -> "bg-red-500 border-red-400"
      end

    assigns = assign(assigns, :active_class, active_class)

    ~H"""
    <div class={[
      "w-3 h-3 rounded-full border-2",
      if(@active, do: @active_class, else: "border-gray-600")
    ]}>
    </div>
    """
  end

  defp circuit_breaker_status(state, connected) do
    case {state, connected} do
      {:open, _} -> {"Open", "text-red-400"}
      {:half_open, _} -> {"Half-open", "text-yellow-400"}
      {_, true} -> {"Connected", "text-emerald-400"}
      {_, false} -> {"Disconnected", "text-gray-400"}
      {:closed, _} -> {"Connected", "text-emerald-400"}
      _ -> {"Unknown", "text-gray-400"}
    end
  end

  attr(:class, :string, default: "")

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

  attr(:severity, :atom, required: true, values: [:error, :warn, :info])
  attr(:message, :string, required: true)
  attr(:detail, :map, default: nil)
  attr(:class, :string, default: "")

  def alert_item(assigns) do
    styles = Map.get(@severity_styles, assigns.severity, @severity_styles.info)

    assigns =
      assigns
      |> assign(:border_class, styles.border)
      |> assign(:dot_class, styles.dot)

    ~H"""
    <div class={["bg-gray-800/40 rounded-lg border-l-2 p-2", @border_class, @class]}>
      <div class="flex items-center gap-2">
        <div class={["w-2 h-2 rounded-full shrink-0", @dot_class]}></div>
        <span class="text-xs text-gray-200 font-medium">{@message}</span>
      </div>
      <.alert_detail :if={@detail} detail={@detail} />
    </div>
    """
  end

  attr(:detail, :map, required: true)

  defp alert_detail(assigns) do
    ~H"""
    <div class="mt-1.5 ml-4 text-[11px] text-gray-400">
      <div :if={@detail[:message]} class="text-gray-300 mb-1">{@detail[:message]}</div>
      <div class="flex flex-wrap gap-1.5">
        <span :if={@detail[:code]} class="px-1.5 py-0.5 rounded bg-red-900/30 text-red-400 font-mono">
          ERR {@detail[:code]}
        </span>
        <span :if={@detail[:category]} class="px-1.5 py-0.5 rounded bg-gray-700/50 text-gray-400">
          {@detail[:category]}
        </span>
      </div>
    </div>
    """
  end

  attr(:value, :float, required: true)
  attr(:status, :atom, default: :healthy, values: [:healthy, :degraded, :down])
  attr(:class, :string, default: "")

  def progress_bar(assigns) do
    styles = Map.get(@status_styles, assigns.status, @status_styles.healthy)
    assigns = assign(assigns, :bar_class, styles.bar)

    ~H"""
    <div class={["h-2 bg-gray-800 rounded-full overflow-hidden", @class]}>
      <div class={["h-full rounded-full transition-all", @bar_class]} style={"width: #{@value}%"} />
    </div>
    """
  end

  attr(:rank, :integer, required: true)
  attr(:size, :atom, default: :normal, values: [:small, :normal])
  attr(:class, :string, default: "")

  def rank_badge(assigns) do
    {size_class, rank_color} =
      case {assigns.size, assigns.rank} do
        {:small, 1} -> {"w-4 h-4 text-[9px]", "bg-yellow-500/20 text-yellow-400"}
        {:small, 2} -> {"w-4 h-4 text-[9px]", "bg-gray-400/20 text-gray-300"}
        {:small, 3} -> {"w-4 h-4 text-[9px]", "bg-orange-600/20 text-orange-400"}
        {:small, _} -> {"w-4 h-4 text-[9px]", "bg-gray-800 text-gray-500"}
        {:normal, 1} -> {"w-6 h-6 text-xs", "bg-yellow-500/20 text-yellow-400"}
        {:normal, 2} -> {"w-6 h-6 text-xs", "bg-gray-400/20 text-gray-300"}
        {:normal, 3} -> {"w-6 h-6 text-xs", "bg-orange-600/20 text-orange-400"}
        {:normal, _} -> {"w-6 h-6 text-xs", "bg-gray-800 text-gray-500"}
      end

    assigns =
      assigns
      |> assign(:size_class, size_class)
      |> assign(:rank_color, rank_color)

    ~H"""
    <span class={[
      "inline-flex items-center justify-center rounded-full font-semibold",
      @size_class,
      @rank_color,
      @class
    ]}>
      {@rank}
    </span>
    """
  end

  slot(:inner_block, required: true)
  attr(:class, :string, default: "")

  def empty_state(assigns) do
    ~H"""
    <div class={[
      "rounded-xl border border-gray-700/60 border-dashed bg-gray-900/20 shadow-2xl overflow-hidden",
      @class
    ]}>
      <div class="flex flex-col items-center justify-center py-16 px-8">
        <div class="relative mb-4">
          <div class="bg-gray-800/40 flex h-12 w-12 items-center justify-center rounded-lg">
            <svg class="h-6 w-6 text-gray-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="1.1"
                d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z"
              />
            </svg>
          </div>
        </div>
        <div class="text-center">
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  def copy_icon(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="1.5"
      stroke="currentColor"
      class="w-4 h-4 group-hover:scale-110 transition-transform"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M15.666 3.888A2.25 2.25 0 0013.5 2.25h-3c-1.03 0-1.9.693-2.166 1.638m7.332 0c.055.194.084.4.084.612v0a.75.75 0 01-.75.75H9a.75.75 0 01-.75-.75v0c0-.212.03-.418.084-.612m7.332 0c.646.049 1.288.11 1.927.184 1.1.128 1.907 1.077 1.907 2.185V19.5a2.25 2.25 0 01-2.25 2.25H6.75A2.25 2.25 0 014.5 19.5V6.257c0-1.108.806-2.057 1.907-2.185a48.208 48.208 0 011.927-.184"
      />
    </svg>
    """
  end
end
