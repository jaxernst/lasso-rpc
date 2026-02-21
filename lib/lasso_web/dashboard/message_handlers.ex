defmodule LassoWeb.Dashboard.MessageHandlers do
  @moduledoc """
  Handles PubSub message processing for the Dashboard LiveView.
  """

  import Phoenix.Component, only: [assign: 3, update: 3]
  alias Lasso.Events.{Provider, Subscription}
  alias LassoWeb.Dashboard.{Constants, Helpers}

  def valid_provider?(socket, provider_id) do
    Enum.any?(socket.assigns[:connections] || [], &(&1.id == provider_id))
  end

  defp maybe_update_chain(socket, chain, update_fn) do
    if socket.assigns[:selected_chain] == chain, do: update_fn.(socket), else: socket
  end

  def handle_provider_event(
        evt,
        socket,
        buffer_event_fn,
        fetch_connections_fn,
        update_chain_fn,
        update_provider_fn
      )
      when is_struct(evt, Provider.Healthy) or is_struct(evt, Provider.Unhealthy) or
             is_struct(evt, Provider.HealthCheckFailed) or is_struct(evt, Provider.WSConnected) or
             is_struct(evt, Provider.WSClosed) or is_struct(evt, Provider.WSDisconnected) do
    {chain, pid, event_type, details, ts} = extract_provider_event_data(evt)

    if chain in Map.get(socket.assigns, :profile_chains, []) and
         valid_provider?(socket, pid) do
      entry = %{
        ts: DateTime.utc_now() |> DateTime.to_time() |> to_string(),
        ts_ms: ts,
        chain: chain,
        provider_id: pid,
        event: event_type,
        details: details
      }

      uev =
        Helpers.as_event(:provider,
          chain: chain,
          provider_id: pid,
          severity: :info,
          message: to_string(event_type),
          meta: Map.drop(entry, [:ts, :ts_ms])
        )

      socket
      |> update(:provider_events, &[entry | Enum.take(&1, Constants.provider_events_limit() - 1)])
      |> buffer_event_fn.(uev)
      |> maybe_refresh_provider(pid, fetch_connections_fn, update_provider_fn)
      |> maybe_update_chain(chain, update_chain_fn)
    else
      socket
    end
  end

  defp extract_provider_event_data(evt) do
    case evt do
      %Provider.Healthy{chain: c, provider_id: p, ts: t} ->
        {c, p, :healthy, nil, t}

      %Provider.Unhealthy{chain: c, provider_id: p, ts: t} ->
        {c, p, :unhealthy, nil, t}

      %Provider.HealthCheckFailed{chain: c, provider_id: p, reason: r, ts: t} ->
        {c, p, :health_check_failed, %{reason: r}, t}

      %Provider.WSConnected{chain: c, provider_id: p, ts: t} ->
        {c, p, :ws_connected, nil, t}

      %Provider.WSClosed{chain: c, provider_id: p, code: code, reason: r, ts: t} ->
        {c, p, :ws_closed, %{code: code, reason: r}, t}

      %Provider.WSDisconnected{chain: c, provider_id: p, reason: r, ts: t} ->
        {c, p, :ws_disconnected, %{reason: r}, t}
    end
  end

  defp maybe_refresh_provider(socket, provider_id, fetch_fn, update_fn) do
    if socket.assigns[:selected_provider] == provider_id do
      socket |> fetch_fn.() |> update_fn.()
    else
      socket
    end
  end

  def handle_events_batch(socket, events) do
    routing_entries = transform_to_routing_entries(events, socket.assigns.profile_chains)

    socket
    |> update(:events, fn existing ->
      Enum.take(events ++ existing, Constants.routing_events_limit())
    end)
    |> update(:routing_events, fn existing ->
      Enum.take(routing_entries ++ existing, Constants.routing_events_limit())
    end)
  end

  def handle_events_snapshot(socket, events) do
    # Transform RoutingDecision-style events for routing_events display
    routing_entries = transform_to_routing_entries(events, socket.assigns.profile_chains)

    socket
    |> assign(:events, events)
    |> assign(:routing_events, routing_entries)
  end

  defp transform_to_routing_entries(events, profile_chains) do
    profile_chains_set = MapSet.new(profile_chains)

    events
    |> Enum.filter(fn e ->
      # Include routing-decision style events with either atom or string keys.
      # Be tolerant of chain field shapes to avoid dropping valid HTTP events.
      method = normalize_string(field(e, :method))
      chain = normalize_string(field(e, :chain))

      is_binary(method) and is_binary(chain) and
        (MapSet.size(profile_chains_set) == 0 or MapSet.member?(profile_chains_set, chain))
    end)
    |> Enum.map(fn e ->
      chain = normalize_string(field(e, :chain))
      method = normalize_string(field(e, :method))

      %{
        ts: format_time(field(e, :ts)),
        ts_ms: normalize_timestamp(field(e, :ts)),
        chain: chain,
        method: method,
        strategy: field(e, :strategy),
        provider_id: field(e, :provider_id),
        duration_ms: field(e, :duration_ms) || 0,
        result: field(e, :result) || :unknown,
        failovers: field(e, :failover_count) || 0,
        source_node: field(e, :source_node),
        source_node_id: field(e, :source_node_id)
      }
    end)
  end

  defp field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp normalize_string(value) when is_binary(value), do: value
  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(_), do: nil

  def handle_subscription_event(evt, socket, buffer_event_fn) do
    {chain, provider_id, event_kind, sub_type, details, ts} =
      extract_subscription_event_data(evt)

    if chain in Map.get(socket.assigns, :profile_chains, []) do
      entry = %{
        type: :ws_lifecycle,
        ts: format_time(ts),
        ts_ms: ts,
        chain: chain,
        provider_id: provider_id,
        event: event_kind,
        subscription_type: sub_type,
        details: details
      }

      uev =
        Helpers.as_event(:subscription,
          chain: chain,
          provider_id: provider_id,
          severity: subscription_event_severity(event_kind),
          message: subscription_event_label(event_kind, sub_type),
          meta: details
        )

      socket
      |> update(:routing_events, &[entry | Enum.take(&1, Constants.routing_events_limit() - 1)])
      |> buffer_event_fn.(uev)
    else
      socket
    end
  end

  defp extract_subscription_event_data(%Subscription.Established{} = evt) do
    {evt.chain, evt.provider_id, :subscription_established, evt.subscription_type, %{}, evt.ts}
  end

  defp extract_subscription_event_data(%Subscription.Failed{} = evt) do
    {evt.chain, evt.provider_id, :subscription_failed, evt.subscription_type,
     %{reason: evt.reason}, evt.ts}
  end

  defp extract_subscription_event_data(%Subscription.Failover{} = evt) do
    {evt.chain, evt.to_provider_id, :subscription_failover, evt.subscription_type,
     %{from_provider_id: evt.from_provider_id, to_provider_id: evt.to_provider_id}, evt.ts}
  end

  defp extract_subscription_event_data(%Subscription.Stale{} = evt) do
    {evt.chain, evt.provider_id, :subscription_stale, evt.subscription_type,
     %{stale_duration_ms: evt.stale_duration_ms}, evt.ts}
  end

  defp subscription_event_severity(:subscription_established), do: :info
  defp subscription_event_severity(:subscription_failed), do: :error
  defp subscription_event_severity(:subscription_failover), do: :warn
  defp subscription_event_severity(:subscription_stale), do: :warn

  defp subscription_event_label(event_kind, sub_type) do
    type_str = subscription_type_label(sub_type)

    case event_kind do
      :subscription_established -> "subscribed #{type_str}"
      :subscription_failed -> "subscribe failed #{type_str}"
      :subscription_failover -> "failover #{type_str}"
      :subscription_stale -> "stale #{type_str}"
    end
  end

  defp subscription_type_label(:new_heads), do: "newHeads"
  defp subscription_type_label(:logs), do: "logs"
  defp subscription_type_label(_), do: "unknown"

  defp format_time(ts) when is_integer(ts) do
    ts |> DateTime.from_unix!(:millisecond) |> DateTime.to_time() |> to_string()
  end

  defp format_time(_), do: DateTime.utc_now() |> DateTime.to_time() |> to_string()

  defp normalize_timestamp(ts) when is_integer(ts), do: ts
  defp normalize_timestamp(_), do: System.system_time(:millisecond)
end
