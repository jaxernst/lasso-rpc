defmodule LassoWeb.Components.FloatingWindowExamples do
  @moduledoc """
  Complete working examples of refactored floating windows using the
  FloatingWindow component library.

  These examples demonstrate real-world usage patterns and can serve as
  templates for migrating existing windows.
  """

  use Phoenix.Component
  import LassoWeb.Components.FloatingWindow
  alias LassoWeb.Dashboard.{Helpers, StatusHelpers}

  # ===========================================================================
  # Example 1: Provider Details Window (from dashboard.ex)
  # ===========================================================================

  @doc """
  Provider details floating window - refactored version.

  This replaces the existing `floating_details_window` when a provider is selected.
  """
  attr :provider_id, :string, required: true
  attr :connections, :list, required: true
  attr :collapsed, :boolean, default: false
  attr :selected_chain, :string, default: nil
  attr :provider_events, :list, default: []
  attr :provider_unified_events, :list, default: []
  attr :provider_metrics, :map, default: %{}

  def provider_details_window(assigns) do
    # Find provider connection
    provider_connection = Enum.find(assigns.connections, &(&1.id == assigns.provider_id))
    provider_name = if provider_connection, do: provider_connection.name, else: assigns.provider_id

    # Determine status for header indicator
    status = cond do
      !provider_connection -> :error
      provider_connection.status == :connected -> :healthy
      provider_connection.status == :connecting -> :warning
      true -> :degraded
    end

    assigns = assigns
      |> assign(:provider_connection, provider_connection)
      |> assign(:provider_name, provider_name)
      |> assign(:status, status)

    ~H"""
    <.floating_window
      id="provider-details"
      position={:top_right}
      collapsed={@collapsed}
      on_toggle="toggle_details_panel"
    >
      <:header>
        <.status_indicator status={@status} />
        <div class="truncate text-xs text-gray-300"><%= @provider_name %></div>

        <%= if @collapsed do %>
          <.provider_collapsed_preview provider_metrics={@provider_metrics} />
        <% end %>
      </:header>

      <:body>
        <!-- Primary Metrics Section -->
        <.window_section border={:bottom}>
          <.metrics_grid>
            <.metric_card
              label="p50 (5m)"
              value={format_latency(@provider_metrics[:p50_latency])}
              value_class="text-sky-400"
            />
            <.metric_card
              label="p95 (5m)"
              value={format_latency(@provider_metrics[:p95_latency])}
              value_class="text-sky-400"
            />
            <.metric_card
              label="Success (5m)"
              value={format_success_rate(@provider_metrics[:success_rate])}
              value_class={success_rate_color(@provider_metrics[:success_rate])}
            />
            <.metric_card
              label="Calls (1h)"
              value={to_string(@provider_metrics[:calls_last_hour] || 0)}
              value_class="text-purple-400"
            />
          </.metrics_grid>
        </.window_section>

        <!-- Status Details Section -->
        <%= if @provider_connection do %>
          <.window_section title="Status Details" border={:bottom}>
            <.provider_status_grid provider={@provider_connection} />
          </.window_section>
        <% end %>

        <!-- Routing Context Section -->
        <.window_section title="Routing Decisions" border={:bottom}>
          <.provider_routing_stats
            provider_metrics={@provider_metrics}
            provider_id={@provider_id}
            connections={@connections}
          />
        </.window_section>

        <!-- Activity Feed Section -->
        <.window_section title="Activity" border={:none} class="flex-1 overflow-hidden">
          <.event_feed
            id="provider-activity"
            events={Enum.take(@provider_unified_events, 60)}
            empty_message={"No recent activity for #{@provider_name}"}
          >
            <:event :let={e}>
              <div class="bg-gray-800/30 rounded-lg p-2">
                <div class="text-[11px] text-gray-400">
                  <span class="text-gray-500">[{e.ts}]</span>
                  <span class="ml-1 text-emerald-300">{@provider_id}</span>
                  <span class="ml-1">{e.message}</span>
                </div>
              </div>
            </:event>
          </.event_feed>
        </.window_section>
      </:body>
    </.floating_window>
    """
  end

  # Provider collapsed preview
  defp provider_collapsed_preview(assigns) do
    ~H"""
    <div class="flex items-center gap-3 text-[10px]">
      <span class="text-gray-400">
        p50: <span class="text-sky-300">{format_latency(@provider_metrics[:p50_latency])}</span>
      </span>
      <span class="text-gray-400">
        Success: <span class={success_rate_color(@provider_metrics[:success_rate])}>
          {format_success_rate(@provider_metrics[:success_rate])}
        </span>
      </span>
    </div>
    """
  end

  # Provider status grid showing health, circuit state, websocket status
  defp provider_status_grid(assigns) do
    ~H"""
    <div class="grid grid-cols-2 md:grid-cols-4 gap-3 text-sm">
      <div class="flex flex-col">
        <span class="text-gray-400 text-xs">Status</span>
        <span class={StatusHelpers.provider_status_class_text(@provider)}>
          {StatusHelpers.provider_status_label(@provider)}
        </span>
      </div>

      <div class="flex flex-col">
        <span class="text-gray-400 text-xs">Health</span>
        <span class={StatusHelpers.provider_status_class_text(%{health_status: @provider.health_status})}>
          {@provider.health_status |> to_string() |> String.upcase()}
        </span>
      </div>

      <div class="flex flex-col">
        <span class="text-gray-400 text-xs">Circuit</span>
        <span class={circuit_state_color(@provider.circuit_state)}>
          {@provider.circuit_state |> to_string() |> String.upcase()}
        </span>
      </div>

      <div class="flex flex-col">
        <span class="text-gray-400 text-xs">WebSocket</span>
        <span class={ws_status_color(@provider)}>
          {ws_status_label(@provider)}
        </span>
      </div>
    </div>

    <!-- Issues Alert (if present) -->
    <%= if has_current_issues?(@provider) do %>
      <div class="bg-red-900/20 border border-red-600/30 rounded-lg p-3 mt-3">
        <div class="flex items-center gap-2 mb-2">
          <div class="w-2 h-2 rounded-full bg-red-400"></div>
          <span class="text-red-300 text-sm font-medium">Issues Detected</span>
        </div>
        <div class="text-xs text-gray-300 space-y-1">
          <div>Consecutive failures: <span class="text-red-300">{@provider.consecutive_failures}</span></div>
          <div>Reconnect attempts: <span class="text-yellow-300">{@provider.reconnect_attempts}</span></div>
        </div>
      </div>
    <% end %>
    """
  end

  # Provider routing statistics
  defp provider_routing_stats(assigns) do
    ~H"""
    <div class="space-y-3">
      <div class="text-xs text-gray-300">
        <span class="text-gray-400">Pick share (5m):</span>
        <span class="ml-2 text-white">
          {(@provider_metrics[:pick_share_5m] || 0.0) |> Helpers.to_float() |> Float.round(1)}%
        </span>
      </div>

      <!-- Top Methods -->
      <div>
        <div class="text-[11px] text-gray-400 mb-2">Top methods (5m)</div>
        <div class="space-y-1 max-h-32 overflow-y-auto">
          <%= for stat <- Enum.take(@provider_metrics[:rpc_stats] || [], 5) do %>
            <div class="flex items-center justify-between text-[11px]">
              <span class="text-sky-300 truncate">{stat.method}</span>
              <div class="flex items-center gap-3">
                <span class="text-gray-400">
                  {Helpers.to_float(stat.avg_duration_ms) |> Float.round(1)}ms
                </span>
                <span class={success_rate_color(stat.success_rate)}>
                  {(Helpers.to_float(stat.success_rate) * 100) |> Float.round(1)}%
                </span>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # ===========================================================================
  # Example 2: Chain Details Window
  # ===========================================================================

  @doc """
  Chain details floating window - refactored version.
  """
  attr :chain, :string, required: true
  attr :connections, :list, required: true
  attr :collapsed, :boolean, default: false
  attr :chain_metrics, :map, default: %{}
  attr :chain_events, :list, default: []
  attr :chain_endpoints, :map, default: %{}

  def chain_details_window(assigns) do
    # Filter connections for this chain
    chain_connections = Enum.filter(assigns.connections, &(&1.chain == assigns.chain))

    # Determine status
    connected = Enum.count(chain_connections, &(&1.status == :connected))
    total = length(chain_connections)

    status = cond do
      connected == total && total > 0 -> :healthy
      connected == 0 -> :error
      true -> :degraded
    end

    assigns = assigns
      |> assign(:chain_connections, chain_connections)
      |> assign(:connected_count, connected)
      |> assign(:total_count, total)
      |> assign(:status, status)

    ~H"""
    <.floating_window
      id="chain-details"
      position={:top_right}
      collapsed={@collapsed}
      on_toggle="toggle_details_panel"
    >
      <:header>
        <.status_indicator status={@status} />
        <div class="truncate text-xs text-gray-300">
          <%= String.capitalize(@chain) %>
        </div>

        <%= if @collapsed do %>
          <.chain_collapsed_preview
            connected={@connected_count}
            total={@total_count}
            chain_metrics={@chain_metrics}
          />
        <% end %>
      </:header>

      <:body>
        <!-- Overview Section -->
        <.window_section border={:bottom}>
          <div class="mb-3">
            <div class="text-xs text-gray-400">
              Chain ID: <span class="text-white">{Helpers.get_chain_id(@chain)}</span>
            </div>
            <div class="text-xs text-gray-400">
              Providers: <span class="text-emerald-400">{@connected_count}</span>/<span class="text-gray-500">{@total_count}</span>
            </div>
          </div>

          <.metrics_grid>
            <.metric_card
              label="Latency p50 (5m)"
              value={format_latency(@chain_metrics[:p50_latency])}
            />
            <.metric_card
              label="Latency p95 (5m)"
              value={format_latency(@chain_metrics[:p95_latency])}
            />
            <.metric_card
              label="Success (5m)"
              value={format_success_rate(@chain_metrics[:success_rate])}
              value_class={success_rate_color(@chain_metrics[:success_rate])}
            />
            <.metric_card
              label="RPS"
              value={to_string(@chain_metrics[:rps] || 0)}
              value_class="text-purple-400"
            />
          </.metrics_grid>
        </.window_section>

        <!-- Routing Strategy Section -->
        <.window_section title="Routing Strategy" border={:bottom}>
          <.routing_strategy_selector
            chain={@chain}
            chain_endpoints={@chain_endpoints}
          />
        </.window_section>

        <!-- Endpoints Section -->
        <.window_section title="RPC Endpoints" border={:bottom}>
          <.endpoint_display chain_endpoints={@chain_endpoints} />
        </.window_section>

        <!-- Events Section -->
        <.window_section title="Chain Events" border={:none} class="flex-1 overflow-hidden">
          <.event_feed
            id="chain-events"
            events={Enum.take(@chain_events, 50)}
            empty_message={"No recent events for #{String.capitalize(@chain)}"}
          >
            <:event :let={event}>
              <div class="bg-gray-800/30 rounded-lg p-2">
                <div class="flex items-center justify-between text-xs">
                  <div class="flex items-center space-x-2">
                    <div class={["w-2 h-2 rounded-full", event_kind_color(event[:kind])]}></div>
                    <span class="font-mono text-gray-300">{event[:kind]}</span>
                    <%= if event[:method] do %>
                      <span class="text-sky-400">{event[:method]}</span>
                    <% end %>
                  </div>
                  <span class="text-gray-500">{Helpers.format_timestamp(event[:ts_ms])}</span>
                </div>
                <%= if event[:message] do %>
                  <div class="text-xs text-gray-400 mt-1">{event[:message]}</div>
                <% end %>
              </div>
            </:event>
          </.event_feed>
        </.window_section>
      </:body>
    </.floating_window>
    """
  end

  # Chain collapsed preview
  defp chain_collapsed_preview(assigns) do
    ~H"""
    <div class="flex items-center gap-3 text-[10px]">
      <span class="text-gray-400">
        Providers: <span class="text-emerald-300">{@connected}</span>/<span class="text-gray-500">{@total}</span>
      </span>
      <span class="text-gray-400">
        p50: <span class="text-sky-300">{format_latency(@chain_metrics[:p50_latency])}</span>
      </span>
    </div>
    """
  end

  # Routing strategy selector UI
  defp routing_strategy_selector(assigns) do
    ~H"""
    <div class="space-y-3">
      <div class="text-xs text-gray-400">Select routing strategy:</div>
      <div class="flex flex-wrap gap-2">
        <%= for strategy <- ["fastest", "round-robin", "latency-weighted"] do %>
          <button
            phx-click="select_strategy"
            phx-value-chain={@chain}
            phx-value-strategy={strategy}
            class={[
              "px-3 py-1 rounded-full text-xs transition-all border",
              strategy_button_class(strategy)
            ]}
          >
            <%= strategy_label(strategy) %>
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  # Endpoint display component
  defp endpoint_display(assigns) do
    ~H"""
    <div class="space-y-3">
      <!-- HTTP Endpoint -->
      <div>
        <div class="text-xs font-medium text-gray-300 mb-1">HTTP</div>
        <div class="flex gap-1">
          <div class="flex-1 text-xs font-mono text-gray-400 bg-gray-900/50 rounded px-2 py-1 break-all">
            {@chain_endpoints[:http_url] || "http://localhost:4000/rpc/#{@chain}"}
          </div>
          <button class="border border-gray-700 hover:border-gray-600 rounded px-2 py-1 text-xs">
            Copy
          </button>
        </div>
      </div>

      <!-- WebSocket Endpoint -->
      <div>
        <div class="text-xs font-medium text-gray-300 mb-1">WebSocket</div>
        <div class="flex gap-1">
          <div class="flex-1 text-xs font-mono text-gray-400 bg-gray-900/50 rounded px-2 py-1 break-all">
            {@chain_endpoints[:ws_url] || "ws://localhost:4000/ws/#{@chain}"}
          </div>
          <button class="border border-gray-700 hover:border-gray-600 rounded px-2 py-1 text-xs">
            Copy
          </button>
        </div>
      </div>
    </div>
    """
  end

  # ===========================================================================
  # Example 3: Simple Notification Window
  # ===========================================================================

  @doc """
  Simple notification window - demonstrates minimal usage.
  """
  attr :collapsed, :boolean, default: false
  attr :notifications, :list, default: []

  def notification_window(assigns) do
    unread_count = Enum.count(assigns.notifications, &(!&1.read))

    assigns = assign(assigns, :unread_count, unread_count)

    ~H"""
    <.floating_window
      id="notifications"
      position={:top_right}
      collapsed={@collapsed}
      on_toggle="toggle_notifications"
      size={%{collapsed: "w-80 h-12", expanded: "w-96 h-[24rem]"}}
    >
      <:header>
        <.status_indicator status={:info} animated={@unread_count > 0} />
        <span class="text-xs text-gray-300">Notifications</span>
        <%= if @collapsed && @unread_count > 0 do %>
          <span class="bg-red-500 text-white text-[10px] px-1.5 rounded-full">
            {@unread_count}
          </span>
        <% end %>
      </:header>

      <:body>
        <.event_feed
          id="notifications-feed"
          events={@notifications}
          empty_message="No notifications"
        >
          <:event :let={notif}>
            <div class={[
              "bg-gray-800/30 rounded-lg p-3 border-l-2",
              if(notif.read, do: "border-gray-600", else: "border-sky-500")
            ]}>
              <div class="text-xs font-medium text-white">{notif.title}</div>
              <div class="text-xs text-gray-400 mt-1">{notif.message}</div>
              <div class="text-[10px] text-gray-500 mt-2">{notif.timestamp}</div>
            </div>
          </:event>
        </.event_feed>
      </:body>

      <:footer>
        <.action_group align={:right}>
          <button class="text-xs text-sky-400 hover:text-sky-300">
            Mark all read
          </button>
        </.action_group>
      </:footer>
    </.floating_window>
    """
  end

  # ===========================================================================
  # Helper Functions
  # ===========================================================================

  defp format_latency(nil), do: "—"
  defp format_latency(latency), do: "#{round(latency)}ms"

  defp format_success_rate(nil), do: "—"
  defp format_success_rate(rate) when is_number(rate) do
    "#{Float.round(rate * 100, 1)}%"
  end
  defp format_success_rate(rate) when is_float(rate) do
    "#{Float.round(rate, 1)}%"
  end
  defp format_success_rate(_), do: "—"

  defp success_rate_color(nil), do: "text-gray-600"
  defp success_rate_color(rate) when is_number(rate) do
    cond do
      rate >= 0.95 -> "text-emerald-400"
      rate >= 0.8 -> "text-yellow-400"
      true -> "text-red-400"
    end
  end
  defp success_rate_color(_), do: "text-gray-600"

  defp circuit_state_color(:open), do: "text-red-400"
  defp circuit_state_color(:half_open), do: "text-yellow-400"
  defp circuit_state_color(:closed), do: "text-emerald-400"
  defp circuit_state_color(_), do: "text-gray-400"

  defp ws_status_color(provider) do
    has_ws = Map.get(provider, :type) in [:websocket, :both]
    connected = Map.get(provider, :ws_connected, false)

    cond do
      !has_ws -> "text-gray-400"
      connected -> "text-emerald-400"
      true -> "text-red-400"
    end
  end

  defp ws_status_label(provider) do
    has_ws = Map.get(provider, :type) in [:websocket, :both]
    connected = Map.get(provider, :ws_connected, false)

    cond do
      !has_ws -> "NOT SUPPORTED"
      connected -> "CONNECTED"
      true -> "DISCONNECTED"
    end
  end

  defp has_current_issues?(provider) do
    is_rate_limited = Map.get(provider, :is_in_cooldown, false)
    has_failures = Map.get(provider, :consecutive_failures, 0) > 0
    has_reconnects = Map.get(provider, :reconnect_attempts, 0) > 0
    circuit_open = Map.get(provider, :circuit_state) == :open
    unhealthy = Map.get(provider, :health_status) == :unhealthy

    (has_failures || has_reconnects || circuit_open || unhealthy) && !is_rate_limited
  end

  defp event_kind_color(:rpc), do: "bg-blue-400"
  defp event_kind_color(:provider), do: "bg-emerald-400"
  defp event_kind_color(:error), do: "bg-red-400"
  defp event_kind_color(:benchmark), do: "bg-purple-400"
  defp event_kind_color(_), do: "bg-gray-400"

  defp strategy_button_class("fastest") do
    "border-sky-500 bg-sky-500/20 text-sky-300"
  end
  defp strategy_button_class(_) do
    "border-gray-600 text-gray-300 hover:border-sky-400 hover:text-sky-300"
  end

  defp strategy_label("fastest"), do: "⚡ Fastest"
  defp strategy_label("round-robin"), do: "🔄 Round Robin"
  defp strategy_label("latency-weighted"), do: "⚖️ Latency Weighted"
  defp strategy_label(other), do: other
end
