defmodule LassoWeb.Dashboard.Components.ProviderDetailsPanel do
  @moduledoc """
  LiveComponent for displaying detailed provider information.

  Receives pre-computed data from the parent Dashboard LiveView:
  - provider_id: The selected provider's ID
  - connections: List of all provider connections (to find the selected one)
  - selected_profile: Current profile
  - selected_provider_metrics: Pre-computed performance metrics
  - selected_provider_unified_events: Pre-filtered events for this provider
  """

  use LassoWeb, :live_component

  alias LassoWeb.Dashboard.{Formatting, Helpers, StatusHelpers}

  @impl true
  def update(assigns, socket) do
    # Find the provider connection from the connections list
    provider_connection =
      Enum.find(assigns.connections, &(&1.id == assigns.provider_id))

    # Get the pre-computed data from parent
    provider_unified_events = assigns[:selected_provider_unified_events] || []
    performance_metrics = assigns[:selected_provider_metrics] || %{}

    socket =
      socket
      |> assign(assigns)
      |> assign(:provider_connection, provider_connection)
      |> assign(:provider_unified_events, provider_unified_events)
      |> assign(:performance_metrics, performance_metrics)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class="flex h-full flex-col overflow-y-auto text-gray-200 overflow-hidden"
      data-provider-id={@provider_id}
    >
      <!-- HEADER -->
      <div class="flex gap-2 items-center border-b border-gray-800 p-6 pb-5 relative overflow-hidden">
        <div class="w-full">
          <!-- Title row with status badge -->
          <div class="flex items-center w-full justify-between mb-1.5 relative z-10">
            <h3 class="text-3xl font-bold text-white tracking-tight">
              {if @provider_connection, do: @provider_connection.name, else: @provider_id}
            </h3>

            <div class={[
              "flex items-center gap-1.5 px-2.5 py-1 rounded-full border text-xs font-medium",
              StatusHelpers.provider_status_badge_class(@provider_connection || %{})
            ]}>
              <div class={[
                "h-1.5 w-1.5 rounded-full animate-pulse",
                StatusHelpers.provider_status_indicator_class(@provider_connection || %{})
              ]}>
              </div>
              <span>{StatusHelpers.provider_status_label(@provider_connection || %{})}</span>
            </div>
          </div>

          <!-- Provider metadata -->
          <div class="flex items-center gap-2 text-sm mb-2 relative z-10">
            <span class="text-gray-400">
              {if @provider_connection,
                do:
                  "Chain ID: #{Helpers.get_chain_id(@selected_profile, @provider_connection.chain || "unknown")}",
                else: "Provider"}
            </span>
            <%= if @provider_connection do %>
              <span class="text-gray-300">·</span>
              <span class="text-gray-400">
                <%= cond do %>
                  <% @provider_connection.url && @provider_connection.ws_url -> %>
                    <span class="text-gray-400">HTTP + WS</span>
                  <% @provider_connection.ws_url -> %>
                    <span class="text-gray-400">WS only</span>
                  <% true -> %>
                    <span class="text-gray-400">HTTP only</span>
                <% end %>
              </span>
            <% end %>
          </div>
        </div>
      </div>

      <%= if @provider_connection do %>
        <.sync_status_section provider_connection={@provider_connection} />
        <.performance_section performance_metrics={@performance_metrics} />
        <.circuit_breaker_section provider_connection={@provider_connection} />
        <.issues_section
          provider_connection={@provider_connection}
          provider_unified_events={@provider_unified_events}
        />
        <.method_performance_section performance_metrics={@performance_metrics} />
      <% else %>
        <div class="flex-1 flex items-center justify-center">
          <div class="text-gray-500">Provider data not available</div>
        </div>
      <% end %>
    </div>
    """
  end

  # ============================================================================
  # Section Components
  # ============================================================================

  attr :provider_connection, :map, required: true

  defp sync_status_section(assigns) do
    block_height = Map.get(assigns.provider_connection, :block_height)
    consensus_height = Map.get(assigns.provider_connection, :consensus_height)
    blocks_behind = Map.get(assigns.provider_connection, :blocks_behind, 0) || 0

    assigns =
      assigns
      |> assign(:block_height, block_height)
      |> assign(:consensus_height, consensus_height)
      |> assign(:blocks_behind, blocks_behind)

    ~H"""
    <div class="border-b border-gray-800 p-4">
      <h4 class="mb-3 text-xs font-semibold uppercase tracking-wider text-gray-500">
        Sync Status
      </h4>
      <%= if @block_height && @consensus_height do %>
        <div class="flex items-center justify-between text-sm mb-2">
          <span class="text-gray-400">
            Block Height:
            <span class="text-white font-mono">{Formatting.format_number(@block_height)}</span>
          </span>
          <span class="text-gray-400">
            Consensus:
            <span class="text-white font-mono">{Formatting.format_number(@consensus_height)}</span>
          </span>
          <span class={[
            "font-mono font-bold",
            cond do
              @blocks_behind <= 2 -> "text-emerald-400"
              @blocks_behind <= 10 -> "text-yellow-400"
              true -> "text-red-400"
            end
          ]}>
            {cond do
              @blocks_behind >= 0 and @blocks_behind <= 2 -> "Synced"
              @blocks_behind > 2 -> "-#{@blocks_behind}"
              @blocks_behind < 0 -> "+#{abs(@blocks_behind)}"
            end}
          </span>
        </div>
        <!-- Progress bar visualization -->
        <div class="h-2 bg-gray-800 rounded-full overflow-hidden mb-2">
          <% bar_width =
            if @consensus_height > 0,
              do: min(100, @block_height / @consensus_height * 100),
              else: 100 %>
          <div
            class={[
              "h-full rounded-full transition-all",
              cond do
                @blocks_behind <= 2 -> "bg-emerald-500/60"
                @blocks_behind <= 10 -> "bg-yellow-500/60"
                true -> "bg-red-500/60"
              end
            ]}
            style={"width: #{bar_width}%"}
          />
        </div>
        <div class="text-xs text-gray-500 text-right">
          {cond do
            @blocks_behind <= 2 -> "(within range)"
            @blocks_behind <= 10 -> "(slightly behind)"
            true -> "(significantly behind)"
          end}
        </div>
      <% else %>
        <div class="text-sm text-gray-500">Block height data unavailable</div>
      <% end %>
    </div>
    """
  end

  attr :performance_metrics, :map, required: true

  defp performance_section(assigns) do
    ~H"""
    <div class="border-b border-gray-800 p-4">
      <h4 class="mb-3 text-xs font-semibold uppercase tracking-wider text-gray-500">
        Performance
      </h4>
      <div class="grid grid-cols-4 gap-3">
        <div class="bg-gray-800/50 rounded-lg p-3 text-center border border-gray-800">
          <div class="text-[10px] text-gray-500 mb-1">p50</div>
          <div class="text-lg font-bold text-white">
            {if Map.get(@performance_metrics, :p50_latency),
              do: "#{Map.get(@performance_metrics, :p50_latency)}ms",
              else: "—"}
          </div>
        </div>
        <div class="bg-gray-800/50 rounded-lg p-3 text-center border border-gray-800">
          <div class="text-[10px] text-gray-500 mb-1">p95</div>
          <div class="text-lg font-bold text-white">
            {if Map.get(@performance_metrics, :p95_latency),
              do: "#{Map.get(@performance_metrics, :p95_latency)}ms",
              else: "—"}
          </div>
        </div>
        <div class="bg-gray-800/50 rounded-lg p-3 text-center border border-gray-800">
          <div class="text-[10px] text-gray-500 mb-1">Success</div>
          <% success_rate = Map.get(@performance_metrics, :success_rate, 0.0) %>
          <div class={[
            "text-lg font-bold",
            cond do
              success_rate >= 99.0 -> "text-emerald-400"
              success_rate >= 95.0 -> "text-yellow-400"
              true -> "text-red-400"
            end
          ]}>
            {if success_rate > 0, do: "#{success_rate}%", else: "—"}
          </div>
        </div>
        <div class="bg-gray-800/50 rounded-lg p-3 text-center border border-gray-800">
          <div class="text-[10px] text-gray-500 mb-1">Traffic</div>
          <div class="text-lg font-bold text-white">
            {(Map.get(@performance_metrics, :pick_share_5m, 0.0) || 0.0)
            |> Helpers.to_float()
            |> Float.round(1)}%
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :provider_connection, :map, required: true

  defp circuit_breaker_section(assigns) do
    has_http = Map.get(assigns.provider_connection, :url) != nil
    has_ws = Map.get(assigns.provider_connection, :ws_url) != nil
    http_state = Map.get(assigns.provider_connection, :http_circuit_state, :closed)
    ws_state = Map.get(assigns.provider_connection, :ws_circuit_state, :closed)
    ws_connected = Map.get(assigns.provider_connection, :ws_connected, false)

    assigns =
      assigns
      |> assign(:has_http, has_http)
      |> assign(:has_ws, has_ws)
      |> assign(:http_state, http_state)
      |> assign(:ws_state, ws_state)
      |> assign(:ws_connected, ws_connected)

    ~H"""
    <div class="border-b border-gray-800 p-4">
      <h4 class="mb-3 text-xs font-semibold uppercase tracking-wider text-gray-500">
        Circuit Breaker
      </h4>
      <div class="space-y-2">
        <!-- HTTP Circuit Breaker -->
        <%= if @has_http do %>
          <.circuit_breaker_row label="HTTP" state={@http_state} />
          <.circuit_breaker_labels />
        <% end %>

        <!-- WS Circuit Breaker -->
        <%= if @has_ws do %>
          <.circuit_breaker_row label="WS" state={@ws_state} connected={@ws_connected} class="mt-3" />
          <.circuit_breaker_labels />
        <% end %>

        <!-- Failure/Success Counters -->
        <div class="flex justify-between text-xs text-gray-400 pt-2 border-gray-800">
          <span>
            Failures:
            <span class={
              if Map.get(@provider_connection, :consecutive_failures, 0) > 0,
                do: "text-red-400",
                else: "text-gray-300"
            }>
              {Map.get(@provider_connection, :consecutive_failures, 0)}/5
            </span>
            threshold
          </span>
          <span>
            Successes:
            <span class="text-emerald-400">
              {Map.get(@provider_connection, :consecutive_successes, 0)}
            </span>
            consecutive
          </span>
        </div>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :state, :atom, required: true
  attr :connected, :boolean, default: nil
  attr :class, :string, default: ""

  defp circuit_breaker_row(assigns) do
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

  defp circuit_breaker_labels(assigns) do
    assigns = assign(assigns, :dummy, nil)

    ~H"""
    <div class="flex items-center gap-3 pb-3">
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

  attr :provider_connection, :map, required: true
  attr :provider_unified_events, :list, required: true

  defp issues_section(assigns) do
    active_alerts = build_active_alerts(assigns.provider_connection)

    event_feed =
      assigns.provider_unified_events
      |> Enum.filter(fn e ->
        kind = e[:kind]
        severity = e[:severity]
        kind in [:circuit, :provider, :error] or severity in [:warn, :error]
      end)
      |> Enum.take(15)

    assigns =
      assigns
      |> assign(:active_alerts, active_alerts)
      |> assign(:event_feed, event_feed)

    ~H"""
    <div class="border-b border-gray-800 p-4">
      <h4 class="mb-3 text-xs font-semibold uppercase tracking-wider text-gray-500">Issues</h4>

      <!-- Active Alerts -->
      <%= if length(@active_alerts) > 0 do %>
        <div class="space-y-2 mb-3">
          <%= for {severity, message, error_detail} <- @active_alerts do %>
            <.alert_item severity={severity} message={message} detail={error_detail} />
          <% end %>
        </div>
      <% end %>

      <!-- Event Feed -->
      <%= if length(@event_feed) > 0 do %>
        <div class="max-h-64 overflow-y-auto space-y-1.5 pr-1">
          <%= for event <- @event_feed do %>
            <.event_feed_item event={event} />
          <% end %>
        </div>
        <div class="mt-2 pt-1 text-center">
          <span class="text-[10px] text-gray-500">{length(@event_feed)} events</span>
        </div>
      <% else %>
        <%= if length(@active_alerts) == 0 do %>
          <div class="text-xs text-gray-500 text-center pt-2 pb-3">No issues detected</div>
        <% end %>
      <% end %>
    </div>
    """
  end

  attr :severity, :atom, required: true
  attr :message, :string, required: true
  attr :detail, :map, default: nil

  defp alert_item(assigns) do
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
    <div class={["bg-gray-800/40 rounded-lg border-l-2 p-2", @border_class]}>
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

  attr :event, :map, required: true

  defp event_feed_item(assigns) do
    event = assigns.event

    severity_color =
      case event[:severity] do
        :error -> "bg-red-500"
        :warn -> "bg-yellow-500"
        _ -> "bg-blue-500"
      end

    time_ago =
      if event[:ts_ms] do
        diff_ms = System.system_time(:millisecond) - event[:ts_ms]

        cond do
          diff_ms < 60_000 -> "now"
          diff_ms < 3_600_000 -> "#{div(diff_ms, 60_000)}m ago"
          true -> "#{div(diff_ms, 3_600_000)}h ago"
        end
      else
        "—"
      end

    raw_message = event[:message] || "Unknown event"
    display_message = format_event_message(raw_message)
    is_expandable = String.length(display_message) > 80 or has_event_details?(event)

    preview_message =
      if String.length(display_message) > 80 do
        String.slice(display_message, 0, 77) <> "..."
      else
        display_message
      end

    event_id = "event-#{:erlang.phash2({event[:kind], event[:message], event[:ts_ms]})}"

    assigns =
      assigns
      |> assign(:severity_color, severity_color)
      |> assign(:time_ago, time_ago)
      |> assign(:display_message, display_message)
      |> assign(:is_expandable, is_expandable)
      |> assign(:preview_message, preview_message)
      |> assign(:event_id, event_id)

    ~H"""
    <%= if @is_expandable do %>
      <details
        id={@event_id}
        phx-hook="ExpandableDetails"
        class="group bg-gray-800/30 rounded-lg hover:bg-gray-800/50 transition-colors"
      >
        <summary class="p-2 cursor-pointer list-none">
          <div class="flex items-start justify-between gap-2">
            <div class="flex items-start gap-2 min-w-0 flex-1">
              <div class={["w-1.5 h-1.5 rounded-full mt-1.5 shrink-0", @severity_color]}></div>
              <span class="text-xs text-gray-300 break-words">{@preview_message}</span>
            </div>
            <div class="flex items-center gap-1 shrink-0">
              <svg
                class="w-3 h-3 text-gray-500 transition-transform group-open:rotate-180"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M19 9l-7 7-7-7"
                />
              </svg>
              <span class="text-[10px] text-gray-500">{@time_ago}</span>
            </div>
          </div>
        </summary>
        <div class="px-2 pb-2 pt-1 ml-3.5 space-y-2">
          <!-- Full message if truncated -->
          <%= if String.length(@display_message) > 80 do %>
            <div class="text-xs text-gray-300 break-words whitespace-pre-wrap">
              {@display_message}
            </div>
          <% end %>
          <!-- Error details -->
          <%= if get_in(@event, [:meta, :error_code]) || get_in(@event, [:meta, :error_message]) do %>
            <div class="space-y-1.5">
              <%= if get_in(@event, [:meta, :error_message]) do %>
                <div class="text-[11px] text-red-400 break-words">
                  {get_in(@event, [:meta, :error_message])}
                </div>
              <% end %>
              <div class="flex flex-wrap gap-1.5">
                <%= if get_in(@event, [:meta, :error_code]) do %>
                  <span class="px-1.5 py-0.5 rounded bg-red-900/30 text-red-400 text-[10px] font-mono">
                    ERR {get_in(@event, [:meta, :error_code])}
                  </span>
                <% end %>
                <%= if get_in(@event, [:meta, :error_category]) do %>
                  <span class="px-1.5 py-0.5 rounded bg-gray-700/50 text-gray-400 text-[10px]">
                    {get_in(@event, [:meta, :error_category])}
                  </span>
                <% end %>
              </div>
            </div>
          <% end %>
          <!-- Event metadata tags -->
          <div class="flex flex-wrap gap-1">
            <%= if @event[:kind] do %>
              <span class="px-1.5 py-0.5 rounded bg-gray-700/50 text-[10px] text-gray-400">
                {@event[:kind] |> to_string() |> String.capitalize()}
              </span>
            <% end %>
            <%= if get_in(@event, [:meta, :transport]) do %>
              <span class="px-1.5 py-0.5 rounded bg-gray-700/50 text-[10px] text-gray-400">
                {get_in(@event, [:meta, :transport])}
              </span>
            <% end %>
          </div>
        </div>
      </details>
    <% else %>
      <div class="bg-gray-800/30 rounded-lg p-2 hover:bg-gray-800/50 transition-colors">
        <div class="flex items-start justify-between gap-2">
          <div class="flex items-start gap-2 min-w-0 flex-1">
            <div class={["w-1.5 h-1.5 rounded-full mt-1.5 shrink-0", @severity_color]}></div>
            <span class="text-xs text-gray-300">{@display_message}</span>
          </div>
          <span class="text-[10px] text-gray-500 shrink-0">{@time_ago}</span>
        </div>
      </div>
    <% end %>
    """
  end

  attr :performance_metrics, :map, required: true

  defp method_performance_section(assigns) do
    rpc_stats = Map.get(assigns.performance_metrics, :rpc_stats, [])
    max_calls = rpc_stats |> Enum.map(& &1.total_calls) |> Enum.max(fn -> 1 end)

    assigns =
      assigns
      |> assign(:rpc_stats, rpc_stats)
      |> assign(:max_calls, max_calls)

    ~H"""
    <div class="p-4">
      <h4 class="mb-3 text-xs font-semibold uppercase tracking-wider text-gray-500">
        Method Performance
      </h4>
      <%= if length(@rpc_stats) > 0 do %>
        <div class="space-y-2">
          <%= for stat <- Enum.take(@rpc_stats, 6) do %>
            <% bar_width = if @max_calls > 0, do: stat.total_calls / @max_calls * 100, else: 0 %>
            <div class="flex items-center gap-2 text-xs">
              <span class="w-28 text-gray-300 truncate font-mono" title={stat.method}>
                {stat.method}
              </span>
              <span class="w-16 text-gray-400">
                p50: {Helpers.to_float(stat.avg_duration_ms) |> Float.round(0)}ms
              </span>
              <span class={[
                "w-12",
                if(stat.success_rate >= 0.99,
                  do: "text-emerald-400",
                  else: if(stat.success_rate >= 0.95, do: "text-yellow-400", else: "text-red-400")
                )
              ]}>
                {(Helpers.to_float(stat.success_rate) * 100) |> Float.round(1)}%
              </span>
              <div class="flex-1 bg-gray-800 rounded h-2">
                <div class="bg-gray-600 h-2 rounded" style={"width: #{bar_width}%"}></div>
              </div>
              <span class="w-14 text-right text-gray-500">{stat.total_calls}</span>
            </div>
          <% end %>
        </div>
        <div class="text-[10px] text-gray-600 text-right mt-2">(calls)</div>
      <% else %>
        <div class="text-xs text-gray-500 text-center py-2">No recent method data</div>
      <% end %>
    </div>
    """
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp build_active_alerts(provider_connection) do
    alerts = []

    http_cb = Map.get(provider_connection, :http_circuit_state)
    ws_cb = Map.get(provider_connection, :ws_circuit_state)
    http_cb_error = Map.get(provider_connection, :http_cb_error)
    ws_cb_error = Map.get(provider_connection, :ws_cb_error)

    alerts =
      if http_cb == :open do
        [{:error, "HTTP circuit OPEN", format_cb_error(http_cb_error)} | alerts]
      else
        alerts
      end

    alerts =
      if ws_cb == :open do
        [{:error, "WS circuit OPEN", format_cb_error(ws_cb_error)} | alerts]
      else
        alerts
      end

    alerts =
      if http_cb == :half_open do
        [{:warn, "HTTP circuit recovering", nil} | alerts]
      else
        alerts
      end

    alerts =
      if ws_cb == :half_open do
        [{:warn, "WS circuit recovering", nil} | alerts]
      else
        alerts
      end

    http_rate_limited = Map.get(provider_connection, :http_rate_limited, false)
    ws_rate_limited = Map.get(provider_connection, :ws_rate_limited, false)
    rate_limit_remaining = Map.get(provider_connection, :rate_limit_remaining, %{})

    alerts =
      cond do
        http_rate_limited and ws_rate_limited ->
          http_sec = div(Map.get(rate_limit_remaining, :http, 0), 1000)
          ws_sec = div(Map.get(rate_limit_remaining, :ws, 0), 1000)
          [{:warn, "Rate limited (HTTP: #{http_sec}s, WS: #{ws_sec}s)", nil} | alerts]

        http_rate_limited ->
          sec = div(Map.get(rate_limit_remaining, :http, 0), 1000)
          [{:warn, "HTTP rate limited (#{sec}s)", nil} | alerts]

        ws_rate_limited ->
          sec = div(Map.get(rate_limit_remaining, :ws, 0), 1000)
          [{:warn, "WS rate limited (#{sec}s)", nil} | alerts]

        true ->
          alerts
      end

    failures = Map.get(provider_connection, :consecutive_failures, 0)

    alerts =
      if failures > 0 do
        severity = if failures >= 3, do: :error, else: :warn
        [{severity, "#{failures} consecutive failures", nil} | alerts]
      else
        alerts
      end

    has_ws = Map.get(provider_connection, :ws_url) != nil
    ws_connected = Map.get(provider_connection, :ws_connected, false)
    ws_circuit_ok = Map.get(provider_connection, :ws_circuit_state) != :open

    if has_ws and not ws_connected and ws_circuit_ok do
      [{:warn, "WebSocket disconnected", nil} | alerts]
    else
      alerts
    end
  end

  defp format_cb_error(nil), do: nil

  defp format_cb_error(%{} = error) do
    %{
      code: error[:code] || error[:error_code],
      category: error[:category] || error[:error_category],
      message: error[:message] || error[:error_message]
    }
  end

  defp format_event_message(message) when is_binary(message) do
    if String.starts_with?(message, "%Lasso.JSONRPC.Error{") do
      code = extract_field(message, "code:")
      msg = extract_field(message, "message:")
      category = extract_field(message, "category:")

      parts = []
      parts = if msg && msg != "nil", do: [clean_string_value(msg) | parts], else: parts
      parts = if code && code != "nil", do: ["ERR #{code}" | parts], else: parts
      parts = if category && category != "nil", do: ["(#{category})" | parts], else: parts

      case parts do
        [] -> message
        _ -> Enum.reverse(parts) |> Enum.join(" ")
      end
    else
      message
    end
  end

  defp format_event_message(other), do: inspect(other)

  defp extract_field(str, field) do
    case Regex.run(~r/#{Regex.escape(field)}\s*([^,}]+)/, str) do
      [_, value] -> String.trim(value)
      _ -> nil
    end
  end

  defp clean_string_value(str) do
    str
    |> String.trim()
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.replace(~r/\\\"/, "\"")
  end

  defp has_event_details?(event) do
    get_in(event, [:meta, :error_code]) != nil or
      get_in(event, [:meta, :error_message]) != nil or
      get_in(event, [:meta, :error_category]) != nil
  end
end
