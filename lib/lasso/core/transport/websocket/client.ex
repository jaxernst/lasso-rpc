defmodule Lasso.RPC.Transport.WebSocket.Client do
  @moduledoc false

  use GenServer

  alias Lasso.Core.Transport.OriginResolver

  @default_connect_timeout 10_000
  @default_attempt_timeout 2_000
  @forbidden_headers ~w[host connection upgrade sec-websocket-accept sec-websocket-extensions sec-websocket-key sec-websocket-protocol sec-websocket-version]

  defstruct [
    :conn,
    :request_ref,
    :websocket,
    :handler,
    :handler_state,
    :owner_monitor
  ]

  @spec start_link(String.t(), module(), term(), keyword()) :: GenServer.on_start()
  def start_link(url, handler, handler_state, opts \\ []) do
    case GenServer.start(__MODULE__, {url, handler, handler_state, opts}) do
      {:ok, pid} ->
        link_started_process(pid)

      error ->
        error
    end
  end

  @spec cast(pid(), term()) :: :ok
  def cast(pid, message), do: GenServer.cast(pid, message)

  @impl true
  def init({url, handler, handler_state, opts}) do
    with {:ok, connection} <- connect(url, opts),
         {:ok, handler_state} <- handler.handle_connect(%{}, handler_state) do
      owner_monitor = monitor_owner(handler_state, opts)

      {:ok,
       struct!(__MODULE__,
         conn: connection.conn,
         request_ref: connection.request_ref,
         websocket: connection.websocket,
         handler: handler,
         handler_state: handler_state,
         owner_monitor: owner_monitor
       )}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_cast(message, state) do
    state.handler.handle_cast(message, state.handler_state)
    |> apply_handler_result(state)
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{owner_monitor: monitor} = state) do
    {:stop, :normal, state}
  end

  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        process_responses(responses, %{state | conn: conn})

      {:error, conn, reason, responses} ->
        case process_responses(responses, %{state | conn: conn}) do
          {:noreply, state} -> disconnect(state, {:error, reason})
          other -> other
        end

      :unknown ->
        state.handler.handle_info(message, state.handler_state)
        |> apply_handler_result(state)
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.owner_monitor, do: Process.demonitor(state.owner_monitor, [:flush])
    if state.conn, do: Mint.HTTP.close(state.conn)
    :ok
  end

  defp connect(url, opts) do
    resolver =
      Keyword.get_lazy(opts, :resolver, fn ->
        Application.get_env(
          :lasso,
          :custom_origin_resolver,
          &OriginResolver.resolve_addresses/1
        )
      end)

    timeout = Keyword.get(opts, :connect_timeout, @default_connect_timeout)
    deadline = System.monotonic_time(:millisecond) + timeout

    with {:ok, uri} <- parse_url(url),
         {:ok, addresses} <- OriginResolver.resolve(uri.host, resolver) do
      addresses
      |> order_addresses(opts)
      |> connect_addresses(uri, opts, deadline, nil)
    else
      {:error, {:network_error, _reason} = error} -> {:error, error}
      {:error, reason} -> {:error, {:network_error, reason}}
      _other -> {:error, {:network_error, :invalid_resolver_result}}
    end
  end

  defp parse_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, userinfo: nil, fragment: nil} = uri
      when scheme in ["ws", "wss"] and is_binary(host) and host != "" ->
        {:ok, uri}

      _other ->
        {:error, {:network_error, :invalid_websocket_url}}
    end
  end

  defp order_addresses(addresses, opts) do
    addresses = Enum.sort(addresses)

    case Keyword.get(opts, :address_orderer) do
      orderer when is_function(orderer, 1) ->
        orderer.(addresses)

      _other ->
        selector = {
          Keyword.get(opts, :connection_id),
          Application.get_env(:lasso, :node_id),
          Keyword.get(opts, :connection_generation)
        }

        rotate(addresses, :erlang.phash2(selector, length(addresses)))
    end
  end

  defp rotate(addresses, 0), do: addresses
  defp rotate(addresses, offset), do: Enum.drop(addresses, offset) ++ Enum.take(addresses, offset)

  defp connect_addresses([], _uri, _opts, _deadline, nil),
    do: {:error, {:network_error, :connection_failed}}

  defp connect_addresses(
         [],
         _uri,
         _opts,
         _deadline,
         {:ws_upgrade_error, _status, _headers} = error
       ),
       do: {:error, error}

  defp connect_addresses([], _uri, _opts, _deadline, last_error),
    do: {:error, {:network_error, last_error}}

  defp connect_addresses([address | rest], uri, opts, deadline, _last_error) do
    case connect_address(address, uri, opts, deadline) do
      {:ok, _connection} = success ->
        success

      {:error, {:ws_upgrade_error, status, _headers}} = error
      when status in 400..499 and status != 408 ->
        error

      {:error, reason} ->
        connect_addresses(rest, uri, opts, deadline, reason)
    end
  end

  defp connect_address(address, uri, opts, deadline) do
    with {:ok, timeout} <- remaining_timeout(deadline),
         {:ok, conn} <-
           Mint.HTTP.connect(http_scheme(uri.scheme), address, port(uri),
             hostname: uri.host,
             protocols: [:http1],
             transport_opts: [
               timeout:
                 min(
                   timeout,
                   Keyword.get(opts, :connect_attempt_timeout, @default_attempt_timeout)
                 )
             ]
           ),
         {:ok, conn, request_ref} <-
           Mint.WebSocket.upgrade(
             websocket_scheme(uri.scheme),
             conn,
             request_path(uri),
             safe_headers(Keyword.get(opts, :extra_headers, []))
           ) do
      await_upgrade(conn, request_ref, deadline, nil, [])
    else
      {:error, conn, reason} ->
        Mint.HTTP.close(conn)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp await_upgrade(conn, request_ref, deadline, status, headers) do
    case remaining_timeout(deadline) do
      {:ok, timeout} ->
        receive do
          message ->
            case Mint.WebSocket.stream(conn, message) do
              {:ok, conn, responses} ->
                case collect_upgrade(responses, request_ref, status, headers) do
                  {:continue, status, headers} ->
                    await_upgrade(conn, request_ref, deadline, status, headers)

                  {:done, status, headers} ->
                    finish_upgrade(conn, request_ref, status, headers)

                  {:error, reason} ->
                    Mint.HTTP.close(conn)
                    {:error, reason}
                end

              {:error, conn, reason, _responses} ->
                Mint.HTTP.close(conn)
                {:error, reason}

              :unknown ->
                await_upgrade(conn, request_ref, deadline, status, headers)
            end
        after
          timeout ->
            Mint.HTTP.close(conn)
            {:error, :connection_timeout}
        end

      {:error, reason} ->
        Mint.HTTP.close(conn)
        {:error, reason}
    end
  end

  defp collect_upgrade(responses, request_ref, initial_status, initial_headers) do
    Enum.reduce_while(
      responses,
      {:continue, initial_status, initial_headers},
      fn
        {:status, ^request_ref, status}, {:continue, _old, headers} ->
          {:cont, {:continue, status, headers}}

        {:headers, ^request_ref, headers}, {:continue, status, existing} ->
          {:cont, {:continue, status, existing ++ headers}}

        {:done, ^request_ref}, {:continue, status, headers} ->
          {:halt, {:done, status, headers}}

        {:error, ^request_ref, reason}, _state ->
          {:halt, {:error, reason}}

        _response, state ->
          {:cont, state}
      end
    )
  end

  defp finish_upgrade(conn, request_ref, status, headers) when is_integer(status) do
    case Mint.WebSocket.new(conn, request_ref, status, headers) do
      {:ok, conn, websocket} ->
        {:ok, %{conn: conn, request_ref: request_ref, websocket: websocket}}

      {:error, conn, %Mint.WebSocket.UpgradeFailureError{} = error} ->
        Mint.HTTP.close(conn)
        {:error, {:ws_upgrade_error, error.status_code, safe_response_headers(error.headers)}}

      {:error, conn, reason} ->
        Mint.HTTP.close(conn)
        {:error, reason}
    end
  end

  defp finish_upgrade(conn, _request_ref, _status, _headers) do
    Mint.HTTP.close(conn)
    {:error, :invalid_upgrade_response}
  end

  defp process_responses(responses, state) do
    Enum.reduce_while(responses, {:noreply, state}, fn
      {:data, request_ref, data}, {:noreply, %{request_ref: request_ref} = state} ->
        case decode_frames(data, state) do
          {:noreply, _state} = result -> {:cont, result}
          stop -> {:halt, stop}
        end

      {:error, request_ref, reason}, {:noreply, %{request_ref: request_ref} = state} ->
        {:halt, disconnect(state, {:error, reason})}

      _response, result ->
        {:cont, result}
    end)
  end

  defp decode_frames(data, state) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        dispatch_frames(frames, %{state | websocket: websocket})

      {:error, websocket, reason} ->
        disconnect(%{state | websocket: websocket}, {:error, reason})
    end
  end

  defp dispatch_frames(frames, state) do
    Enum.reduce_while(frames, {:noreply, state}, fn
      {:ping, payload}, {:noreply, state} ->
        case write_frame({:pong, payload}, state) do
          {:ok, state} -> {:cont, {:noreply, state}}
          {:error, reason, state} -> {:halt, disconnect(state, {:error, reason})}
        end

      {:pong, _payload}, result ->
        {:cont, result}

      {:close, code, reason}, {:noreply, state} ->
        state = acknowledge_close(code, reason, state)
        {:halt, disconnect(state, {:remote, code || 1_000, reason || ""})}

      {:error, reason}, {:noreply, state} ->
        {:halt, disconnect(state, {:error, reason})}

      frame, {:noreply, state} ->
        case state.handler.handle_frame(frame, state.handler_state)
             |> apply_handler_result(state) do
          {:noreply, _state} = result -> {:cont, result}
          stop -> {:halt, stop}
        end
    end)
  end

  defp apply_handler_result({:ok, handler_state}, state),
    do: {:noreply, %{state | handler_state: handler_state}}

  defp apply_handler_result({:reply, frame, handler_state}, state) do
    state = %{state | handler_state: handler_state}

    case write_frame(frame, state) do
      {:ok, state} -> {:noreply, state}
      {:error, reason, state} -> disconnect(state, {:error, reason})
    end
  end

  defp apply_handler_result({:close, handler_state}, state) do
    state = %{state | handler_state: handler_state}

    case write_frame(:close, state) do
      {:ok, state} -> disconnect(state, {:local, :normal})
      {:error, reason, state} -> disconnect(state, {:error, reason})
    end
  end

  defp write_frame(frame, state) do
    case Mint.WebSocket.encode(state.websocket, frame) do
      {:ok, websocket, data} ->
        case Mint.WebSocket.stream_request_body(state.conn, state.request_ref, data) do
          {:ok, conn} ->
            {:ok, %{state | conn: conn, websocket: websocket}}

          {:error, conn, reason} ->
            {:error, reason, %{state | conn: conn, websocket: websocket}}
        end

      {:error, websocket, reason} ->
        {:error, reason, %{state | websocket: websocket}}
    end
  end

  defp acknowledge_close(code, reason, state) do
    case write_frame({:close, code || 1_000, reason || ""}, state) do
      {:ok, state} -> state
      {:error, _reason, state} -> state
    end
  end

  defp disconnect(state, reason) do
    handler_state =
      case state.handler.handle_disconnect(%{reason: reason}, state.handler_state) do
        {:ok, handler_state} -> handler_state
        _other -> state.handler_state
      end

    {:stop, :normal, %{state | handler_state: handler_state}}
  end

  defp monitor_owner(handler_state, opts) do
    owner =
      Keyword.get(opts, :owner) ||
        if(is_map(handler_state), do: Map.get(handler_state, :parent), else: nil)

    if is_pid(owner), do: Process.monitor(owner)
  end

  defp safe_headers(headers) do
    Enum.flat_map(headers, fn
      {name, value} when (is_binary(name) or is_atom(name)) and not is_nil(value) ->
        name = name |> to_string() |> String.downcase()

        if name in @forbidden_headers do
          []
        else
          [{name, to_string(value)}]
        end

      _other ->
        []
    end)
  end

  defp safe_response_headers(headers) do
    headers
    |> List.flatten()
    |> Enum.filter(fn {name, _value} -> String.downcase(name) == "retry-after" end)
  end

  defp request_path(%URI{path: path, query: nil}), do: normalize_path(path)
  defp request_path(%URI{path: path, query: query}), do: normalize_path(path) <> "?" <> query
  defp normalize_path(path) when path in [nil, ""], do: "/"
  defp normalize_path(path), do: path

  defp http_scheme("ws"), do: :http
  defp http_scheme("wss"), do: :https
  defp websocket_scheme("ws"), do: :ws
  defp websocket_scheme("wss"), do: :wss
  defp port(%URI{port: port}) when is_integer(port), do: port
  defp port(%URI{scheme: "ws"}), do: 80
  defp port(%URI{scheme: "wss"}), do: 443

  defp remaining_timeout(deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 -> {:ok, remaining}
      _expired -> {:error, :connection_timeout}
    end
  end

  defp link_started_process(pid) do
    Process.link(pid)
    {:ok, pid}
  rescue
    ArgumentError -> {:error, :connection_closed}
  catch
    :exit, :noproc -> {:error, :connection_closed}
  end
end
