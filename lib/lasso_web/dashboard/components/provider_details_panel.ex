defmodule LassoWeb.Dashboard.Components.ProviderDetailsPanel do
  @moduledoc """
  LiveComponent for displaying detailed provider information.
  """

  use LassoWeb, :live_component

  alias LassoWeb.Components.DetailPanelComponents
  alias LassoWeb.Dashboard.{Formatting, Helpers, StatusHelpers}

  @impl true
  def update(assigns, socket) do
    provider_connection = Enum.find(assigns.connections, &(&1.id == assigns.provider_id))

    socket =
      socket
      |> assign(assigns)
      |> assign(:provider_connection, provider_connection)
      |> assign(:provider_unified_events, assigns[:selected_provider_unified_events] || [])
      |> assign(:performance_metrics, assigns[:selected_provider_metrics] || %{})

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class="flex h-full flex-col overflow-y-auto text-gray-200 overflow-hidden"
      data-provider-id={@provider_id}
    >
      <.provider_header
        provider_connection={@provider_connection}
        provider_id={@provider_id}
        selected_profile={@selected_profile}
      />

      <div :if={@provider_connection}>
        <.sync_status_section provider_connection={@provider_connection} />
        <.performance_section performance_metrics={@performance_metrics} />
        <.circuit_breaker_section provider_connection={@provider_connection} />
        <.issues_section
          provider_connection={@provider_connection}
          provider_unified_events={@provider_unified_events}
        />
        <.method_performance_section performance_metrics={@performance_metrics} />
      </div>

      <div :if={!@provider_connection} class="flex-1 flex items-center justify-center">
        <div class="text-gray-500">Provider data not available</div>
      </div>
    </div>
    """
  end

  attr(:provider_connection, :map, default: nil)
  attr(:provider_id, :string, required: true)
  attr(:selected_profile, :string, required: true)

  defp provider_header(assigns) do
    conn = assigns.provider_connection || %{}

    assigns =
      assigns
      |> assign(:name, Map.get(conn, :name, assigns.provider_id))
      |> assign(:transport_label, transport_label(conn))
      |> assign(:chain_id, get_chain_id_display(assigns.selected_profile, conn))

    ~H"""
    <div class="flex gap-2 items-center border-b border-gray-800 p-6 pb-5 relative overflow-hidden">
      <div class="w-full">
        <div class="flex items-center w-full justify-between mb-1.5 relative z-10">
          <h3 class="text-3xl font-bold text-white tracking-tight">{@name}</h3>

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

        <div class="flex items-center gap-2 text-sm mb-2 relative z-10">
          <span class="text-gray-400">{@chain_id}</span>
          <span :if={@provider_connection} class="text-gray-300">·</span>
          <span :if={@provider_connection} class="text-gray-400">{@transport_label}</span>
        </div>
      </div>
    </div>
    """
  end

  defp transport_label(%{url: url, ws_url: ws_url}) when not is_nil(url) and not is_nil(ws_url),
    do: "HTTP + WS"

  defp transport_label(%{ws_url: ws_url}) when not is_nil(ws_url), do: "WS only"
  defp transport_label(_), do: "HTTP only"

  defp get_chain_id_display(profile, %{chain: chain}) when not is_nil(chain),
    do: "Chain ID: #{Helpers.get_chain_id(profile, chain)}"

  defp get_chain_id_display(_, _), do: "Provider"

  attr(:provider_connection, :map, required: true)

  defp sync_status_section(assigns) do
    block_height = Map.get(assigns.provider_connection, :block_height)
    consensus_height = Map.get(assigns.provider_connection, :consensus_height)
    blocks_behind = Map.get(assigns.provider_connection, :blocks_behind, 0) || 0
    sync_status = sync_status_level(blocks_behind)

    assigns =
      assigns
      |> assign(:block_height, block_height)
      |> assign(:consensus_height, consensus_height)
      |> assign(:blocks_behind, blocks_behind)
      |> assign(:sync_status, sync_status)

    ~H"""
    <DetailPanelComponents.panel_section>
      <DetailPanelComponents.section_header title="Sync Status" />
      <div :if={@block_height && @consensus_height}>
        <div class="flex items-center justify-between text-sm mb-2">
          <span class="text-gray-400">
            Block Height:
            <span class="text-white font-mono">{Formatting.format_number(@block_height)}</span>
          </span>
          <span class="text-gray-400">
            Consensus:
            <span class="text-white font-mono">{Formatting.format_number(@consensus_height)}</span>
          </span>
          <span class={["font-mono font-bold", sync_color(@sync_status)]}>
            {sync_label(@blocks_behind)}
          </span>
        </div>
        <DetailPanelComponents.progress_bar
          value={sync_progress(@block_height, @consensus_height)}
          status={@sync_status}
          class="mb-2"
        />
        <div class="text-xs text-gray-500 text-right">{sync_description(@sync_status)}</div>
      </div>
      <div :if={!@block_height || !@consensus_height} class="text-sm text-gray-500">
        Block height data unavailable
      </div>
    </DetailPanelComponents.panel_section>
    """
  end

  defp sync_status_level(blocks_behind) when blocks_behind <= 2, do: :healthy
  defp sync_status_level(blocks_behind) when blocks_behind <= 10, do: :degraded
  defp sync_status_level(_), do: :down

  defp sync_color(:healthy), do: "text-emerald-400"
  defp sync_color(:degraded), do: "text-yellow-400"
  defp sync_color(:down), do: "text-red-400"

  defp sync_label(blocks_behind) when blocks_behind >= 0 and blocks_behind <= 2, do: "Synced"
  defp sync_label(blocks_behind) when blocks_behind > 2, do: "-#{blocks_behind}"
  defp sync_label(blocks_behind) when blocks_behind < 0, do: "+#{abs(blocks_behind)}"

  defp sync_description(:healthy), do: "(within range)"
  defp sync_description(:degraded), do: "(slightly behind)"
  defp sync_description(:down), do: "(significantly behind)"

  defp sync_progress(_, 0), do: 100

  defp sync_progress(block_height, consensus_height),
    do: min(100, block_height / consensus_height * 100)

  attr(:performance_metrics, :map, required: true)

  defp performance_section(assigns) do
    metrics = assigns.performance_metrics
    success_rate = Map.get(metrics, :success_rate, 0.0)

    assigns =
      assigns
      |> assign(:p50, format_latency(Map.get(metrics, :p50_latency)))
      |> assign(:p95, format_latency(Map.get(metrics, :p95_latency)))
      |> assign(:success_rate, if(success_rate > 0, do: "#{success_rate}%", else: "—"))
      |> assign(:success_class, success_rate_color(success_rate))
      |> assign(:traffic, format_traffic(Map.get(metrics, :pick_share_5m, 0.0)))

    ~H"""
    <DetailPanelComponents.panel_section>
      <DetailPanelComponents.section_header title="Performance" />
      <DetailPanelComponents.metrics_grid>
        <:metric label="p50" value={@p50} />
        <:metric label="p95" value={@p95} />
        <:metric label="Success" value={@success_rate} value_class={@success_class} />
        <:metric label="Traffic" value={@traffic} />
      </DetailPanelComponents.metrics_grid>
    </DetailPanelComponents.panel_section>
    """
  end

  defp format_latency(nil), do: "—"
  defp format_latency(ms), do: "#{ms}ms"

  defp format_traffic(nil), do: "0.0%"
  defp format_traffic(value), do: "#{value |> Helpers.to_float() |> Float.round(1)}%"

  defp success_rate_color(rate) when rate >= 99.0, do: "text-emerald-400"
  defp success_rate_color(rate) when rate >= 95.0, do: "text-yellow-400"
  defp success_rate_color(_), do: "text-red-400"

  attr(:provider_connection, :map, required: true)

  defp circuit_breaker_section(assigns) do
    conn = assigns.provider_connection
    failures = Map.get(conn, :consecutive_failures, 0)

    assigns =
      assigns
      |> assign(:has_http, Map.get(conn, :url) != nil)
      |> assign(:has_ws, Map.get(conn, :ws_url) != nil)
      |> assign(:http_state, Map.get(conn, :http_circuit_state, :closed))
      |> assign(:ws_state, Map.get(conn, :ws_circuit_state, :closed))
      |> assign(:ws_connected, Map.get(conn, :ws_connected, false))
      |> assign(:failures, failures)
      |> assign(:failures_class, if(failures > 0, do: "text-red-400", else: "text-gray-300"))
      |> assign(:successes, Map.get(conn, :consecutive_successes, 0))

    ~H"""
    <DetailPanelComponents.panel_section>
      <DetailPanelComponents.section_header title="Circuit Breaker" />
      <div class="space-y-2">
        <div :if={@has_http}>
          <DetailPanelComponents.circuit_breaker_row label="HTTP" state={@http_state} />
          <DetailPanelComponents.circuit_breaker_labels />
        </div>

        <div :if={@has_ws}>
          <DetailPanelComponents.circuit_breaker_row
            label="WS"
            state={@ws_state}
            connected={@ws_connected}
            class="mt-3"
          />
          <DetailPanelComponents.circuit_breaker_labels />
        </div>

        <div class="flex justify-between text-xs text-gray-400 pt-2 border-gray-800">
          <span>
            Failures: <span class={@failures_class}>{@failures}/5</span> threshold
          </span>
          <span>
            Successes: <span class="text-emerald-400">{@successes}</span> consecutive
          </span>
        </div>
      </div>
    </DetailPanelComponents.panel_section>
    """
  end

  attr(:provider_connection, :map, required: true)
  attr(:provider_unified_events, :list, required: true)

  defp issues_section(assigns) do
    active_alerts = build_active_alerts(assigns.provider_connection)

    event_feed =
      assigns.provider_unified_events
      |> Enum.filter(&relevant_event?/1)
      |> Enum.take(15)

    has_content = length(active_alerts) > 0 or length(event_feed) > 0

    assigns =
      assigns
      |> assign(:active_alerts, active_alerts)
      |> assign(:event_feed, event_feed)
      |> assign(:has_content, has_content)

    ~H"""
    <DetailPanelComponents.panel_section>
      <DetailPanelComponents.section_header title="Issues" />

      <div :if={length(@active_alerts) > 0} class="space-y-2 mb-3">
        <DetailPanelComponents.alert_item
          :for={{severity, message, detail} <- @active_alerts}
          severity={severity}
          message={message}
          detail={detail}
        />
      </div>

      <div :if={length(@event_feed) > 0}>
        <div class="max-h-64 overflow-y-auto space-y-1.5 pr-1">
          <.event_feed_item :for={event <- @event_feed} event={event} />
        </div>
        <div class="mt-2 pt-1 text-center">
          <span class="text-[10px] text-gray-500">{length(@event_feed)} events</span>
        </div>
      </div>

      <div :if={!@has_content} class="text-xs text-gray-500 text-center pt-2 pb-3">
        No issues detected
      </div>
    </DetailPanelComponents.panel_section>
    """
  end

  defp relevant_event?(event) do
    event[:kind] in [:circuit, :provider, :error] or event[:severity] in [:warn, :error]
  end

  attr(:event, :map, required: true)

  defp event_feed_item(assigns) do
    event = assigns.event
    display_message = format_event_message(event[:message] || "Unknown event")
    is_expandable = String.length(display_message) > 80 or has_event_details?(event)

    assigns =
      assigns
      |> assign(:severity_color, severity_dot_color(event[:severity]))
      |> assign(:time_ago, format_time_ago(event[:ts_ms]))
      |> assign(:display_message, display_message)
      |> assign(:is_expandable, is_expandable)
      |> assign(:preview_message, truncate_message(display_message, 80))
      |> assign(
        :event_id,
        "event-#{:erlang.phash2({event[:kind], event[:message], event[:ts_ms]})}"
      )

    ~H"""
    <details
      :if={@is_expandable}
      id={@event_id}
      phx-hook="ExpandableDetails"
      class="group bg-gray-800/30 rounded-lg hover:bg-gray-800/50 transition-colors"
    >
      <summary class="p-2 cursor-pointer list-none">
        <.event_row
          severity_color={@severity_color}
          message={@preview_message}
          time_ago={@time_ago}
          expandable={true}
        />
      </summary>
      <.event_details event={@event} display_message={@display_message} />
    </details>

    <div
      :if={!@is_expandable}
      class="bg-gray-800/30 rounded-lg p-2 hover:bg-gray-800/50 transition-colors"
    >
      <.event_row
        severity_color={@severity_color}
        message={@display_message}
        time_ago={@time_ago}
        expandable={false}
      />
    </div>
    """
  end

  attr(:severity_color, :string, required: true)
  attr(:message, :string, required: true)
  attr(:time_ago, :string, required: true)
  attr(:expandable, :boolean, required: true)

  defp event_row(assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-2">
      <div class="flex items-start gap-2 min-w-0 flex-1">
        <div class={["w-1.5 h-1.5 rounded-full mt-1.5 shrink-0", @severity_color]}></div>
        <span class="text-xs text-gray-300 break-words">{@message}</span>
      </div>
      <div class="flex items-center gap-1 shrink-0">
        <svg
          :if={@expandable}
          class="w-3 h-3 text-gray-500 transition-transform group-open:rotate-180"
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
        >
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" />
        </svg>
        <span class="text-[10px] text-gray-500">{@time_ago}</span>
      </div>
    </div>
    """
  end

  attr(:event, :map, required: true)
  attr(:display_message, :string, required: true)

  defp event_details(assigns) do
    error_code = get_in(assigns.event, [:meta, :error_code])
    error_message = get_in(assigns.event, [:meta, :error_message])
    error_category = get_in(assigns.event, [:meta, :error_category])
    transport = get_in(assigns.event, [:meta, :transport])

    assigns =
      assigns
      |> assign(:error_code, error_code)
      |> assign(:error_message, error_message)
      |> assign(:error_category, error_category)
      |> assign(:transport, transport)
      |> assign(:has_error_info, error_code || error_message)
      |> assign(:is_truncated, String.length(assigns.display_message) > 80)

    ~H"""
    <div class="px-2 pb-2 pt-1 ml-3.5 space-y-2">
      <div :if={@is_truncated} class="text-xs text-gray-300 break-words whitespace-pre-wrap">
        {@display_message}
      </div>

      <div :if={@has_error_info} class="space-y-1.5">
        <div :if={@error_message} class="text-[11px] text-red-400 break-words">{@error_message}</div>
        <div class="flex flex-wrap gap-1.5">
          <span
            :if={@error_code}
            class="px-1.5 py-0.5 rounded bg-red-900/30 text-red-400 text-[10px] font-mono"
          >
            ERR {@error_code}
          </span>
          <span
            :if={@error_category}
            class="px-1.5 py-0.5 rounded bg-gray-700/50 text-gray-400 text-[10px]"
          >
            {@error_category}
          </span>
        </div>
      </div>

      <div class="flex flex-wrap gap-1">
        <span
          :if={@event[:kind]}
          class="px-1.5 py-0.5 rounded bg-gray-700/50 text-[10px] text-gray-400"
        >
          {@event[:kind] |> to_string() |> String.capitalize()}
        </span>
        <span :if={@transport} class="px-1.5 py-0.5 rounded bg-gray-700/50 text-[10px] text-gray-400">
          {@transport}
        </span>
      </div>
    </div>
    """
  end

  defp severity_dot_color(:error), do: "bg-red-500"
  defp severity_dot_color(:warn), do: "bg-yellow-500"
  defp severity_dot_color(_), do: "bg-blue-500"

  defp format_time_ago(nil), do: "—"

  defp format_time_ago(ts_ms) do
    diff_ms = System.system_time(:millisecond) - ts_ms

    cond do
      diff_ms < 60_000 -> "now"
      diff_ms < 3_600_000 -> "#{div(diff_ms, 60_000)}m ago"
      true -> "#{div(diff_ms, 3_600_000)}h ago"
    end
  end

  defp truncate_message(message, max_length) when byte_size(message) > max_length do
    String.slice(message, 0, max_length - 3) <> "..."
  end

  defp truncate_message(message, _), do: message

  attr(:performance_metrics, :map, required: true)

  defp method_performance_section(assigns) do
    rpc_stats = Map.get(assigns.performance_metrics, :rpc_stats, [])
    max_calls = rpc_stats |> Enum.map(& &1.total_calls) |> Enum.max(fn -> 1 end)

    assigns =
      assigns
      |> assign(:rpc_stats, Enum.take(rpc_stats, 6))
      |> assign(:max_calls, max_calls)

    ~H"""
    <DetailPanelComponents.panel_section border={false}>
      <DetailPanelComponents.section_header title="Method Performance" />
      <div :if={length(@rpc_stats) > 0} class="space-y-2">
        <.method_stat_row :for={stat <- @rpc_stats} stat={stat} max_calls={@max_calls} />
        <div class="text-[10px] text-gray-600 text-right mt-2">(calls)</div>
      </div>
      <div :if={@rpc_stats == []} class="text-xs text-gray-500 text-center py-2">
        No recent method data
      </div>
    </DetailPanelComponents.panel_section>
    """
  end

  attr(:stat, :map, required: true)
  attr(:max_calls, :integer, required: true)

  defp method_stat_row(assigns) do
    stat = assigns.stat
    bar_width = if assigns.max_calls > 0, do: stat.total_calls / assigns.max_calls * 100, else: 0

    assigns =
      assigns
      |> assign(:bar_width, bar_width)
      |> assign(:latency, "#{Helpers.to_float(stat.avg_duration_ms) |> Float.round(0)}ms")
      |> assign(:success_pct, "#{(Helpers.to_float(stat.success_rate) * 100) |> Float.round(1)}%")
      |> assign(:success_class, success_rate_color(stat.success_rate * 100))

    ~H"""
    <div class="flex items-center gap-2 text-xs">
      <span class="w-28 text-gray-300 truncate font-mono" title={@stat.method}>{@stat.method}</span>
      <span class="w-16 text-gray-400">p50: {@latency}</span>
      <span class={["w-12", @success_class]}>{@success_pct}</span>
      <div class="flex-1 bg-gray-800 rounded h-2">
        <div class="bg-gray-600 h-2 rounded" style={"width: #{@bar_width}%"}></div>
      </div>
      <span class="w-14 text-right text-gray-500">{@stat.total_calls}</span>
    </div>
    """
  end

  defp build_active_alerts(conn) do
    []
    |> add_circuit_alerts(conn)
    |> add_rate_limit_alerts(conn)
    |> add_failure_alerts(conn)
    |> add_ws_disconnect_alert(conn)
  end

  defp add_circuit_alerts(alerts, conn) do
    http_cb = Map.get(conn, :http_circuit_state)
    ws_cb = Map.get(conn, :ws_circuit_state)

    alerts
    |> maybe_add(
      http_cb == :open,
      {:error, "HTTP circuit OPEN", format_cb_error(conn[:http_cb_error])}
    )
    |> maybe_add(ws_cb == :open, {:error, "WS circuit OPEN", format_cb_error(conn[:ws_cb_error])})
    |> maybe_add(http_cb == :half_open, {:warn, "HTTP circuit recovering", nil})
    |> maybe_add(ws_cb == :half_open, {:warn, "WS circuit recovering", nil})
  end

  defp add_rate_limit_alerts(alerts, conn) do
    http_limited = Map.get(conn, :http_rate_limited, false)
    ws_limited = Map.get(conn, :ws_rate_limited, false)
    remaining = Map.get(conn, :rate_limit_remaining, %{})

    case {http_limited, ws_limited} do
      {true, true} ->
        http_sec = div(Map.get(remaining, :http, 0), 1000)
        ws_sec = div(Map.get(remaining, :ws, 0), 1000)
        [{:warn, "Rate limited (HTTP: #{http_sec}s, WS: #{ws_sec}s)", nil} | alerts]

      {true, false} ->
        [{:warn, "HTTP rate limited (#{div(Map.get(remaining, :http, 0), 1000)}s)", nil} | alerts]

      {false, true} ->
        [{:warn, "WS rate limited (#{div(Map.get(remaining, :ws, 0), 1000)}s)", nil} | alerts]

      _ ->
        alerts
    end
  end

  defp add_failure_alerts(alerts, conn) do
    case Map.get(conn, :consecutive_failures, 0) do
      0 -> alerts
      n when n >= 3 -> [{:error, "#{n} consecutive failures", nil} | alerts]
      n -> [{:warn, "#{n} consecutive failures", nil} | alerts]
    end
  end

  defp add_ws_disconnect_alert(alerts, conn) do
    has_ws = Map.get(conn, :ws_url) != nil
    ws_connected = Map.get(conn, :ws_connected, false)
    ws_circuit_ok = Map.get(conn, :ws_circuit_state) != :open

    if has_ws and not ws_connected and ws_circuit_ok do
      [{:warn, "WebSocket disconnected", nil} | alerts]
    else
      alerts
    end
  end

  defp maybe_add(alerts, true, alert), do: [alert | alerts]
  defp maybe_add(alerts, false, _), do: alerts

  defp format_cb_error(nil), do: nil

  defp format_cb_error(error) when is_map(error) do
    %{
      code: error[:code] || error[:error_code],
      category: error[:category] || error[:error_category],
      message: error[:message] || error[:error_message]
    }
  end

  defp format_event_message(message) when is_binary(message) do
    if String.starts_with?(message, "%Lasso.JSONRPC.Error{") do
      parse_jsonrpc_error(message)
    else
      message
    end
  end

  defp format_event_message(other), do: inspect(other)

  defp parse_jsonrpc_error(message) do
    code = extract_field(message, "code:")
    msg = extract_field(message, "message:")
    category = extract_field(message, "category:")

    [msg, code, category]
    |> Enum.reject(&(&1 == nil or &1 == "nil"))
    |> Enum.map(fn
      ^msg -> clean_string_value(msg)
      ^code -> "ERR #{code}"
      ^category -> "(#{category})"
    end)
    |> case do
      [] -> message
      parts -> Enum.join(parts, " ")
    end
  end

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
    meta = event[:meta] || %{}
    meta[:error_code] || meta[:error_message] || meta[:error_category]
  end
end
