defmodule LassoWeb.Dashboard.MessageHandlers do
  @moduledoc """
  Handles PubSub message processing for the Dashboard LiveView.

  Each handler function takes event data and socket as parameters,
  processes the event, and returns the updated socket.
  """

  import Phoenix.Component, only: [assign: 3, update: 3]
  import Phoenix.LiveView, only: [push_event: 3]
  alias Lasso.Events.Provider
  alias LassoWeb.Dashboard.{Constants, Helpers}

  @doc """
  Handles connection status updates from ProviderPool.
  Generates diff events for status changes and reconnect attempts.
  """
  def handle_connection_status_update(connections, socket, buffer_event_fn) do
    prev = Map.get(socket.assigns, :connections, [])
    prev_by_id = Map.new(prev, fn c -> {c.id, c} end)

    {socket, batch} =
      Enum.reduce(connections, {socket, []}, fn c, {sock, acc} ->
        case Map.get(prev_by_id, c.id) do
          nil ->
            {sock, acc}

          prev_c ->
            new_acc =
              []
              |> then(fn lst ->
                if Map.get(c, :status) != Map.get(prev_c, :status) do
                  [
                    Helpers.as_event(:provider,
                      chain: Map.get(c, :chain),
                      provider_id: c.id,
                      severity:
                        case c.status do
                          :connected -> :info
                          :connecting -> :warn
                          _ -> :warn
                        end,
                      message: "status #{to_string(prev_c.status)} -> #{to_string(c.status)}",
                      meta: %{name: c.name}
                    )
                    | lst
                  ]
                else
                  lst
                end
              end)
              |> then(fn lst ->
                prev_attempts = Map.get(prev_c, :reconnect_attempts, 0)
                attempts = Map.get(c, :reconnect_attempts, 0)

                if attempts > prev_attempts do
                  [
                    Helpers.as_event(:provider,
                      chain: Map.get(c, :chain),
                      provider_id: c.id,
                      severity: :warn,
                      message: "reconnect attempt #{attempts}",
                      meta: %{delta: attempts - prev_attempts}
                    )
                    | lst
                  ]
                else
                  lst
                end
              end)

            {sock, acc ++ new_acc}
        end
      end)

    socket =
      socket
      |> assign(:connections, connections)
      |> assign(:last_updated, DateTime.utc_now() |> DateTime.to_string())

    Enum.reduce(batch, socket, fn event, sock ->
      buffer_event_fn.(sock, event)
    end)
  end

  @doc """
  Handles routing decision events from the router.
  Adds to routing_events list and creates unified event.
  """
  def handle_routing_decision(evt, socket, buffer_event_fn, update_chain_fn, update_provider_fn) do
    %{
      chain: chain,
      method: method,
      strategy: strategy,
      provider_id: pid,
      duration_ms: dur
    } = evt

    profile_chains = Map.get(socket.assigns, :profile_chains, [])

    if chain in profile_chains do
      entry = %{
        ts: DateTime.utc_now() |> DateTime.to_time() |> to_string(),
        ts_ms: System.system_time(:millisecond),
        chain: chain,
        method: method,
        strategy: strategy,
        provider_id: pid,
        duration_ms: if(is_number(dur), do: round(dur), else: 0),
        result: Map.get(evt, :result, :unknown),
        failovers: Map.get(evt, :failover_count, 0)
      }

      socket =
        update(socket, :routing_events, fn list ->
          [entry | Enum.take(list, Constants.routing_events_limit() - 1)]
        end)

      ev =
        Helpers.as_event(:rpc,
          chain: chain,
          provider_id: pid,
          severity: if(entry.result == :error, do: :warn, else: :info),
          message: "#{method} #{entry.result} (#{dur}ms)",
          meta: Map.drop(entry, [:ts, :ts_ms])
        )

      socket =
        socket
        |> buffer_event_fn.(ev)
        |> push_event("provider_request", %{provider_id: pid})

      socket =
        if socket.assigns[:selected_chain] == chain do
          update_chain_fn.(socket)
        else
          socket
        end

      socket =
        if socket.assigns[:selected_provider] == pid do
          update_provider_fn.(socket)
        else
          socket
        end

      socket
    else
      socket
    end
  end

  @doc """
  Handles provider health/connection events.
  Supports: Healthy, Unhealthy, HealthCheckFailed, WSConnected, WSClosed.
  """
  def handle_provider_event(evt, socket, buffer_event_fn, fetch_connections_fn, update_chain_fn, update_provider_fn)
      when is_struct(evt, Provider.Healthy) or
             is_struct(evt, Provider.Unhealthy) or
             is_struct(evt, Provider.HealthCheckFailed) or
             is_struct(evt, Provider.WSConnected) or
             is_struct(evt, Provider.WSClosed) do
    {chain, pid, event, details, ts} =
      case evt do
        %Provider.Healthy{chain: chain, provider_id: pid, ts: ts} ->
          {chain, pid, :healthy, nil, ts}

        %Provider.Unhealthy{chain: chain, provider_id: pid, ts: ts} ->
          {chain, pid, :unhealthy, nil, ts}

        %Provider.HealthCheckFailed{chain: chain, provider_id: pid, reason: reason, ts: ts} ->
          {chain, pid, :health_check_failed, %{reason: reason}, ts}

        %Provider.WSConnected{chain: chain, provider_id: pid, ts: ts} ->
          {chain, pid, :ws_connected, nil, ts}

        %Provider.WSClosed{chain: chain, provider_id: pid, code: code, reason: reason, ts: ts} ->
          {chain, pid, :ws_closed, %{code: code, reason: reason}, ts}
      end

    profile_chains = Map.get(socket.assigns, :profile_chains, [])

    if chain in profile_chains do
      entry = %{
        ts: DateTime.utc_now() |> DateTime.to_time() |> to_string(),
        ts_ms: ts,
        chain: chain,
        provider_id: pid,
        event: event,
        details: details
      }

      socket =
        update(socket, :provider_events, fn list ->
          [entry | Enum.take(list, Constants.provider_events_limit() - 1)]
        end)

      uev =
        Helpers.as_event(:provider,
          chain: chain,
          provider_id: pid,
          severity: :info,
          message: to_string(event),
          meta: Map.drop(entry, [:ts, :ts_ms])
        )

      socket = buffer_event_fn.(socket, uev)

      socket =
        if socket.assigns[:selected_provider] == pid do
          socket
          |> fetch_connections_fn.()
          |> update_provider_fn.()
        else
          socket
        end

      socket =
        if socket.assigns[:selected_chain] == chain do
          update_chain_fn.(socket)
        else
          socket
        end

      socket
    else
      socket
    end
  end

  @doc """
  Handles circuit breaker state change events.
  Creates unified event for display in provider panel.
  """
  def handle_circuit_breaker_event(event_data, socket, buffer_event_fn, update_chain_fn, update_provider_fn) do
    %{chain: chain, provider_id: pid, transport: transport, new_state: new_state} = event_data

    profile_chains = Map.get(socket.assigns, :profile_chains, [])

    if chain in profile_chains do
      ev =
        Helpers.as_event(:circuit_breaker,
          chain: chain,
          provider_id: pid,
          transport: transport,
          severity:
            case new_state do
              :closed -> :info
              :half_open -> :warn
              :open -> :error
            end,
          message: "#{transport} circuit #{new_state}",
          meta: %{
            transport: transport,
            new_state: new_state,
            old_state: Map.get(event_data, :old_state),
            reason: Map.get(event_data, :reason),
            error_code: get_in(event_data, [:error, :code]),
            error_category: get_in(event_data, [:error, :category]),
            error_message: get_in(event_data, [:error, :message])
          }
        )

      socket = buffer_event_fn.(socket, ev)

      socket =
        if socket.assigns[:selected_provider] == pid do
          update_provider_fn.(socket)
        else
          socket
        end

      socket =
        if socket.assigns[:selected_chain] == chain do
          update_chain_fn.(socket)
        else
          socket
        end

      socket
    else
      socket
    end
  end

  @doc """
  Handles new block events from chain monitors.
  Updates latest_blocks map and creates unified event.
  """
  def handle_block_event(blk, socket, buffer_event_fn, update_chain_fn, update_provider_fn)
      when is_map(blk) do
    %{chain: chain, block_number: bn} = blk
    profile_chains = Map.get(socket.assigns, :profile_chains, [])

    if chain in profile_chains do
      socket =
        update(socket, :latest_blocks, fn blocks ->
          Map.put(blocks, chain, bn)
        end)

      ev =
        Helpers.as_event(:chain,
          chain: chain,
          severity: :info,
          message: "block #{bn}",
          meta: blk
        )

      socket = buffer_event_fn.(socket, ev)

      socket =
        if socket.assigns[:selected_chain] == chain do
          update_chain_fn.(socket)
        else
          socket
        end

      case Map.get(blk, :provider_id) do
        nil ->
          socket

        pid ->
          if socket.assigns[:selected_provider] == pid do
            update_provider_fn.(socket)
          else
            socket
          end
      end
    else
      socket
    end
  end

  @doc """
  Handles batched events from EventBuffer.
  Prepends new events to the events list.
  """
  def handle_events_batch(events, socket) do
    update(socket, :events, fn list ->
      events ++ list
    end)
  end
end
