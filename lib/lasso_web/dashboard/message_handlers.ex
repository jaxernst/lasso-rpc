defmodule LassoWeb.Dashboard.MessageHandlers do
  @moduledoc """
  Handles PubSub message processing for the Dashboard LiveView.
  """

  import Phoenix.Component, only: [assign: 3, update: 3]
  import Phoenix.LiveView, only: [push_event: 3]
  alias Lasso.Events.Provider
  alias LassoWeb.Dashboard.{Constants, Helpers}

  def handle_connection_status_update(connections, socket, buffer_event_fn) do
    prev_by_id = socket.assigns |> Map.get(:connections, []) |> Map.new(&{&1.id, &1})

    diff_events =
      connections
      |> Enum.flat_map(fn conn ->
        case Map.get(prev_by_id, conn.id) do
          nil -> []
          prev -> build_connection_diff_events(conn, prev)
        end
      end)

    socket
    |> assign(:connections, connections)
    |> assign(:last_updated, DateTime.utc_now() |> DateTime.to_string())
    |> buffer_events(diff_events, buffer_event_fn)
  end

  defp build_connection_diff_events(conn, prev) do
    status_event = build_status_change_event(conn, prev)
    reconnect_event = build_reconnect_event(conn, prev)
    Enum.reject([status_event, reconnect_event], &is_nil/1)
  end

  defp build_status_change_event(conn, prev) do
    if conn.status != prev.status do
      Helpers.as_event(:provider,
        chain: conn.chain,
        provider_id: conn.id,
        severity: if(conn.status == :connected, do: :info, else: :warn),
        message: "status #{prev.status} -> #{conn.status}",
        meta: %{name: conn.name}
      )
    end
  end

  defp build_reconnect_event(conn, prev) do
    prev_attempts = Map.get(prev, :reconnect_attempts, 0)
    attempts = Map.get(conn, :reconnect_attempts, 0)

    if attempts > prev_attempts do
      Helpers.as_event(:provider,
        chain: conn.chain,
        provider_id: conn.id,
        severity: :warn,
        message: "reconnect attempt #{attempts}",
        meta: %{delta: attempts - prev_attempts}
      )
    end
  end

  defp buffer_events(socket, events, buffer_fn) do
    Enum.reduce(events, socket, &buffer_fn.(&2, &1))
  end

  def handle_routing_decision(evt, socket, buffer_event_fn, update_chain_fn, update_provider_fn) do
    %{chain: chain, method: method, strategy: strategy, provider_id: pid, duration_ms: dur} = evt

    if chain in Map.get(socket.assigns, :profile_chains, []) do
      entry = %{
        ts: DateTime.utc_now() |> DateTime.to_time() |> to_string(),
        ts_ms: System.system_time(:millisecond),
        chain: chain,
        method: method,
        strategy: strategy,
        provider_id: pid,
        duration_ms: if(is_number(dur), do: round(dur), else: 0),
        result: Map.get(evt, :result, :unknown),
        failovers: Map.get(evt, :failover_count, 0),
        source_node: Map.get(evt, :source_node),
        source_region: Map.get(evt, :source_region)
      }

      ev =
        Helpers.as_event(:rpc,
          chain: chain,
          provider_id: pid,
          severity: if(entry.result == :error, do: :warn, else: :info),
          message: "#{method} #{entry.result} (#{dur}ms)",
          meta: Map.drop(entry, [:ts, :ts_ms])
        )

      socket
      |> update(:routing_events, &[entry | Enum.take(&1, Constants.routing_events_limit() - 1)])
      |> buffer_event_fn.(ev)
      |> push_event("provider_request", %{provider_id: pid})
      |> maybe_update_chain(chain, update_chain_fn)
      |> maybe_update_provider(pid, update_provider_fn)
    else
      socket
    end
  end

  defp maybe_update_chain(socket, chain, update_fn) do
    if socket.assigns[:selected_chain] == chain, do: update_fn.(socket), else: socket
  end

  defp maybe_update_provider(socket, provider_id, update_fn) do
    if socket.assigns[:selected_provider] == provider_id, do: update_fn.(socket), else: socket
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
             is_struct(evt, Provider.WSClosed) do
    {chain, pid, event_type, details, ts} = extract_provider_event_data(evt)

    if chain in Map.get(socket.assigns, :profile_chains, []) do
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
    end
  end

  defp maybe_refresh_provider(socket, provider_id, fetch_fn, update_fn) do
    if socket.assigns[:selected_provider] == provider_id do
      socket |> fetch_fn.() |> update_fn.()
    else
      socket
    end
  end

  def handle_circuit_breaker_event(
        event_data,
        socket,
        buffer_event_fn,
        update_chain_fn,
        update_provider_fn
      ) do
    %{chain: chain, provider_id: pid, transport: transport, new_state: new_state} = event_data

    if chain in Map.get(socket.assigns, :profile_chains, []) do
      ev =
        Helpers.as_event(:circuit_breaker,
          chain: chain,
          provider_id: pid,
          transport: transport,
          severity: circuit_severity(new_state),
          message: "#{transport} circuit #{new_state}",
          meta: %{
            transport: transport,
            new_state: new_state,
            old_state: event_data[:old_state],
            reason: event_data[:reason],
            error_code: get_in(event_data, [:error, :code]),
            error_category: get_in(event_data, [:error, :category]),
            error_message: get_in(event_data, [:error, :message])
          }
        )

      socket
      |> buffer_event_fn.(ev)
      |> maybe_update_provider(pid, update_provider_fn)
      |> maybe_update_chain(chain, update_chain_fn)
    else
      socket
    end
  end

  defp circuit_severity(:closed), do: :info
  defp circuit_severity(:half_open), do: :warn
  defp circuit_severity(:open), do: :error

  def handle_block_event(blk, socket, buffer_event_fn, update_chain_fn, update_provider_fn)
      when is_map(blk) do
    %{chain: chain, block_number: bn} = blk

    if chain in Map.get(socket.assigns, :profile_chains, []) do
      ev =
        Helpers.as_event(:chain, chain: chain, severity: :info, message: "block #{bn}", meta: blk)

      socket
      |> update(:latest_blocks, &Map.put(&1, chain, bn))
      |> buffer_event_fn.(ev)
      |> maybe_update_chain(chain, update_chain_fn)
      |> maybe_update_provider(blk[:provider_id], update_provider_fn)
    else
      socket
    end
  end

  def handle_events_batch(socket, events) do
    # Transform RoutingDecision-style events for routing_events display
    routing_entries = transform_to_routing_entries(events, socket.assigns.profile_chains)

    socket
    |> update(:events, &(events ++ &1))
    |> update(
      :routing_events,
      &(routing_entries ++
          Enum.take(&1, Constants.routing_events_limit() - length(routing_entries)))
    )
  end

  def handle_events_snapshot(socket, events) do
    # Transform RoutingDecision-style events for routing_events display
    routing_entries = transform_to_routing_entries(events, socket.assigns.profile_chains)

    socket
    |> assign(:events, events)
    |> assign(:routing_events, routing_entries)
  end

  defp transform_to_routing_entries(events, profile_chains) do
    events
    |> Enum.filter(fn e ->
      # Only include events that are routing decisions for this profile's chains
      Map.has_key?(e, :method) and Map.get(e, :chain) in profile_chains
    end)
    |> Enum.map(fn e ->
      %{
        ts: format_time(Map.get(e, :ts)),
        ts_ms: normalize_timestamp(Map.get(e, :ts)),
        chain: Map.get(e, :chain),
        method: Map.get(e, :method),
        strategy: Map.get(e, :strategy),
        provider_id: Map.get(e, :provider_id),
        duration_ms: Map.get(e, :duration_ms, 0),
        result: Map.get(e, :result, :unknown),
        failovers: Map.get(e, :failover_count, 0),
        source_node: Map.get(e, :source_node),
        source_region: Map.get(e, :source_region)
      }
    end)
  end

  defp format_time(ts) when is_integer(ts) do
    ts |> DateTime.from_unix!(:millisecond) |> DateTime.to_time() |> to_string()
  end

  defp format_time(_), do: DateTime.utc_now() |> DateTime.to_time() |> to_string()

  defp normalize_timestamp(ts) when is_integer(ts), do: ts
  defp normalize_timestamp(_), do: System.system_time(:millisecond)
end
