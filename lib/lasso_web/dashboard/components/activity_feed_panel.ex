defmodule LassoWeb.Dashboard.Components.ActivityFeedPanel do
  @moduledoc """
  LiveComponent for the collapsed profile overview activity feed.

  Extracted from the collapsed_profile_preview function component so that
  `routing_events` (which changes every batch) has independent change tracking
  and doesn't cause the entire profile overview to re-render.
  """
  use LassoWeb, :live_component

  @impl true
  def update(assigns, socket) do
    {:ok,
     assign(
       socket,
       :routing_events,
       assigns[:routing_events] || socket.assigns[:routing_events] || []
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="px-5 pb-4">
      <h4 class="text-xs font-semibold text-gray-500 mb-2">
        Live Activity
      </h4>
      <div
        id="recent-activity-feed"
        phx-hook="ActivityFeed"
        class="flex max-h-32 flex-col gap-1 overflow-y-auto"
        style="overflow-anchor: none;"
      >
        <%= for e <- Enum.take(@routing_events, 100) do %>
          <%= if e[:type] == :ws_lifecycle do %>
            <div
              data-event-id={e[:ts_ms]}
              class="text-[9px] text-gray-300 flex items-center gap-1 shrink-0"
            >
              <span class="text-cyan-400">ws</span>
              <span class="text-purple-300">{e.chain}</span>
              <span class={ws_event_color(e.event)}>
                {ws_event_label(e.event, e.subscription_type)}
              </span>
              → <span class="text-emerald-300">{String.slice(e.provider_id || "", 0, 14)}…</span>
            </div>
          <% else %>
            <div
              data-event-id={e[:ts_ms]}
              class="text-[9px] text-gray-300 flex items-center gap-1 shrink-0"
            >
              <span class="text-purple-300">{e.chain}</span>
              <span class="text-sky-300">{e.method}</span>
              → <span class="text-emerald-300">{String.slice(e.provider_id || "", 0, 14)}…</span>
              <span class={[
                "",
                if(e[:result] == :error, do: "text-red-400", else: "text-yellow-300")
              ]}>
                ({e[:duration_ms] || 0}ms)
              </span>
              <%= if (e[:failovers] || 0) > 0 do %>
                <span
                  class="inline-flex items-center px-1 py-0.5 rounded text-[8px] text-orange-300 font-bold bg-orange-900/50"
                  title={"#{e[:failovers]} failover(s)"}
                >
                  ↻{e[:failovers]}
                </span>
              <% end %>
            </div>
          <% end %>
        <% end %>
        <%= if length(@routing_events) == 0 do %>
          <div class="text-[10px] text-gray-600">Waiting for requests...</div>
        <% end %>
      </div>
    </div>
    """
  end

  defp ws_event_color(:subscription_established), do: "text-green-400"
  defp ws_event_color(:subscription_failed), do: "text-red-400"
  defp ws_event_color(:subscription_failover), do: "text-orange-300"
  defp ws_event_color(:subscription_stale), do: "text-yellow-400"
  defp ws_event_color(_), do: "text-gray-400"

  defp ws_event_label(:subscription_established, type), do: "subscribed #{sub_type_label(type)}"
  defp ws_event_label(:subscription_failed, type), do: "failed #{sub_type_label(type)}"
  defp ws_event_label(:subscription_failover, type), do: "failover #{sub_type_label(type)}"
  defp ws_event_label(:subscription_stale, type), do: "stale #{sub_type_label(type)}"
  defp ws_event_label(_, type), do: sub_type_label(type)

  defp sub_type_label(:new_heads), do: "newHeads"
  defp sub_type_label(:logs), do: "logs"
  defp sub_type_label(_), do: ""
end
