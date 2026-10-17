defmodule Lasso.Test.Harness.Fleet do
  @moduledoc """
  Real port-0 HTTP/WS upstreams with per-method action queues and an owned ledger.

  `drain/1` acknowledges all requests recorded before its reply; it does not wait
  for held responses or predict future sends. Retire the tenant before `stop/1`.
  Owner death stops the listener as failure cleanup.
  """
  use GenServer

  @doc "Starts one owned HTTP/WS upstream on loopback port 0."
  def start!(owner, name) do
    {:ok, pid} = GenServer.start(__MODULE__, {owner, name})
    GenServer.call(pid, :endpoint)
  end

  def stop(f), do: GenServer.stop(f.pid)

  def script(f, method, calls, fallback \\ :default),
    do: GenServer.call(f.pid, {:script, method, calls, fallback})

  def release(f, token, action), do: GenServer.call(f.pid, {:release, token, action})
  def drain(f), do: GenServer.call(f.pid, :drain)

  def request(fleet, transport, request),
    do: GenServer.call(fleet, {:request, transport, request})

  @impl true
  def init({owner, name}) do
    ref = {__MODULE__, make_ref()}

    {:ok, _} =
      :cowboy.start_clear(ref, %{socket_opts: [ip: {127, 0, 0, 1}, port: 0]}, %{
        env: %{dispatch: :cowboy_router.compile([{:_, [{:_, __MODULE__.Wire, self()}]}])}
      })

    endpoint = %{
      pid: self(),
      name: name,
      url: "http://127.0.0.1:#{:ranch.get_port(ref)}",
      ws_url: "ws://127.0.0.1:#{:ranch.get_port(ref)}/ws"
    }

    {:ok,
     %{
       owner: owner,
       monitor: Process.monitor(owner),
       ref: ref,
       endpoint: endpoint,
       name: name,
       scripts: %{},
       calls: [],
       holds: %{}
     }}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _, _}, %{monitor: monitor} = state),
    do: {:stop, :normal, state}

  @impl true
  def terminate(_, state), do: :cowboy.stop_listener(state.ref)

  @impl true
  def handle_call(:endpoint, _, s), do: {:reply, s.endpoint, s}

  def handle_call({:script, method, calls, fallback}, _, s),
    do: {:reply, :ok, put_in(s.scripts[method], {calls, fallback})}

  def handle_call(:drain, _, s), do: {:reply, Enum.reverse(s.calls), s}

  def handle_call({:release, token, action}, _, s) do
    case Map.pop(s.holds, token) do
      {nil, _} ->
        {:reply, {:error, :unknown_hold}, s}

      {pid, holds} ->
        send(pid, {:release, token, action})
        {:reply, :ok, %{s | holds: holds}}
    end
  end

  def handle_call({:request, transport, request}, {pid, _}, s) do
    method = request["method"]
    {calls, fallback} = Map.get(s.scripts, method, {[], :default})

    {action, remaining} =
      case calls do
        [next | rest] -> {next, rest}
        [] -> {fallback, []}
      end

    action = if action == :default, do: default(method), else: action
    report = %{fleet: s.name, transport: transport, request: request, action: action}
    send(s.owner, {:fleet, self(), report})

    s = %{
      s
      | scripts: Map.put(s.scripts, method, {remaining, fallback}),
        calls: [report | s.calls]
    }

    s =
      case action do
        {:hold, token} -> put_in(s.holds[token], pid)
        _ -> s
      end

    {:reply, action, s}
  end

  defp default("eth_chainId"), do: {:answer, "0x7a69"}

  defp default("eth_getBlockByNumber"),
    do:
      {:answer,
       %{
         number: "0x3e8",
         timestamp: "0x#{Integer.to_string(System.system_time(:second), 16)}",
         hash: "0x" <> String.duplicate("a", 64)
       }}

  defp default("eth_subscribe"), do: {:answer, "harness-sub"}
  defp default("eth_unsubscribe"), do: {:answer, true}
  defp default("eth_blockNumber"), do: {:answer, "0x3e8"}
  defp default(_), do: {:answer, "0x10"}

  defmodule Wire do
    def init(req, fleet) do
      if :cowboy_req.path(req) == "/ws" do
        {:cowboy_websocket, req, fleet}
      else
        {:ok, body, req} = read_body(req, [])
        request = Jason.decode!(body)
        action = Lasso.Test.Harness.Fleet.request(fleet, :http, request) |> released()

        case action do
          {:disconnect, _code} ->
            # Stop the owned connection before Cowboy can supply an implicit 204.
            Process.exit(req.pid, :kill)
            {:ok, req, fleet}

          _ ->
            {status, headers, body} = response(action, request)
            {:ok, :cowboy_req.reply(status, headers, body, req), fleet}
        end
      end
    end

    defp read_body(req, chunks) do
      case :cowboy_req.read_body(req) do
        {:ok, body, req} -> {:ok, IO.iodata_to_binary(Enum.reverse([body | chunks])), req}
        {:more, body, req} -> read_body(req, [body | chunks])
      end
    end

    def websocket_init(fleet), do: {:ok, fleet}

    def websocket_handle({:text, bytes}, fleet) do
      request = Jason.decode!(bytes)
      action = Lasso.Test.Harness.Fleet.request(fleet, :ws, request) |> released()

      case action do
        {:disconnect, code} ->
          {:reply, {:close, code, "scripted"}, fleet}

        _ ->
          {_, _, body} = response(action, request)
          {:reply, {:text, body}, fleet}
      end
    end

    def websocket_handle(_, fleet), do: {:ok, fleet}
    def websocket_info(_, fleet), do: {:ok, fleet}

    defp released({:hold, token}) do
      receive do
        {:release, ^token, action} -> action
      end
    end

    defp released(action), do: action

    defp response({:answer, value, extra}, r),
      do: json(200, %{}, r, Map.put(extra, :result, value))

    defp response({:answer, value}, r), do: json(200, %{}, r, %{result: value})

    defp response({:error, code, message}, r),
      do: json(200, %{}, r, %{error: %{code: code, message: message}})

    defp response({:status, status, headers, body}, r),
      do: json(status, Map.new(headers), r, body)

    defp json(status, headers, r, payload) do
      body =
        if is_binary(payload),
          do: payload,
          else: Jason.encode!(Map.merge(%{jsonrpc: "2.0", id: r["id"]}, payload))

      {status, Map.put(headers, "content-type", "application/json"), body}
    end
  end
end
