defmodule Lasso.RPC.Transport.WebSocket.ClientTest do
  use ExUnit.Case, async: true

  alias Lasso.RPC.Transport.WebSocket.Client

  defmodule Handler do
    def handle_connect(_connection, state) do
      send(state.owner, :connected)
      {:ok, state}
    end

    def handle_cast({:send, payload}, state) do
      send(self(), {:written, payload})
      {:reply, {:text, payload}, state}
    end

    def handle_info({:written, payload}, state) do
      send(state.owner, {:write_acknowledged, payload})
      {:ok, state}
    end

    def handle_info(_message, state), do: {:ok, state}

    def handle_frame(frame, state) do
      send(state.owner, {:frame, frame})
      {:ok, state}
    end

    def handle_disconnect(reason, state) do
      send(state.owner, {:disconnected, reason})
      {:ok, state}
    end
  end

  test "connects only to validated tuples and preserves path, authority, and safe headers" do
    server = start_server(self())
    port = server.port
    owner = self()

    resolver = fn "authority.example.test" ->
      send(owner, :resolved_once)
      {:ok, [{127, 0, 0, 2}, {127, 0, 0, 1}]}
    end

    assert {:ok, client} =
             Client.start_link(
               "ws://authority.example.test:#{port}/rpc/path?network=mainnet",
               Handler,
               %{owner: self()},
               owner: self(),
               resolver: resolver,
               address_orderer: &Enum.reverse/1,
               connect_timeout: 2_000,
               connect_attempt_timeout: 100,
               extra_headers: [
                 {"host", "attacker.invalid"},
                 {"authorization", "Bearer test-token"}
               ]
             )

    assert_receive :resolved_once
    refute_receive :resolved_once
    assert_receive :connected

    assert_receive {:handshake, request}
    assert request.request_line == "GET /rpc/path?network=mainnet HTTP/1.1"
    assert request.headers["host"] == "authority.example.test:#{port}"
    assert request.headers["authorization"] == "Bearer test-token"

    Client.cast(client, {:send, "hello"})
    assert_receive {:write_acknowledged, "hello"}
    assert_receive {:client_frame, {:text, "hello"}}

    send(server.pid, {:send_ping, "probe"})
    assert_receive {:client_frame, {:pong, "probe"}}

    monitor = Process.monitor(client)
    send(server.pid, {:send_close, 1_012, "restart"})

    assert_receive {:client_frame, {:close, 1_012, "restart"}}
    assert_receive {:disconnected, %{reason: {:remote, 1_012, "restart"}}}
    assert_receive {:DOWN, ^monitor, :process, ^client, :normal}

    stop_server(server)
  end

  test "fails closed when the resolver rejects any answer set" do
    server = start_server(self())

    assert {:error, {:network_error, "blocked answer"}} =
             Client.start_link(
               "ws://blocked.example.test:#{server.port}/rpc",
               Handler,
               %{owner: self()},
               owner: self(),
               resolver: fn _host -> {:error, :ssrf_blocked, "blocked answer"} end,
               connect_timeout: 100
             )

    refute_receive {:handshake, _request}, 150
    stop_server(server)
  end

  test "rejects URL fragments before DNS resolution" do
    resolver = fn _host ->
      flunk("fragment-bearing URL reached DNS resolution")
    end

    assert {:error, {:network_error, :invalid_websocket_url}} =
             Client.start_link(
               "wss://provider.example.test/rpc#ignored",
               Handler,
               %{owner: self()},
               resolver: resolver
             )
  end

  defp start_server(owner) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)

    pid =
      spawn_link(fn ->
        case :gen_tcp.accept(listener, 2_000) do
          {:ok, socket} ->
            :ok = :gen_tcp.close(listener)
            request = receive_handshake(socket, "")
            send(owner, {:handshake, request})
            :ok = :gen_tcp.send(socket, upgrade_response(request.headers["sec-websocket-key"]))
            server_loop(socket, owner)

          {:error, :closed} ->
            :ok

          {:error, :timeout} ->
            :gen_tcp.close(listener)
        end
      end)

    %{pid: pid, listener: listener, port: port}
  end

  defp stop_server(server) do
    :gen_tcp.close(server.listener)
    send(server.pid, :stop)
    :ok
  end

  defp receive_handshake(socket, buffer) do
    if String.contains?(buffer, "\r\n\r\n") do
      parse_request(buffer)
    else
      {:ok, chunk} = :gen_tcp.recv(socket, 0, 1_000)
      receive_handshake(socket, buffer <> chunk)
    end
  end

  defp parse_request(raw) do
    [request_line | header_lines] = String.split(raw, "\r\n", trim: true)

    headers =
      Map.new(header_lines, fn line ->
        [name, value] = String.split(line, ":", parts: 2)
        {String.downcase(name), String.trim(value)}
      end)

    %{request_line: request_line, headers: headers}
  end

  defp upgrade_response(key) do
    accept =
      :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
      |> Base.encode64()

    [
      "HTTP/1.1 101 Switching Protocols\r\n",
      "Upgrade: websocket\r\n",
      "Connection: Upgrade\r\n",
      "Sec-WebSocket-Accept: ",
      accept,
      "\r\n\r\n"
    ]
  end

  defp server_loop(socket, owner) do
    receive do
      {:send_ping, payload} ->
        :ok = :gen_tcp.send(socket, server_frame(0x9, payload))
        send(owner, {:client_frame, receive_client_frame(socket)})
        server_loop(socket, owner)

      {:send_close, code, reason} ->
        :ok = :gen_tcp.send(socket, server_frame(0x8, <<code::16, reason::binary>>))
        send(owner, {:client_frame, receive_client_frame(socket)})
        server_loop(socket, owner)

      :stop ->
        :gen_tcp.close(socket)
    after
      0 ->
        case :gen_tcp.recv(socket, 0, 50) do
          {:ok, data} ->
            send(owner, {:client_frame, decode_client_frame(data)})
            server_loop(socket, owner)

          {:error, :timeout} ->
            server_loop(socket, owner)

          {:error, :closed} ->
            :ok
        end
    end
  end

  defp receive_client_frame(socket) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 1_000)
    decode_client_frame(data)
  end

  defp decode_client_frame(<<_fin::1, _rsv::3, opcode::4, 1::1, length::7, rest::binary>>)
       when length < 126 do
    <<mask::binary-size(4), payload::binary-size(length), _remaining::binary>> = rest
    decoded = unmask(payload, mask)

    case opcode do
      0x1 -> {:text, decoded}
      0xA -> {:pong, decoded}
      0x8 -> decode_close(decoded)
    end
  end

  defp decode_close(<<code::16, reason::binary>>), do: {:close, code, reason}
  defp decode_close(<<>>), do: {:close, nil, nil}

  defp unmask(payload, mask) do
    mask
    |> :binary.bin_to_list()
    |> Stream.cycle()
    |> Enum.zip(:binary.bin_to_list(payload))
    |> Enum.map(fn {mask_byte, byte} -> Bitwise.bxor(mask_byte, byte) end)
    |> :binary.list_to_bin()
  end

  defp server_frame(opcode, payload) do
    <<1::1, 0::3, opcode::4, 0::1, byte_size(payload)::7, payload::binary>>
  end
end
