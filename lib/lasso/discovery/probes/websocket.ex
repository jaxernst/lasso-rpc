defmodule Lasso.Discovery.Probes.WebSocket do
  @moduledoc """
  Probes RPC provider WebSocket capabilities.

  Tests:
  - WebSocket connection establishment
  - Unary RPC requests over WebSocket
  - Subscription support (newHeads, logs, newPendingTransactions)

  Subscriptions are tested concurrently over a single shared wait window.
  An accepted subscription without a valid event remains unverified; a quiet
  observation window cannot establish absence of support. By default, wait time
  uses the operator's configured subscription wait period.
  """

  require Logger

  alias __MODULE__.Client
  alias Lasso.Discovery.MethodEvidence
  alias Lasso.JSONRPC.Quantity

  @subscription_types ["newHeads", "logs", "newPendingTransactions"]

  @type ws_result :: %{
          connected: boolean(),
          error: term() | nil,
          connection: map() | nil,
          unary_requests: map() | nil,
          subscriptions: map() | nil
        }

  @doc """
  Probes WebSocket capabilities of a provider.

  ## Options

    * `:timeout` - Connection and request timeout in ms (default: 10000)
    * `:chain_id` - Expected chain ID, when known; mismatches abort probing
    * `:subscription_wait` - Event observation window (default: 15000 ms)

  ## Returns

  Map with connection status, unary request results, and subscription support.
  """
  @spec probe(String.t(), keyword()) :: ws_result()
  def probe(ws_url, opts \\ []) do
    ws_url = ensure_ws_url(ws_url)
    probe_dedicated(ws_url, opts)
  end

  defp probe_dedicated(ws_url, opts) do
    timeout = Keyword.get(opts, :timeout, 10_000)
    expected_chain_id = Keyword.get(opts, :chain_id)
    capabilities = Keyword.get(opts, :provider_capabilities, %{})

    ws_url = ensure_ws_url(ws_url)

    case connect(ws_url, timeout) do
      {:ok, conn} ->
        ref = Process.monitor(conn)

        try do
          case verify_chain(conn, expected_chain_id, timeout) do
            {:ok, chain_id} ->
              connection_result = test_connection_latency(conn, timeout)
              unary_results = test_unary_requests(conn, timeout, capabilities)

              subscription_results =
                test_subscriptions_concurrent(conn, timeout, ref, capabilities, opts)

              %{
                connected: true,
                error: nil,
                chain_id: chain_id,
                connection: connection_result,
                unary_requests: unary_results,
                subscriptions: subscription_results
              }

            {:error, reason} ->
              %{
                connected: false,
                error: format_error(reason),
                connection: nil,
                unary_requests: nil,
                subscriptions: nil
              }
          end
        after
          Process.demonitor(ref, [:flush])
          if Process.alive?(conn), do: disconnect(conn)
        end

      {:error, reason} ->
        %{
          connected: false,
          error: format_error(reason),
          connection: nil,
          unary_requests: nil,
          subscriptions: nil
        }
    end
  end

  @doc """
  Converts HTTP URL to WebSocket URL if needed.
  """
  @spec ensure_ws_url(String.t()) :: String.t()
  def ensure_ws_url("https://" <> rest), do: "wss://" <> rest
  def ensure_ws_url("http://" <> rest), do: "ws://" <> rest
  def ensure_ws_url(url), do: url

  defp connect(ws_url, timeout) do
    # Start our probe client
    Client.start_link(ws_url, timeout)
  end

  defp disconnect(conn) do
    Client.stop(conn)
  end

  defp verify_chain(conn, expected, timeout) do
    with {:ok, value} <- Client.request(conn, "eth_chainId", [], timeout),
         {:ok, actual} <- Quantity.decode(value),
         true <- actual > 0 and (is_nil(expected) or actual == expected) do
      {:ok, actual}
    else
      false -> {:error, :chain_mismatch}
      _ -> {:error, :chain_identity_unverified}
    end
  end

  defp test_connection_latency(conn, timeout) do
    start = System.monotonic_time(:millisecond)

    case Client.request(conn, "eth_blockNumber", [], timeout) do
      {:ok, result} ->
        latency = System.monotonic_time(:millisecond) - start

        status =
          if MethodEvidence.classify("eth_blockNumber", result) == :supported,
            do: :ok,
            else: :unknown

        %{status: status, latency_ms: latency}

      {:error, reason} ->
        %{status: :error, error: format_error(reason)}
    end
  end

  defp test_unary_requests(conn, timeout, capabilities) do
    methods = ["eth_blockNumber", "eth_chainId", "eth_gasPrice"]

    results =
      Enum.map(methods, fn method ->
        start = System.monotonic_time(:millisecond)

        result =
          case Client.request(conn, method, [], timeout) do
            {:ok, result} ->
              %{
                status: MethodEvidence.classify(method, result),
                latency_ms: System.monotonic_time(:millisecond) - start
              }

            {:error, reason} ->
              classify_probe_error(reason, capabilities, false)
          end

        {method, result}
      end)

    Map.new(results)
  end

  defp test_subscriptions_concurrent(conn, timeout, monitor_ref, capabilities, opts) do
    wait_ms = observation_window_ms(opts)

    # Phase 1: Create all subscriptions (sequential, each ~200ms)
    sub_results =
      Enum.map(@subscription_types, fn sub_type ->
        params =
          case sub_type do
            "logs" -> ["logs", %{}]
            other -> [other]
          end

        {sub_type, Client.create_subscription(conn, params, timeout)}
      end)

    {active_subs, failed_subs} =
      Enum.split_with(sub_results, fn
        {_, {:ok, _}} -> true
        _ -> false
      end)

    # Build reverse map: sub_id → subscription type name
    sub_id_to_type = Map.new(active_subs, fn {type, {:ok, sub_id}} -> {sub_id, type} end)

    # Phase 2: Collect events in a single shared window; exits early on :DOWN
    {events_received, client_down} = collect_events(sub_id_to_type, wait_ms, monitor_ref)

    # Phase 3: Unsubscribe — skip if the client process is already gone
    unless client_down do
      for {_type, {:ok, sub_id}} <- active_subs do
        if Process.alive?(conn), do: Client.unsubscribe(conn, sub_id, timeout)
      end
    end

    # Phase 4: Classify with correlation
    new_heads_verified = Map.has_key?(events_received, "newHeads")

    successful_results =
      Enum.map(active_subs, fn {sub_type, {:ok, sub_id}} ->
        received = Map.has_key?(events_received, sub_type)
        status = classify_subscription(sub_type, received, new_heads_verified)

        {sub_type, %{status: status, subscription_id: sub_id, received_event: received}}
      end)

    failed_results =
      Enum.map(failed_subs, fn {sub_type, {:error, reason}} ->
        {sub_type, classify_probe_error(reason, capabilities, true)}
      end)

    Map.new(successful_results ++ failed_results)
  end

  defp observation_window_ms(opts) do
    case Keyword.get(opts, :subscription_wait, 15_000) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> 15_000
    end
  end

  defp collect_events(sub_id_to_type, wait_ms, monitor_ref) do
    deadline = System.monotonic_time(:millisecond) + wait_ms
    do_collect_events(sub_id_to_type, deadline, %{}, monitor_ref)
  end

  defp do_collect_events(sub_id_to_type, deadline, received, monitor_ref) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 or map_size(received) == map_size(sub_id_to_type) do
      {received, false}
    else
      receive do
        {:DOWN, ^monitor_ref, :process, _, _} ->
          {received, true}

        {:subscription_event, sub_id, event} ->
          case Map.get(sub_id_to_type, sub_id) do
            nil ->
              do_collect_events(sub_id_to_type, deadline, received, monitor_ref)

            sub_type ->
              do_collect_events(
                sub_id_to_type,
                deadline,
                if(valid_event?(sub_type, event),
                  do: Map.put(received, sub_type, true),
                  else: received
                ),
                monitor_ref
              )
          end
      after
        remaining -> {received, false}
      end
    end
  end

  @doc false
  @spec valid_event?(String.t(), term()) :: boolean()
  def valid_event?("newHeads", event),
    do: MethodEvidence.classify("eth_getBlockByNumber", event) == :supported

  def valid_event?("logs", event), do: MethodEvidence.valid_log?(event)
  def valid_event?("newPendingTransactions", event), do: MethodEvidence.data?(event, 32)
  def valid_event?(_, _), do: false

  defp classify_subscription(_type, true, _), do: :supported
  defp classify_subscription(_type, false, _), do: :accepted

  defp classify_probe_error(%{"code" => code} = reason, capabilities, subscription?)
       when is_integer(code) do
    message = Map.get(reason, "message", "")
    {type, _} = Lasso.Discovery.ErrorClassifier.classify(reason, capabilities)

    policy =
      Lasso.Core.Support.ErrorClassifier.classify(code, message,
        provider_id: "discovery",
        provider_capabilities: capabilities,
        data: Map.get(reason, "data"),
        shared_instance?: false
      )

    unsupported_subscription? =
      subscription? and policy.category == :capability_violation and
        is_binary(message) and
        String.contains?(String.downcase(message), "unsupported subscription")

    status =
      if type == :method_not_found or unsupported_subscription?, do: :unsupported, else: :unknown

    %{status: status, error: format_error(reason), error_category: policy.category}
  end

  defp classify_probe_error(reason, _capabilities, _subscription?),
    do: %{status: :error, error: format_error(reason)}

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(%{"message" => msg}), do: msg
  defp format_error({:ws_upgrade_error, code, _headers}), do: "HTTP #{code}"
  defp format_error(%{__struct__: struct} = err), do: "#{struct}: #{Exception.message(err)}"
  defp format_error(reason), do: inspect(reason)
