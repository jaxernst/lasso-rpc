defmodule Lasso.ConnectCircuitHTTPTest do
  use ExUnit.Case, async: false

  alias Lasso.BlockSync.Strategies.HttpStrategy
  alias Lasso.Config.ConfigStore
  alias Lasso.Core.Support.{CircuitBreaker, GapFiller}
  alias Lasso.Providers
  alias Lasso.Providers.Catalog
  alias Lasso.Test.Eventually

  defmodule Upstream do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, bytes, conn} = read_body(conn)
      body = Jason.decode!(bytes)
      send(opts[:owner], {:upstream, opts[:name], body["method"], self()})

      if body["method"] == "eth_blockNumber" and Agent.get(opts[:hold], & &1) do
        receive do
          :release -> :ok
        after
          5_000 -> raise "held head poll was not released"
        end
      end

      result =
        case body["method"] do
          "eth_chainId" -> "0x" <> Integer.to_string(opts[:chain], 16)
          "eth_blockNumber" -> "0x3"
          "eth_getBlockByNumber" -> %{"number" => hd(body["params"])}
          _ -> opts[:name]
        end

      send_resp(conn, 200, Jason.encode!(%{jsonrpc: "2.0", id: body["id"], result: result}))
    end
  end

  setup do
    chain = 800_000_000 + rem(System.unique_integer([:positive]), 100_000_000)
    hold = start_supervised!({Agent, fn -> false end})
    previous = Application.get_env(:lasso, :http_client)
    Application.put_env(:lasso, :http_client, Lasso.RPC.Transport.HTTP.Client.Finch)
    :ok = ConfigStore.register_chain_runtime("public", chain, %{providers: [], head_policy: :off})

    upstreams =
      for {name, priority} <- [{"a", 1}, {"b", 2}] do
        ref = {__MODULE__, chain, name}
        opts = [owner: self(), name: name, chain: chain, hold: hold]
        {:ok, _} = Plug.Cowboy.http(Upstream, opts, ref: ref, port: 0)
        port = :ranch.get_port(ref)
        id = "connect-#{chain}-#{name}"

        assert {:ok, ^id} =
                 Providers.add_provider(
                   chain,
                   %{
                     id: id,
                     name: name,
                     priority: priority,
                     url: "http://127.0.0.1:#{port}",
                     background_observations: false,
                     subscribe_new_heads: false
                   },
                   validate: false
                 )

        %{ref: ref, port: port, id: id, opts: opts}
      end

    on_exit(fn ->
      Application.put_env(:lasso, :http_client, previous)

      for u <- upstreams do
        Providers.remove_provider(chain, u.id)
        Plug.Cowboy.shutdown(u.ref)
      end

      Lasso.ProfileChainSupervisor.stop_profile_chain("public", chain)
      ConfigStore.unregister_chain_runtime("public", chain)
    end)

    %{chain: chain, a: hd(upstreams), hold: hold}
  end

  test "refused connections stop leading traffic and recover promptly after repeated probation",
       ctx do
    assert rpc(ctx.chain)["result"] == "a"
    :ok = Plug.Cowboy.shutdown(ctx.a.ref)
    breaker = breaker(ctx)
    owner = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:finch, :connect, :start],
        fn _, _, metadata, _ ->
          if metadata.port == ctx.a.port, do: send(owner, :connect_a)
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    for _ <- 1..3, do: assert(rpc(ctx.chain)["result"] == "b")
    Eventually.assert_eventually(fn -> CircuitBreaker.get_state(breaker).state == :open end)
    # The first failed request may also discard a stale keep-alive connection.
    # All three requests must actually attempt the refused endpoint.
    for _ <- 1..3, do: assert_receive(:connect_a, 1_000)
    remaining = CircuitBreaker.get_recovery_time_remaining(breaker)
    assert remaining > 0 and remaining <= 1_050

    for _ <- 1..20, do: assert(rpc(ctx.chain)["result"] == "b")
    assert CircuitBreaker.get_state(breaker).state == :open
    refute_receive :connect_a, 0

    # Forced requests exercise the same leased probation used by head polls.
    for expected <- [2_000, 4_000, 4_000] do
      Eventually.assert_eventually(
        fn -> CircuitBreaker.get_state(breaker).state == :half_open end,
        timeout: 5_000
      )

      assert rpc(ctx.chain, ctx.a.id)["error"]
      Eventually.assert_eventually(fn -> CircuitBreaker.get_state(breaker).state == :open end)
      assert CircuitBreaker.get_recovery_time_remaining(breaker) <= div(expected * 105, 100)
      assert CircuitBreaker.get_recovery_time_remaining(breaker) > expected - 500
    end

    {:ok, _} = Plug.Cowboy.http(Upstream, ctx.a.opts, ref: ctx.a.ref, port: ctx.a.port)
    started = System.monotonic_time(:millisecond)

    Eventually.assert_eventually(fn -> rpc(ctx.chain, ctx.a.id)["result"] == "a" end,
      timeout: 6_000
    )

    Eventually.assert_eventually(fn -> CircuitBreaker.get_state(breaker).state == :closed end)
    assert System.monotonic_time(:millisecond) - started < 6_000
    assert rpc(ctx.chain)["result"] == "a"
  end

  test "backfill retries probation occupied by a real head poll within its recovery deadline",
       ctx do
    assert rpc(ctx.chain)["result"] == "a"
    :ok = Plug.Cowboy.shutdown(ctx.a.ref)
    for _ <- 1..3, do: assert(rpc(ctx.chain)["result"] == "b")
    breaker = breaker(ctx)
    Eventually.assert_eventually(fn -> CircuitBreaker.get_state(breaker).state == :half_open end)
    {:ok, _} = Plug.Cowboy.http(Upstream, ctx.a.opts, ref: ctx.a.ref, port: ctx.a.port)
    Agent.update(ctx.hold, fn _ -> true end)

    instance = elem(breaker, 0)

    {:ok, poll} =
      HttpStrategy.start(ctx.chain, instance, poll_interval_ms: 60_000, initial_delay_ms: 0)

    assert_receive {:http_strategy, :poll, ^instance, generation}, 1_000
    {:ok, poll} = HttpStrategy.handle_message({:poll, generation}, poll)
    assert_receive {:upstream, "a", "eth_blockNumber", held}, 2_000
    assert CircuitBreaker.get_state(breaker).state == :half_open

    expired = GapFiller.Plan.new("public", ctx.chain, ctx.a.id, self(), 150)
    assert {:error, :deadline_exhausted} = GapFiller.ensure_blocks(expired, 1, 3)

    plan = GapFiller.Plan.new("public", ctx.chain, ctx.a.id, self(), 30_000)
    backfill = Task.async(fn -> GapFiller.ensure_blocks(plan, 1, 3) end)
    # A busy lease must not send a competing request or finish as an error.
    assert Task.yield(backfill, 250) == nil
    refute_receive {:upstream, "a", "eth_getBlockByNumber", _}, 0
    send(held, :release)
    assert {:ok, blocks} = Task.await(backfill, 5_000)
    assert Enum.map(blocks, & &1["number"]) == ["0x1", "0x2", "0x3"]
    assert System.monotonic_time(:microsecond) < plan.deadline_us
    Eventually.assert_eventually(fn -> CircuitBreaker.get_state(breaker).state == :closed end)
    HttpStrategy.stop(poll)
  end

  defp breaker(ctx), do: {Catalog.lookup_instance_id("public", ctx.chain, ctx.a.id), :http}

  defp rpc(chain, provider \\ nil) do
    port = LassoWeb.Endpoint.config(:http)[:port]
    prefix = "http://127.0.0.1:#{port}/rpc/profile/public"

    url =
      if provider,
        do: "#{prefix}/provider/#{provider}/#{chain}",
        else: "#{prefix}/priority/#{chain}"

    body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: System.unique_integer([:positive]),
        method: "web3_clientVersion",
        params: []
      })

    {:ok, response} =
      Finch.build(:post, url, [{"content-type", "application/json"}], body)
      |> Finch.request(Lasso.Finch, receive_timeout: 5_000)

    Jason.decode!(response.body)
  end
end
