defmodule LassoWeb.RPCSocket do
  @moduledoc """
  Raw JSON-RPC WebSocket handler for standard Ethereum json rpc clients.

  Implements Phoenix.Socket.Transport behavior to handle raw WebSocket frames
  instead of Phoenix Channel protocol.

  **Protocol:**
  - Client sends: `{"jsonrpc":"2.0","method":"eth_subscribe","params":["newHeads"],"id":1}`
  - Server responds: `{"jsonrpc":"2.0","id":1,"result":"0xabc123..."}`
  - Server pushes: `{"jsonrpc":"2.0","method":"eth_subscription","params":{...}}`

  **Supported Methods:**
  - `eth_subscribe` - Create subscription (newHeads, logs)
  - `eth_unsubscribe` - Cancel subscription
  - All read-only methods (`eth_blockNumber`, `eth_getLogs`, etc.)
  """

  @behaviour Phoenix.Socket.Transport
  require Logger

  alias Lasso.Config.{ConfigStore, ProfileValidator}
  alias Lasso.Core.Request.ByteBudget
  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.RPC.{Observability, RequestContext, Response}
  alias LassoWeb.RPC.Helpers
  alias LassoWeb.RPCSocket.ItemOwner

  # Heartbeat configuration (aggressive keepalive for subscription connections)
  # Send ping every 30 seconds
  @heartbeat_interval 30_000
  # Expect pong within 5 seconds (more aggressive than 10)
  @heartbeat_timeout 5_000
  # Allow 2 missed heartbeats before closing (stricter than 3)
  @max_missed_heartbeats 2
  @max_forwarded_items 32
  @max_subscriptions 128
  @default_forwarded_byte_limit 32 * 1_024 * 1_024
  @forward_timeout_ms 10_000
  @max_item_owner_count 9_223_372_036_854_775_807
  @item_owner_counts %{
    byte_capacity_rejected: 0,
    capacity_rejected: 0,
    orphaned_subscription: 0,
    subscription_capacity_rejected: 0,
    owner_down: 0,
    spawn_failed: 0,
    stale_down: 0,
    stale_subscription_event: 0,
    stale_result: 0
  }

  ## Phoenix.Socket.Transport callbacks

  @impl true
  def child_spec(_opts) do
    # Return :ignore since we don't need a persistent process
    :ignore
  end

  @impl true
  def connect(transport_info) do
    client_ip = extract_client_ip(transport_info)
    connection_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    params = transport_info[:params] || %{}
    connect_info = transport_info[:connect_info] || %{}
    uri = connect_info[:uri]
    chain_identifier = params["chain_id"] || "ethereum"

    {strategy, provider_id} = extract_routing_params(uri, params)

    with {:ok, profile_slug} <- validate_profile(params["profile"], connection_id),
         {:ok, profile_meta} <- ConfigStore.get_profile(profile_slug),
         {:ok, chain_id} <- resolve_chain_id(profile_meta.profile_id, chain_identifier),
         :ok <-
           validate_provider_override(
             profile_meta.profile_id,
             chain_id,
             provider_id,
             connection_id
           ) do
      socket_state = %{
        profile: profile_meta.profile_id,
        profile_slug: profile_slug,
        chain_id: chain_id,
        strategy: strategy || default_provider_strategy(),
        requested_strategy: strategy || default_provider_strategy(),
        provider_id: provider_id,
        subscriptions: %{},
        orphaned_subscription_count: 0,
        pending_subscription_adds: 0,
        forwarded_items: %{},
        forwarded_monitors: %{},
        forwarded_bytes: 0,
        forwarded_byte_limit:
          Application.get_env(
            :lasso,
            :ws_connection_inflight_byte_limit,
            @default_forwarded_byte_limit
          ),
        forwarded_item_counts: @item_owner_counts,
        item_owner_module: ItemOwner,
        client_pid: self(),
        heartbeat_ref: nil,
        missed_heartbeats: 0,
        last_ping_time: nil,
        connection_id: connection_id,
        client_ip: client_ip
      }

      routing_info = build_routing_info(strategy, provider_id)

      Logger.info(
        "JSON-RPC WebSocket client connected: #{profile_slug}:#{chain_id}#{routing_info} (id: #{connection_id}, ip: #{client_ip})"
      )

      {:ok, socket_state}
    else
      reason ->
        Logger.warning("WebSocket connection rejected: #{inspect(reason)}",
          connection_id: connection_id,
          client_ip: client_ip
        )

        :error
    end
  end

  defp validate_profile(profile_param, connection_id) do
    case ProfileValidator.validate_with_default(profile_param) do
      {:ok, validated} ->
        {:ok, validated}

      {:error, error_type, message} ->
        Logger.warning("WebSocket connection rejected: #{message}",
          error_type: error_type,
          provided_profile: profile_param,
          connection_id: connection_id
        )

        :error
    end
  end

  defp validate_provider_override(_profile, _chain, nil, _connection_id), do: :ok

  defp validate_provider_override(profile, chain_id, provider_id, connection_id) do
    case ConfigStore.get_provider(profile, chain_id, provider_id) do
      {:ok, _provider} ->
        :ok

      {:error, _} ->
        Logger.warning("WebSocket connection rejected: provider not found",
          provided_provider: provider_id,
          chain_id: chain_id,
          profile: profile,
          connection_id: connection_id
        )

        :error
    end
  end

  @impl true
  def init(state) do
    # Start heartbeat timer
    heartbeat_ref = Process.send_after(self(), :send_heartbeat, @heartbeat_interval)

    {:ok, %{state | heartbeat_ref: heartbeat_ref}}
  end

  @impl true
  def handle_in({text, [opcode: :text]}, state) do
    started_at_us = System.monotonic_time(:microsecond)

    case ByteBudget.reserve(byte_size(text), self()) do
      {:ok, reservation} ->
        handle_budgeted_text(text, state, started_at_us, reservation)

      {:error, _reason} ->
        state = count_item_owner(state, :byte_capacity_rejected)
        capacity_response(nil, true, state)
    end
  end

  @impl true
  def handle_in(_, state) do
    # Ignore other non-text frames (binary, etc)
    {:ok, state}
  end

  @impl true
  def handle_control({_payload, [opcode: :pong]}, state) do
    # Handle pong response from client - reset heartbeat counter and cancel timeout
    Logger.debug("[Client←] Received pong from downstream client")

    # Cancel the pending heartbeat timeout since we received the pong
    if state.heartbeat_ref, do: Process.cancel_timer(state.heartbeat_ref)

    # Schedule the next heartbeat
    heartbeat_ref = Process.send_after(self(), :send_heartbeat, @heartbeat_interval)

    {:ok, %{state | missed_heartbeats: 0, last_ping_time: nil, heartbeat_ref: heartbeat_ref}}
  end

  @impl true
  def handle_control({_payload, [opcode: :ping]}, state) do
    # Client sent us a ping - respond with pong (standard keepalive behavior)
    Logger.debug("[Client←] Received ping from client, responding with pong")
    {:reply, :ok, {:pong, ""}, state}
  end

  @impl true
  def handle_info(
        {:subscription_event, %{"params" => %{"subscription" => subscription_id}} = payload},
        state
      ) do
    if Map.has_key?(state.subscriptions, subscription_id) do
      push_subscription_event(payload, state)
    else
      {:ok, count_item_owner(state, :stale_subscription_event)}
    end
  end

  def handle_info({:subscription_event, _payload}, state) do
    {:ok, count_item_owner(state, :stale_subscription_event)}
  end

  @impl true
  def handle_info({:send_notification, notification_json}, state) do
    # Send metadata notification as separate WebSocket frame
    {:push, {:text, notification_json}, state}
  end

  @impl true
  def handle_info({:rpc_item_result, item_ref, owner_pid, result}, state)
      when is_reference(item_ref) and is_pid(owner_pid) do
    case Map.get(state.forwarded_items, item_ref) do
      %{pid: ^owner_pid} = item ->
        Process.demonitor(item.monitor, [:flush])
        state = remove_forwarded_item(state, item_ref, item)
        handle_forwarded_result(result, item, state)

      _missing_or_stale ->
        {:ok, count_item_owner(state, :stale_result)}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, owner_pid, _reason}, state)
      when is_reference(monitor) and is_pid(owner_pid) do
    case Map.get(state.forwarded_monitors, monitor) do
      nil ->
        {:ok, count_item_owner(state, :stale_down)}

      item_ref ->
        case Map.get(state.forwarded_items, item_ref) do
          %{pid: ^owner_pid, monitor: ^monitor} = item ->
            state =
              state
              |> maybe_record_orphaned_subscription(item)
              |> remove_forwarded_item(item_ref, item)
              |> count_item_owner(:owner_down)

            owner_down_response(item, state)

          _missing_or_stale ->
            state = count_item_owner(state, :stale_down)
            {:ok, %{state | forwarded_monitors: Map.delete(state.forwarded_monitors, monitor)}}
        end
    end
  end

  @impl true
  def handle_info(:send_heartbeat, state) do
    # Send ping frame and set timeout for pong response
    Logger.debug("[Client→] Sending heartbeat ping to downstream client")

    # Cancel existing timeout if any
    if state.heartbeat_ref, do: Process.cancel_timer(state.heartbeat_ref)

    # Send ping frame (empty payload)
    ping_frame = {:ping, ""}

    # Set timeout for pong response
    timeout_ref = Process.send_after(self(), :heartbeat_timeout, @heartbeat_timeout)

    {:push, ping_frame,
     %{state | heartbeat_ref: timeout_ref, last_ping_time: System.monotonic_time(:millisecond)}}
  end

  @impl true
  def handle_info(:heartbeat_timeout, state) do
    # Pong not received within timeout - increment missed counter
    missed = state.missed_heartbeats + 1

    Logger.warning(
      "Client heartbeat timeout - missed #{missed}/#{@max_missed_heartbeats} heartbeats"
    )

    if missed >= @max_missed_heartbeats do
      Logger.error("Too many missed client heartbeats (#{missed}), closing connection")
      # Close with proper WebSocket code: 1002 = Protocol Error (failed to respond to pings)
      {:stop, {:shutdown, {1002, "Heartbeat timeout - no pong responses"}}, state}
    else
      # Schedule next heartbeat
      heartbeat_ref = Process.send_after(self(), :send_heartbeat, @heartbeat_interval)
      {:ok, %{state | missed_heartbeats: missed, heartbeat_ref: heartbeat_ref}}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:ok, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.debug("WebSocket terminated: #{inspect(reason)}")

    # Cancel heartbeat timer
    if state.heartbeat_ref, do: Process.cancel_timer(state.heartbeat_ref)

    Enum.each(state.forwarded_items, fn {_item_ref, item} ->
      release_item_reservation(item)
    end)

    :ok
  end

  ## JSON-RPC handling

  defp handle_budgeted_text(text, state, started_at_us, reservation) do
    case Jason.decode(text) do
      {:ok, %{"jsonrpc" => "2.0"} = request} ->
        handle_json_rpc(request, state, started_at_us, reservation)

      {:ok, invalid} ->
        ByteBudget.release(reservation)
        error = JError.new(-32_600, "Invalid Request: missing jsonrpc field")
        response = JError.to_response(error, request_id(invalid))
        {:reply, :ok, {:text, Jason.encode!(response)}, state}

      {:error, _reason} ->
        ByteBudget.release(reservation)
        error = JError.new(-32_700, "Parse error")
        response = JError.to_response(error, nil)
        {:reply, :ok, {:text, Jason.encode!(response)}, state}
    end
  end

  defp handle_json_rpc(%{"method" => method} = request, state, started_at_us, reservation)
       when is_binary(method) do
    # Extract lasso_meta preference (notify or nil - inline mode removed)
    {lasso_meta_mode, _clean_request} = extract_lasso_meta(request)

    # Normalize params to list (JSON-RPC params can be null)
    params = Map.get(request, "params", []) || []
    id = Map.get(request, "id")
    respond? = Map.has_key?(request, "id")

    if local_request?(method, params) do
      ByteBudget.release(reservation)

      ctx =
        RequestContext.new(state.chain_id, method, params,
          transport: :ws,
          strategy: state.strategy,
          plug_start_time: started_at_us
        )

      method
      |> handle_rpc_method(params, state, ctx)
      |> handle_local_result(id, respond?, lasso_meta_mode)
    else
      start_forwarded_item(
        state,
        method,
        params,
        id,
        respond?,
        lasso_meta_mode,
        started_at_us,
        reservation
      )
    end
  end

  defp handle_json_rpc(invalid, state, _started_at_us, reservation) do
    ByteBudget.release(reservation)
    error = JError.new(-32_600, "Invalid Request: missing required fields")
    response = JError.to_response(error, request_id(invalid))
    {:reply, :ok, {:text, Jason.encode!(response)}, state}
  end

  ## RPC method handlers

  defp handle_rpc_method("eth_chainId", [], state, ctx) do
    case get_chain_id(state.profile, state.chain_id) do
      {:ok, chain_id} ->
        updated_ctx = RequestContext.record_success(ctx, chain_id)
        {:ok, chain_id, state, updated_ctx}

      {:error, reason} ->
        updated_ctx = RequestContext.record_error(ctx, reason)
        {:error, reason, state, updated_ctx}
    end
  end

  ## Helper functions

  defp push_subscription_event(payload, state) do
    case Jason.encode(payload) do
      {:ok, json} ->
        {:push, {:text, json}, state}

      {:error, reason} ->
        Logger.error("Failed to encode subscription event: #{inspect(reason)}")
        {:ok, state}
    end
  end

  defp start_forwarded_item(
         state,
         method,
         params,
         id,
         respond?,
         lasso_meta_mode,
         started_at_us,
         reservation
       ) do
    cond do
      map_size(state.forwarded_items) >= @max_forwarded_items ->
        ByteBudget.release(reservation)
        state = count_item_owner(state, :capacity_rejected)
        capacity_response(id, respond?, state)

      state.forwarded_bytes + reservation.bytes > state.forwarded_byte_limit ->
        ByteBudget.release(reservation)
        state = count_item_owner(state, :byte_capacity_rejected)
        capacity_response(id, respond?, state)

      method == "eth_subscribe" and
          map_size(state.subscriptions) + state.pending_subscription_adds +
            state.orphaned_subscription_count >= @max_subscriptions ->
        ByteBudget.release(reservation)
        state = count_item_owner(state, :subscription_capacity_rejected)
        subscription_capacity_response(id, respond?, state)

      true ->
        start_forwarded_owner(
          state,
          method,
          params,
          id,
          respond?,
          lasso_meta_mode,
          started_at_us,
          reservation
        )
    end
  end

  defp start_forwarded_owner(
         state,
         method,
         params,
         id,
         respond?,
         lasso_meta_mode,
         started_at_us,
         reservation
       ) do
    item_ref = make_ref()
    deadline_us = started_at_us + @forward_timeout_ms * 1_000
    subscription_add? = method == "eth_subscribe"

    work = %ItemOwner.Work{
      chain_id: state.chain_id,
      method: method,
      params: params,
      profile: state.profile,
      strategy: state.strategy || default_provider_strategy(),
      provider_id: state.provider_id,
      jsonrpc_id: id,
      jsonrpc_id_present?: respond?,
      subscription_known?: subscription_known?(state, method, params),
      started_at_us: started_at_us,
      deadline_us: deadline_us,
      timeout_ms: @forward_timeout_ms
    }

    case state.item_owner_module.start(self(), item_ref, work) do
      {:ok, owner_pid} ->
        monitor = Process.monitor(owner_pid)

        item = %{
          pid: owner_pid,
          monitor: monitor,
          id: id,
          respond?: respond?,
          subscription_add?: subscription_add?,
          lasso_meta_mode: lasso_meta_mode,
          byte_reservation: reservation
        }

        state = %{
          state
          | forwarded_items: Map.put(state.forwarded_items, item_ref, item),
            forwarded_monitors: Map.put(state.forwarded_monitors, monitor, item_ref),
            forwarded_bytes: state.forwarded_bytes + reservation.bytes,
            pending_subscription_adds: increment_pending_subscriptions(state, subscription_add?)
        }

        {:ok, state}

      {:error, _reason} ->
        ByteBudget.release(reservation)
        state = count_item_owner(state, :spawn_failed)
        capacity_response(id, respond?, state)
    end
  end

  defp handle_local_result(
         {:ok, result, new_state, updated_ctx},
         id,
         respond?,
         lasso_meta_mode
       ) do
    if respond? do
      frame = success_frame(result, id)
      maybe_enqueue_metadata(lasso_meta_mode, updated_ctx)
      {:reply, :ok, frame, new_state}
    else
      {:ok, new_state}
    end
  end

  defp handle_local_result(
         {:error, reason, new_state, _updated_ctx},
         id,
         respond?,
         _lasso_meta_mode
       ) do
    if respond? do
      {:reply, :ok, error_frame(reason, id), new_state}
    else
      {:ok, new_state}
    end
  end

  defp handle_forwarded_result({:ok, result, updated_ctx}, item, state) do
    {result, state} = apply_subscription_result(result, state)

    if item.respond? do
      frame = success_frame(result, item.id)
      maybe_enqueue_metadata(item.lasso_meta_mode, updated_ctx)
      {:push, frame, state}
    else
      {:ok, state}
    end
  end

  defp handle_forwarded_result({:error, reason, _updated_ctx}, item, state) do
    if item.respond?,
      do: {:push, error_frame(reason, item.id), state},
      else: {:ok, state}
  end

  defp handle_forwarded_result(_invalid_result, item, state) do
    state = maybe_record_orphaned_subscription(state, item)
    owner_down_response(item, state)
  end

  defp success_frame(%Response.Success{raw_bytes: bytes}, _id), do: {:text, bytes}

  defp success_frame(result, id) do
    {:text, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})}
  end

  defp error_frame(reason, id) do
    response = reason |> JError.from() |> JError.to_response(id)
    {:text, Jason.encode!(response)}
  end

  defp capacity_response(_id, false, state), do: {:ok, state}

  defp capacity_response(id, true, state) do
    error =
      JError.new(-32_008, "Local request capacity unavailable",
        category: :local_capacity_rejection,
        retriable?: true,
        breaker_penalty?: false
      )

    {:reply, :ok, {:text, Jason.encode!(JError.to_response(error, id))}, state}
  end

  defp subscription_capacity_response(_id, false, state), do: {:ok, state}

  defp subscription_capacity_response(id, true, state) do
    error =
      JError.new(-32_008, "Subscription capacity unavailable",
        category: :local_capacity_rejection,
        retriable?: false,
        breaker_penalty?: false
      )

    {:reply, :ok, {:text, Jason.encode!(JError.to_response(error, id))}, state}
  end

  defp owner_down_response(%{respond?: false}, state), do: {:ok, state}

  defp owner_down_response(item, state) do
    error =
      JError.new(-32_000, "Request outcome unavailable after owner exit",
        category: :server_error,
        retriable?: false,
        breaker_penalty?: false
      )

    {:push, {:text, Jason.encode!(JError.to_response(error, item.id))}, state}
  end

  defp remove_forwarded_item(state, item_ref, item) do
    release_item_reservation(item)

    %{
      state
      | forwarded_items: Map.delete(state.forwarded_items, item_ref),
        forwarded_monitors: Map.delete(state.forwarded_monitors, item.monitor),
        forwarded_bytes: max(state.forwarded_bytes - reservation_bytes(item), 0),
        pending_subscription_adds:
          decrement_pending_subscriptions(state, Map.get(item, :subscription_add?, false))
    }
  end

  defp release_item_reservation(%{byte_reservation: reservation}) do
    ByteBudget.release(reservation)
  end

  defp release_item_reservation(_item), do: :ok

  defp reservation_bytes(%{byte_reservation: %{bytes: bytes}}), do: bytes
  defp reservation_bytes(_item), do: 0

  defp count_item_owner(state, event) do
    counts =
      Map.update!(state.forwarded_item_counts, event, fn count ->
        min(count + 1, @max_item_owner_count)
      end)

    %{state | forwarded_item_counts: counts}
  end

  defp maybe_enqueue_metadata(:notify, updated_ctx) do
    notification = build_metadata_notification(updated_ctx)
    {:ok, notification_json} = Jason.encode(notification)
    send(self(), {:send_notification, notification_json})
    :ok
  end

  defp maybe_enqueue_metadata(_mode, _updated_ctx), do: :ok

  defp local_request?("eth_chainId", []), do: true
  defp local_request?(_method, _params), do: false

  defp request_id(value) when is_map(value), do: Map.get(value, "id")
  defp request_id(_value), do: nil

  defp subscription_known?(state, "eth_unsubscribe", [subscription_id]),
    do: Map.has_key?(state.subscriptions, subscription_id)

  defp subscription_known?(_state, _method, _params), do: false

  defp increment_pending_subscriptions(state, true), do: state.pending_subscription_adds + 1
  defp increment_pending_subscriptions(state, false), do: state.pending_subscription_adds

  defp decrement_pending_subscriptions(state, true),
    do: max(state.pending_subscription_adds - 1, 0)

  defp decrement_pending_subscriptions(state, false), do: state.pending_subscription_adds

  defp maybe_record_orphaned_subscription(state, %{subscription_add?: true}) do
    count = min(state.orphaned_subscription_count + 1, @max_subscriptions)

    state
    |> Map.put(:orphaned_subscription_count, count)
    |> count_item_owner(:orphaned_subscription)
  end

  defp maybe_record_orphaned_subscription(state, _item), do: state

  defp apply_subscription_result({:subscription_added, subscription_id}, state) do
    {subscription_id,
     %{state | subscriptions: Map.put(state.subscriptions, subscription_id, true)}}
  end

  defp apply_subscription_result({:subscription_removed, subscription_id, removed?}, state) do
    {removed?, %{state | subscriptions: Map.delete(state.subscriptions, subscription_id)}}
  end

  defp apply_subscription_result({:subscription_missing, false}, state), do: {false, state}
  defp apply_subscription_result(result, state), do: {result, state}

  defp get_chain_id(profile, chain_name) do
    Helpers.get_chain_id(profile, chain_name)
  end

  defp resolve_chain_id(profile, identifier) when is_binary(identifier) do
    case ConfigStore.lookup_chain_id_in_profile(profile, identifier) do
      {:ok, chain_id} -> {:ok, chain_id}
      :not_found -> {:error, "Unknown chain '#{identifier}'"}
    end
  end

  defp default_provider_strategy do
    Helpers.default_provider_strategy()
  end

  ## Observability helpers

  defp extract_lasso_meta(%{"lasso_meta" => meta_value} = request) when is_binary(meta_value) do
    # Parse the lasso_meta field and strip it from request
    # Note: :inline mode removed - only :notify supported for metadata delivery
    mode =
      case String.downcase(meta_value) do
        "notify" -> :notify
        # "inline" was removed - passthrough optimization is incompatible with inline metadata
        _ -> nil
      end

    clean_request = Map.delete(request, "lasso_meta")
    {mode, clean_request}
  end

  defp extract_lasso_meta(request) do
    # No lasso_meta field present
    {nil, request}
  end

  defp build_metadata_notification(ctx) do
    metadata = Observability.build_client_metadata(ctx)

    %{
      "jsonrpc" => "2.0",
      "method" => "lasso_meta",
      "params" => metadata
    }
  end

  ## Routing parameter extraction

  # Map URL strategy strings to atoms (avoids String.to_atom)
  @strategy_map %{
    "fastest" => :fastest,
    "load-balanced" => :load_balanced,
    "round-robin" => :load_balanced,
    "latency-weighted" => :latency_weighted,
    "priority" => :priority
  }

  defp extract_routing_params(nil, _params), do: {nil, nil}

  defp extract_routing_params(uri, _params) when is_binary(uri) do
    # Parse the URI path: /ws/rpc/[strategy|provider|chain_id]/[chain_id|provider_id]
    path_segments =
      uri
      |> String.split("?")
      |> List.first()
      |> String.split("/", trim: true)

    case path_segments do
      # Pattern: ["ws", "rpc", "provider", provider_id, _chain_id]
      ["ws", "rpc", "provider", provider_id | _] ->
        {nil, provider_id}

      # Pattern: ["ws", "rpc", segment, _chain_id_or_provider]
      # Could be strategy or chain_id - check if it's a known strategy
      ["ws", "rpc", segment, next_segment] ->
        case Map.get(@strategy_map, segment) do
          nil ->
            # Not a strategy, treat as ["ws", "rpc", chain_id, provider_id]
            {nil, next_segment}

          strategy_atom ->
            # Valid strategy
            {strategy_atom, nil}
        end

      # Pattern: ["ws", "rpc", _chain_id] - base endpoint
      ["ws", "rpc" | _] ->
        {nil, nil}

      _ ->
        {nil, nil}
    end
  end

  defp extract_routing_params(%URI{} = uri, params) do
    strategy = Helpers.normalize_strategy_token(params["strategy"])
    provider_id = params["provider_id"]

    case {strategy, provider_id} do
      {nil, nil} -> extract_routing_params(uri.path, params)
      routing -> routing
    end
  end

  defp build_routing_info(nil, nil), do: ""
  defp build_routing_info(strategy, nil) when is_atom(strategy), do: " [strategy: #{strategy}]"

  defp build_routing_info(nil, provider_id) when is_binary(provider_id),
    do: " [provider: #{provider_id}]"

  defp build_routing_info(strategy, provider_id)
       when is_atom(strategy) and is_binary(provider_id),
       do: " [strategy: #{strategy}, provider: #{provider_id}]"

  ## Connection tracking helpers

  defp extract_client_ip(transport_info) do
    # Extract client IP from various possible locations in transport_info
    # Phoenix WebSocket transport provides peer information

    cond do
      # Check for x-forwarded-for header (when behind proxy/load balancer)
      # x_headers is a list of tuples like [{"x-forwarded-for", "value"}]
      x_headers = get_in(transport_info, [:connect_info, :x_headers]) ->
        extract_ip_from_headers(x_headers, transport_info)

      # Check for peer data
      peer = get_in(transport_info, [:connect_info, :peer]) ->
        format_ip(peer)

      # Fallback to unknown
      true ->
        "unknown"
    end
  end

  defp extract_ip_from_headers(x_headers, transport_info) do
    case List.keyfind(x_headers, "x-forwarded-for", 0) do
      {"x-forwarded-for", value} ->
        parse_forwarded_for(value)

      nil ->
        extract_ip_from_peer(transport_info)
    end
  end

  defp parse_forwarded_for(value) do
    # Take the first IP if multiple are present
    value
    |> String.split(",")
    |> List.first()
    |> String.trim()
  end

  defp extract_ip_from_peer(transport_info) do
    case get_in(transport_info, [:connect_info, :peer]) do
      nil -> "unknown"
      peer -> format_ip(peer)
    end
  end

  defp format_ip({ip_tuple, _port}) when is_tuple(ip_tuple) do
    # Convert IP tuple to string
    ip_tuple
    |> :inet.ntoa()
    |> to_string()
  end

  defp format_ip(ip) when is_binary(ip) do
    ip
  end

  defp format_ip(_), do: "unknown"
end