end

defmodule Lasso.Discovery.Probes.WebSocket.Client do
  @moduledoc false

  require Logger

  alias Lasso.RPC.Transport.WebSocket.Client, as: SocketClient

  defstruct [
    :url,
    :parent,
    :pending_requests,
    :pending_subscriptions,
    :active_subscriptions
  ]

  @type t :: %__MODULE__{
          url: String.t(),
          parent: pid(),
          pending_requests: map(),
          pending_subscriptions: map(),
          active_subscriptions: map()
        }

  @spec start_link(String.t(), non_neg_integer()) :: {:ok, pid()} | {:error, term()}
  def start_link(url, timeout) do
    state = %__MODULE__{
      url: Lasso.URLMask.redact(url),
      parent: self(),
      pending_requests: %{},
      pending_subscriptions: %{},
      active_subscriptions: %{}
    }

    SocketClient.start_link(url, __MODULE__, state,
      connection_id: "discovery-probe",
      connect_timeout: timeout
    )
  end

  @spec stop(pid()) :: :ok | nil
  def stop(pid) do
    if Process.alive?(pid) do
      SocketClient.cast(pid, :close)
    end
  catch
    :exit, _ -> :ok
  end

  @spec request(pid(), String.t(), list(), non_neg_integer()) :: {:ok, term()} | {:error, term()}
  def request(pid, method, params, timeout) do
    request_id = System.unique_integer([:positive, :monotonic])

    request = %{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => params,
      "id" => request_id
    }

    SocketClient.cast(pid, {:send_request, request, self()})

    receive do
      {:response, ^request_id, result} -> {:ok, result}
      {:error, ^request_id, error} -> {:error, error}
    after
      timeout ->
        SocketClient.cast(pid, {:cancel_request, request_id})
        {:error, :timeout}
    end
  end

  @doc """
  Creates a subscription and returns the subscription ID without blocking for events.
  Events arrive as `{:subscription_event, sub_id, event}` in the caller's mailbox.
  """
  @spec create_subscription(pid(), list(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, term()}
  def create_subscription(pid, params, timeout) do
    request_id = System.unique_integer([:positive, :monotonic])

    request = %{
      "jsonrpc" => "2.0",
      "method" => "eth_subscribe",
      "params" => params,
      "id" => request_id
    }

    SocketClient.cast(pid, {:send_subscription, request, self()})

    receive do
      {:subscription_created, ^request_id, sub_id} ->
        {:ok, sub_id}

      {:error, ^request_id, error} ->
        {:error, error}
    after
      timeout ->
        SocketClient.cast(pid, {:cancel_request, request_id})
        {:error, :subscription_timeout}
    end
  end

  @spec unsubscribe(pid(), String.t(), non_neg_integer()) :: :ok
  def unsubscribe(pid, sub_id, timeout) do
    request_id = System.unique_integer([:positive, :monotonic])

    request = %{
      "jsonrpc" => "2.0",
      "method" => "eth_unsubscribe",
      "params" => [sub_id],
      "id" => request_id
    }

    SocketClient.cast(pid, {:send_request, request, self()})

    receive do
      {:response, ^request_id, _} -> :ok
      {:error, ^request_id, _} -> :ok
    after
      timeout -> :ok
    end
  end

  @spec handle_connect(map(), t()) :: {:ok, t()}
  def handle_connect(_conn, state) do
    {:ok, state}
  end

  @spec handle_frame(term(), t()) :: {:ok, t()}
  def handle_frame({:text, msg}, state) do
    case Jason.decode(msg) do
      {:ok, %{"id" => id} = response} when is_integer(id) ->
        case Lasso.Discovery.Response.validate(response, id) do
          {:ok, %{"result" => result}} -> handle_response(id, result, state)
          {:ok, %{"error" => error}} -> handle_error_response(id, error, state)
          _ -> handle_error_response(id, :invalid_rpc_response, state)
        end

      {:ok,
       %{
         "jsonrpc" => "2.0",
         "method" => "eth_subscription",
         "params" => %{"subscription" => sub_id, "result" => event}
       }} ->
        handle_subscription_event(sub_id, event, state)

      _ ->
        {:ok, state}
    end
  end

  def handle_frame(_frame, state) do
    {:ok, state}
  end

  @spec handle_cast(term(), t()) ::
          {:ok, t()} | {:reply, Mint.WebSocket.frame() | Mint.WebSocket.shorthand_frame(), t()}
  def handle_cast({:send_request, request, from}, state) do
    id = request["id"]
    new_state = %{state | pending_requests: Map.put(state.pending_requests, id, from)}
    {:reply, {:text, Jason.encode!(request)}, new_state}
  end

  def handle_cast({:send_subscription, request, from}, state) do
    id = request["id"]

    new_state = %{
      state
      | pending_subscriptions:
          Map.put(state.pending_subscriptions, id, {from, List.first(request["params"])})
    }

    {:reply, {:text, Jason.encode!(request)}, new_state}
  end

  def handle_cast({:cancel_request, id}, state) do
    {:ok,
     %{
       state
       | pending_requests: Map.delete(state.pending_requests, id),
         pending_subscriptions: Map.delete(state.pending_subscriptions, id)
     }}
  end

  def handle_cast(:close, state) do
    {:close, state}
  end

  @spec handle_disconnect(term(), t()) :: {:ok, t()}
  def handle_disconnect(_reason, state) do
    {:ok, state}
  end

  defp handle_response(id, result, state) do
    case Map.pop(state.pending_requests, id) do
      {nil, _} ->
        case Map.pop(state.pending_subscriptions, id) do
          {{from, type}, remaining}
          when is_pid(from) and is_binary(result) and byte_size(result) > 0 ->
            send(from, {:subscription_created, id, result})

            {:ok,
             %{
               state
               | pending_subscriptions: remaining,
                 active_subscriptions: Map.put(state.active_subscriptions, result, {from, type})
             }}

          {{from, _type}, remaining} when is_pid(from) ->
            send(from, {:error, id, :invalid_subscription_id})
            {:ok, %{state | pending_subscriptions: remaining}}

          _ ->
            {:ok, state}
        end

      {from, new_pending} ->
        send(from, {:response, id, result})
        {:ok, %{state | pending_requests: new_pending}}
    end
  end

  defp handle_error_response(id, error, state) do
    case Map.pop(state.pending_requests, id) do
      {nil, _} ->
        case Map.pop(state.pending_subscriptions, id) do
          {{from, _type}, remaining} when is_pid(from) ->
            send(from, {:error, id, error})
            {:ok, %{state | pending_subscriptions: remaining}}

          _ ->
            {:ok, state}
        end

      {from, new_pending} ->
        send(from, {:error, id, error})
        {:ok, %{state | pending_requests: new_pending}}
    end
  end

  defp handle_subscription_event(sub_id, event, state) do
    case Map.get(state.active_subscriptions, sub_id) do
      {listener, type} ->
        if Lasso.Discovery.Probes.WebSocket.valid_event?(type, event) do
          send(listener, {:subscription_event, sub_id, event})
          {:ok, %{state | active_subscriptions: Map.delete(state.active_subscriptions, sub_id)}}
        else
          {:ok, state}
        end

      nil ->
        {:ok, state}
    end
  end
end
