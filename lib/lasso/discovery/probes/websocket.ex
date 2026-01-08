defmodule Lasso.Discovery.Probes.WebSocket do
  @moduledoc """
  Probes RPC provider WebSocket capabilities.

  Tests:
  - WebSocket connection establishment
  - Unary RPC requests over WebSocket
  - Subscription support (newHeads, logs, newPendingTransactions)
  """

  require Logger

  alias Client

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
    * `:subscription_wait` - Time to wait for subscription events in ms (default: 15000)

  ## Returns

  Map with connection status, unary request results, and subscription support.
  """
  @spec probe(String.t(), keyword()) :: ws_result()
  def probe(ws_url, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10_000)
    subscription_wait = Keyword.get(opts, :subscription_wait, 15_000)

    # Ensure URL is WebSocket
    ws_url = ensure_ws_url(ws_url)

    case connect(ws_url, timeout) do
      {:ok, conn} ->
        try do
          connection_result = test_connection_latency(conn, timeout)
          unary_results = test_unary_requests(conn, timeout)
          subscription_results = test_subscriptions(conn, timeout, subscription_wait)

          %{
            connected: true,
            error: nil,
            connection: connection_result,
            unary_requests: unary_results,
            subscriptions: subscription_results
          }
        after
          disconnect(conn)
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

  # Connection management using a simple GenServer wrapper around WebSockex
  defp connect(ws_url, timeout) do
    # Start our probe client
    case Client.start_link(ws_url, timeout) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp disconnect(conn) do
    Client.stop(conn)
  end

  defp test_connection_latency(conn, timeout) do
    start = System.monotonic_time(:millisecond)

    case Client.request(conn, "eth_blockNumber", [], timeout) do
      {:ok, _result} ->
        latency = System.monotonic_time(:millisecond) - start
        %{status: :ok, latency_ms: latency}

      {:error, reason} ->
        %{status: :error, error: format_error(reason)}
    end
  end

  defp test_unary_requests(conn, timeout) do
    methods = ["eth_blockNumber", "eth_chainId", "eth_gasPrice"]

    results =
      Enum.map(methods, fn method ->
        start = System.monotonic_time(:millisecond)

        result =
          case Client.request(conn, method, [], timeout) do
            {:ok, _} ->
              %{status: :supported, latency_ms: System.monotonic_time(:millisecond) - start}

            {:error, %{"code" => -32_601}} ->
              %{status: :unsupported, latency_ms: System.monotonic_time(:millisecond) - start}

            {:error, reason} ->
              %{status: :error, error: format_error(reason)}
          end

        {method, result}
      end)

    Map.new(results)
  end

  defp test_subscriptions(conn, timeout, subscription_wait) do
    results =
      Enum.map(@subscription_types, fn sub_type ->
        params =
          case sub_type do
            "logs" -> ["logs", %{}]
            other -> [other]
          end

        result =
          case Client.subscribe(
                 conn,
                 params,
                 timeout,
                 subscription_wait
               ) do
            {:ok, %{subscription_id: sub_id, received_event: true}} ->
              %{status: :supported, subscription_id: sub_id, received_event: true}

            {:ok, %{subscription_id: sub_id, received_event: false}} ->
              %{
                status: :supported,
                subscription_id: sub_id,
                received_event: false,
                note: "No event received within timeout"
              }

            {:error, %{"code" => -32_601}} ->
              %{status: :unsupported, error: "Method not found"}

            {:error, reason} ->
              %{status: :error, error: format_error(reason)}
          end

        {sub_type, result}
      end)

    Map.new(results)
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(%{"message" => msg}), do: msg
  defp format_error(%WebSockex.RequestError{code: code, message: msg}), do: "HTTP #{code}: #{msg}"
  defp format_error(%{__struct__: struct} = err), do: "#{struct}: #{Exception.message(err)}"
  defp format_error(reason), do: inspect(reason)
end

defmodule Client do
  @moduledoc false
  # Internal WebSocket client for probing

  use WebSockex
  require Logger

  defstruct [
    :url,
    :parent,
    :pending_requests,
    :pending_subscription,
    :subscription_id,
    :event_listener
  ]

  def start_link(url, timeout) do
    state = %__MODULE__{
      url: url,
      parent: self(),
      pending_requests: %{},
      pending_subscription: nil,
      subscription_id: nil,
      event_listener: nil
    }

    # Try to connect with timeout
    task =
      Task.async(fn ->
        WebSockex.start_link(url, __MODULE__, state, handle_initial_conn_failure: true)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> {:error, :connection_timeout}
    end
  end

  def stop(pid) do
    if Process.alive?(pid) do
      WebSockex.cast(pid, :close)
    end
  catch
    :exit, _ -> :ok
  end

  def request(pid, method, params, timeout) do
    request_id = :rand.uniform(1_000_000)

    request = %{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => params,
      "id" => request_id
    }

    WebSockex.cast(pid, {:send_request, request, self()})

    receive do
      {:response, ^request_id, result} -> {:ok, result}
      {:error, ^request_id, error} -> {:error, error}
    after
      timeout -> {:error, :timeout}
    end
  end

  def subscribe(pid, params, timeout, wait_for_event) do
    request_id = :rand.uniform(1_000_000)

    request = %{
      "jsonrpc" => "2.0",
      "method" => "eth_subscribe",
      "params" => params,
      "id" => request_id
    }

    WebSockex.cast(pid, {:send_subscription, request, self()})

    # Wait for subscription confirmation
    receive do
      {:subscription_created, ^request_id, sub_id} ->
        # Wait for an event
        receive do
          {:subscription_event, ^sub_id, _event} ->
            # Unsubscribe
            unsubscribe(pid, sub_id, timeout)
            {:ok, %{subscription_id: sub_id, received_event: true}}
        after
          wait_for_event ->
            unsubscribe(pid, sub_id, timeout)
            {:ok, %{subscription_id: sub_id, received_event: false}}
        end

      {:error, ^request_id, error} ->
        {:error, error}
    after
      timeout -> {:error, :subscription_timeout}
    end
  end

  defp unsubscribe(pid, sub_id, timeout) do
    request_id = :rand.uniform(1_000_000)

    request = %{
      "jsonrpc" => "2.0",
      "method" => "eth_unsubscribe",
      "params" => [sub_id],
      "id" => request_id
    }

    WebSockex.cast(pid, {:send_request, request, self()})

    receive do
      {:response, ^request_id, _} -> :ok
      {:error, ^request_id, _} -> :ok
    after
      timeout -> :ok
    end
  end

  # WebSockex callbacks

  @impl true
  def handle_connect(_conn, state) do
    {:ok, state}
  end

  @impl true
  def handle_frame({:text, msg}, state) do
    case Jason.decode(msg) do
      {:ok, %{"id" => id, "result" => result}} when is_integer(id) ->
        handle_response(id, result, state)

      {:ok, %{"id" => id, "error" => error}} when is_integer(id) ->
        handle_error_response(id, error, state)

      {:ok,
       %{
         "method" => "eth_subscription",
         "params" => %{"subscription" => sub_id, "result" => event}
       }} ->
        handle_subscription_event(sub_id, event, state)

      {:ok, _other} ->
        {:ok, state}

      {:error, _} ->
        {:ok, state}
    end
  end

  @impl true
  def handle_frame(_frame, state) do
    {:ok, state}
  end

  @impl true
  def handle_cast({:send_request, request, from}, state) do
    id = request["id"]
    new_state = %{state | pending_requests: Map.put(state.pending_requests, id, from)}
    {:reply, {:text, Jason.encode!(request)}, new_state}
  end

  @impl true
  def handle_cast({:send_subscription, request, from}, state) do
    id = request["id"]
    new_state = %{state | pending_subscription: {id, from}}
    {:reply, {:text, Jason.encode!(request)}, new_state}
  end

  @impl true
  def handle_cast(:close, state) do
    {:close, state}
  end

  @impl true
  def handle_disconnect(_reason, state) do
    {:ok, state}
  end

  defp handle_response(id, result, state) do
    case Map.pop(state.pending_requests, id) do
      {nil, _} ->
        # Check if this is a subscription response
        case state.pending_subscription do
          {^id, from} when is_binary(result) ->
            send(from, {:subscription_created, id, result})
            # Keep event_listener so we can forward subscription events
            {:ok,
             %{state | pending_subscription: nil, subscription_id: result, event_listener: from}}

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
        case state.pending_subscription do
          {^id, from} ->
            send(from, {:error, id, error})
            {:ok, %{state | pending_subscription: nil}}

          _ ->
            {:ok, state}
        end

      {from, new_pending} ->
        send(from, {:error, id, error})
        {:ok, %{state | pending_requests: new_pending}}
    end
  end

  defp handle_subscription_event(sub_id, event, state) do
    if state.event_listener do
      send(state.event_listener, {:subscription_event, sub_id, event})
    end

    {:ok, state}
  end
end
