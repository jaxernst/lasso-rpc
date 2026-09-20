defmodule Lasso.RPC.ArchiveProviderDiversityTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  alias Lasso.Config.ConfigStore
  alias Lasso.Core.Support.CircuitBreaker
  alias Lasso.Providers.{Catalog, InstanceState}

  alias Lasso.RPC.{
    Channel,
    ExecutionEnvelope,
    RequestAnalysis,
    RequestOptions,
    RequestPipeline,
    Selection
  }

  alias Lasso.RPC.Strategies.LoadBalanced
  alias Lasso.Core.Support.CircuitBreaker.Snapshot
  alias Lasso.RPC.Selection.CandidateCursor

  defmodule ControlledTransport do
    alias Lasso.Core.Transport.AttemptProtocol
    def healthy?(_), do: true
    def capabilities(_), do: %{unary?: true, subscriptions?: false, methods: :all}

    def request(raw, request, _timeout) do
      context = AttemptProtocol.context()
      :ok = AttemptProtocol.send_started(context)
      :ok = AttemptProtocol.send_confirmed(context)
      send(raw.observer, {:dispatched, raw.provider_id, raw.transport})
      if action = Map.get(raw, :on_request), do: action.()

      if Map.get(raw, :succeed?, raw.provider_id == "capable") do
        AttemptProtocol.terminal_at(
          context,
          :response,
          %{response_kind: :success, io_duration_us: 1},
          System.monotonic_time(:microsecond)
        )

        bytes = Jason.encode!(%{jsonrpc: "2.0", id: request["id"], result: "0x1"})
        {:ok, %Lasso.RPC.Response.Success{id: request["id"], jsonrpc: "2.0", raw_bytes: bytes}, 1}
      else
        AttemptProtocol.terminal_at(
          context,
          :response,
          %{
            response_kind: :error,
            io_duration_us: 1,
            error_code: -32_000,
            error_category: :server_error
          },
          System.monotonic_time(:microsecond)
        )

        {:error,
         Lasso.JSONRPC.Error.new(-32_000, "historical state unavailable",
           retriable?: true,
           category: :server_error
         ), 1}
      end
    end
  end

  test "distinct archive providers get a first pass before sibling transports consume the budget" do
    {chain, snapshot, plan} =
      fixture([
        {"recent-a", false, [:http]},
        {"bad-a", true, [:http, :ws]},
        {"bad-b", true, [:http, :ws]},
        {"recent-b", false, [:http]},
        {"capable", true, [:http]}
      ])

    params = ["0x0000000000000000000000000000000000000001", "0x1"]

    assert RequestAnalysis.analyze("eth_getBalance", params, consensus_height: 100_000_000).requires_archival

    {seed, order} =
      find_order(snapshot, plan, params, :both, fn order ->
        assert length(order) == 5
        first = Enum.take(order, 3)

        Enum.all?(first, fn {id, _} -> id != "capable" end) and
          length(Enum.uniq_by(first, &elem(&1, 0))) == 2
      end)

    :rand.seed(:exsss, {seed, seed + 1, seed + 2})
    assert {:ok, _, ctx} = execute(chain, params, :both)
    assert ctx.executed_channel.provider_id == "capable"
    assert ctx.execution_envelope.dispatch_count == 3
    assert ctx.execution_envelope.candidate_admission_count == 3
    assert ctx.execution_envelope.dispatch_limit == 3
    assert ctx.execution_envelope.deadline_us - ctx.execution_envelope.started_at_us == 2_000_000
    expected = Enum.uniq_by(order, &elem(&1, 0)) |> Enum.take(3)
    assert dispatched(3) == expected

    assert {:ok, _, recovered} = execute(chain, params, :http)
    assert recovered.executed_channel.provider_id == "capable"
    assert recovered.execution_envelope.dispatch_count <= 3
  end

  test "hash selectors leave five distinct providers eligible and can starve archive even over HTTP only" do
    {chain, snapshot, plan} =
      fixture([
        {"recent-a", false, [:http]},
        {"bad-a", true, [:http]},
        {"bad-b", true, [:http]},
        {"recent-b", false, [:http]},
        {"capable", true, [:http]}
      ])

    params = [
      "0x0000000000000000000000000000000000000001",
      %{"blockHash" => "0x" <> String.duplicate("1", 64), "requireCanonical" => true}
    ]

    refute RequestAnalysis.analyze("eth_getBalance", params, consensus_height: 100_000_000).requires_archival

    {seed, _order} =
      find_order(snapshot, plan, params, :http, fn order ->
        length(order) == 5 and Enum.all?(Enum.take(order, 3), fn {id, _} -> id != "capable" end)
      end)

    :rand.seed(:exsss, {seed, seed + 1, seed + 2})
    assert {:error, _, ctx} = execute(chain, params, :http)
    assert ctx.terminal_reason == :dispatch_budget_exhausted
    assert ctx.execution_envelope.dispatch_count == 3
    assert ctx.execution_envelope.dispatch_limit == 3
    assert ctx.execution_envelope.deadline_us - ctx.execution_envelope.started_at_us == 2_000_000
    refute_receive {:dispatched, "capable", _}, 10

    assert {:ok, _, recovered} = execute(chain, params, :http, "capable")
    assert recovered.execution_envelope.dispatch_count == 1
  end

  test "ranking retains all transports and groups aliases by physical instance" do
    a = %Channel{
      instance_id: "a",
      provider_id: "a",
      profile: "public",
      chain_id: 1,
      transport: :http
    }

    a_alias = %{a | provider_id: "alias", transport: :ws}
    b = %{a | instance_id: "b", provider_id: "b"}
    input = [a, a_alias, b]
    assert [^a, ^b, ^a_alias] = LoadBalanced.order_fallbacks(input, "eth_getBalance")

    assert [^b, ^a, ^a_alias] =
             LoadBalanced.order_fallbacks(input, "eth_getBalance", MapSet.new(["a"]))

    for method <- [
          "eth_sendRawTransaction",
          "eth_sendTransaction",
          "eth_getFilterChanges",
          "unknown_method"
        ] do
      :rand.seed(:exsss, {2, 3, 4})
      expected = Enum.shuffle(input)
      :rand.seed(:exsss, {2, 3, 4})
      assert LoadBalanced.rank_channels(input, method, nil, "public", 1) == expected
      assert ExecutionEnvelope.new("safety", method, 2_000).dispatch_limit == 1
    end
  end

  test "unsafe cursor methods retain the shuffled descriptor order" do
    {_chain, snapshot, plan} =
      fixture([{"bad-a", true, [:http, :ws]}, {"capable", true, [:http]}])

    for method <- [
          "eth_sendRawTransaction",
          "eth_sendTransaction",
          "eth_getFilterChanges",
          "unknown_method"
        ] do
      cursor = CandidateCursor.new(snapshot, plan, method, strategy: :load_balanced)

      expected =
        Enum.map(cursor.descriptors, fn {provider, transport} -> {provider.id, transport} end)

      {actual, _} =
        Enum.map_reduce(expected, cursor, fn _, remaining ->
          assert {:ok, channel, remaining} = CandidateCursor.next(remaining)
          {{channel.provider_id, channel.transport}, remaining}
        end)

      assert actual == expected
    end
  end

  test "a sole provider retains its working alternate transport" do
    {chain, snapshot, plan} = fixture([{"capable", true, [:http, :ws]}])
    key = {"public", chain, "capable", :http}
    [{^key, channel}] = :ets.lookup(:transport_channel_cache, key)

    :ets.insert(
      :transport_channel_cache,
      {key, %{channel | raw_channel: Map.put(channel.raw_channel, :succeed?, false)}}
    )

    params = ["0x0000000000000000000000000000000000000001", "0x1"]
    {seed, _} = find_order(snapshot, plan, params, :both, &(hd(&1) == {"capable", :http}))
    :rand.seed(:exsss, {seed, seed + 1, seed + 2})
    assert {:ok, _, ctx} = execute(chain, params, :both)
    assert ctx.execution_envelope.dispatch_count == 2
    assert dispatched(2) == [{"capable", :http}, {"capable", :ws}]
  end

  test "unavailable sibling transport cannot use the capable provider's first pass" do
    {chain, snapshot, plan} =
      fixture([
        {"bad-a", true, [:http, :ws]},
        {"bad-b", true, [:http, :ws]},
        {"capable", true, [:http, :ws]}
      ])

    id = Catalog.lookup_instance_id("public", chain, "capable")
    :ets.insert(:lasso_instance_state, {{:ws_status, id}, %{status: :disconnected}})
    params = ["0x0000000000000000000000000000000000000001", "0x1"]

    {seed, _} =
      find_order(snapshot, plan, params, :both, fn order ->
        hd(order) == {"capable", :ws} and Enum.find_index(order, &(&1 == {"capable", :http})) >= 3
      end)

    :rand.seed(:exsss, {seed, seed + 1, seed + 2})
    assert {:ok, _, ctx} = execute(chain, params, :both)
    assert ctx.executed_channel.provider_id == "capable"
    assert ctx.executed_channel.transport == :http
    assert ctx.execution_envelope.dispatch_count <= 3
  end

  test "cursor deferral stays bounded and existing channel return limits hold" do
    {_chain, snapshot, plan} = fixture([{"bad-a", true, [:http, :ws]}])
    provider = hd(plan.providers)

    cursor =
      CandidateCursor.new(snapshot, plan, "eth_getBalance", strategy: :load_balanced, limit: 3)

    cursor = %{cursor | descriptors: List.duplicate({provider, :http}, 100)}
    assert {:ok, _, cursor} = CandidateCursor.next(cursor)
    assert {:ok, _, cursor} = CandidateCursor.next(cursor)
    assert length(cursor.descriptors) == 96
    assert :queue.len(cursor.supported_deferred[1]) == 2
    assert {:ok, _, cursor} = CandidateCursor.next(cursor)
    assert :done = CandidateCursor.next(cursor)
  end

  test "seen instances and exclusions survive a rebuilt cursor and eager selection" do
    {chain, snapshot, plan} = fixture([{"bad-a", true, [:http, :ws]}, {"capable", true, [:http]}])
    id = Catalog.lookup_instance_id("public", chain, "bad-a")
    opts = [strategy: :load_balanced, attempted_instances: [id]]
    cursor = CandidateCursor.new(snapshot, plan, "eth_getBalance", opts)
    assert {:ok, %{provider_id: "capable"}, cursor} = CandidateCursor.next(cursor)
    assert {:ok, %{provider_id: "bad-a"}, _} = CandidateCursor.next(cursor)

    assert [%{provider_id: "capable"} | _] =
             Selection.select_channels("public", chain, "eth_getBalance", opts)

    rebuilt = CandidateCursor.new(snapshot, plan, "eth_getBalance", opts ++ [exclude: ["bad-a"]])
    assert {:ok, %{provider_id: "capable"}, rebuilt} = CandidateCursor.next(rebuilt)
    assert :done = CandidateCursor.next(rebuilt)
  end

  test "deferred channels cannot outlive the catalog snapshot" do
    {_chain, snapshot, plan} =
      fixture([{"bad-a", true, [:http, :ws]}, {"capable", true, [:http]}])

    [a, b] = Enum.sort_by(plan.providers, & &1.id)
    cursor = CandidateCursor.new(snapshot, plan, "eth_getBalance", strategy: :load_balanced)
    cursor = %{cursor | descriptors: [{a, :http}, {a, :ws}, {b, :http}]}
    assert {:ok, %{provider_id: "bad-a"}, cursor} = CandidateCursor.next(cursor)
    assert {:ok, %{provider_id: "capable"}, cursor} = CandidateCursor.next(cursor)
    assert :queue.len(cursor.supported_deferred[1]) == 1
    excluded = CandidateCursor.exclude_provider(cursor, "bad-a")
    assert :done = CandidateCursor.next(excluded)
    Catalog.build_from_config()
    assert :stale = CandidateCursor.next(cursor)
  end

  test "closed-circuit alternates retain precedence over a different half-open provider" do
    {chain, snapshot, plan} = fixture([{"bad-a", true, [:http, :ws]}, {"capable", true, [:http]}])
    id = Catalog.lookup_instance_id("public", chain, "capable")
    {:ok, breaker} = Snapshot.lookup({id, :http})

    :sys.replace_state(
      GenServer.whereis(CircuitBreaker.via_name({id, :http})),
      &%{&1 | state: :half_open}
    )

    Snapshot.put(%{breaker | state: :half_open})
    cursor = CandidateCursor.new(snapshot, plan, "eth_getBalance", strategy: :load_balanced)
    assert {:ok, %{provider_id: "bad-a"}, cursor} = CandidateCursor.next(cursor)
    assert {:ok, %{provider_id: "bad-a"}, cursor} = CandidateCursor.next(cursor)
    assert {:ok, %{provider_id: "capable"}, _} = CandidateCursor.next(cursor)

    assert [%{provider_id: "bad-a"}, %{provider_id: "bad-a"}, %{provider_id: "capable"}] =
             Selection.select_channels("public", chain, "eth_getBalance",
               strategy: :load_balanced
             )
  end

  test "a half-open sibling cannot reorder the first healthy eager choice" do
    {chain, snapshot, plan} = fixture([{"bad-a", true, [:http, :ws]}, {"capable", true, [:http]}])
    id = Catalog.lookup_instance_id("public", chain, "bad-a")

    :sys.replace_state(
      GenServer.whereis(CircuitBreaker.via_name({id, :http})),
      &%{&1 | state: :half_open}
    )

    {:ok, breaker} = Snapshot.lookup({id, :http})
    Snapshot.put(%{breaker | state: :half_open})

    {seed, _} =
      find_order(snapshot, plan, [], :both, fn order ->
        order == [{"bad-a", :http}, {"bad-a", :ws}, {"capable", :http}]
      end)

    :rand.seed(:exsss, {seed, seed + 1, seed + 2})

    assert [
             %{provider_id: "bad-a", transport: :ws},
             %{provider_id: "capable"},
             %{provider_id: "bad-a", transport: :http}
           ] =
             Selection.select_channels("public", chain, "eth_getBalance",
               strategy: :load_balanced
             )
  end

  test "eager and cursor fallbacks retain seen instances across availability tiers" do
    {chain, snapshot, plan} =
      fixture([
        {"bad-a", true, [:http, :ws]},
        {"bad-b", true, [:http]},
        {"capable", true, [:http]}
      ])

    for {provider, transport} <- [{"bad-a", :ws}, {"capable", :http}] do
      id = Catalog.lookup_instance_id("public", chain, provider)

      :sys.replace_state(
        GenServer.whereis(CircuitBreaker.via_name({id, transport})),
        &%{&1 | state: :half_open}
      )

      {:ok, breaker} = Snapshot.lookup({id, transport})
      Snapshot.put(%{breaker | state: :half_open})
    end

    {seed, _} =
      find_order(snapshot, plan, [], :both, fn order ->
        order == [{"bad-a", :http}, {"bad-b", :http}, {"bad-a", :ws}, {"capable", :http}]
      end)

    expected = [{"bad-a", :http}, {"bad-b", :http}, {"capable", :http}, {"bad-a", :ws}]

    :rand.seed(:exsss, {seed, seed + 1, seed + 2})

    eager =
      Selection.select_channels("public", chain, "eth_getBalance", strategy: :load_balanced)

    assert Enum.map(eager, &{&1.provider_id, &1.transport}) == expected

    :rand.seed(:exsss, {seed, seed + 1, seed + 2})
    cursor = CandidateCursor.new(snapshot, plan, "eth_getBalance", strategy: :load_balanced)

    {actual, _} =
      Enum.map_reduce(expected, cursor, fn _, remaining ->
        assert {:ok, channel, remaining} = CandidateCursor.next(remaining)
        {{channel.provider_id, channel.transport}, remaining}
      end)

    assert actual == expected
  end

  test "a deferred sibling still passes final circuit admission after health changes" do
    {chain, snapshot, plan} =
      fixture([
        {"bad-a", true, [:http, :ws]},
        {"bad-b", true, [:http]},
        {"capable", true, [:http]}
      ])

    rejected = Catalog.lookup_instance_id("public", chain, "bad-a")
    key = {"public", chain, "bad-b", :http}
    [{^key, channel}] = :ets.lookup(:transport_channel_cache, key)

    action = fn ->
      CircuitBreaker.open({rejected, :ws})
      assert CircuitBreaker.get_state({rejected, :ws}).state == :open
    end

    :ets.insert(
      :transport_channel_cache,
      {key, %{channel | raw_channel: Map.put(channel.raw_channel, :on_request, action)}}
    )

    capable = Catalog.lookup_instance_id("public", chain, "capable")
    pid = GenServer.whereis(CircuitBreaker.via_name({capable, :http}))
    :sys.replace_state(pid, &%{&1 | state: :half_open})
    {:ok, breaker} = Snapshot.lookup({capable, :http})
    Snapshot.put(%{breaker | state: :half_open, half_open_inflight: 0})

    params = ["0x0000000000000000000000000000000000000001", "0x1"]

    {seed, _} =
      find_order(snapshot, plan, params, :both, fn order ->
        Enum.take(order, 2) == [{"bad-a", :http}, {"bad-a", :ws}]
      end)

    :rand.seed(:exsss, {seed, seed + 1, seed + 2})
    assert {:ok, _, ctx} = execute(chain, params, :both)
    assert ctx.execution_envelope.dispatch_count == 3
    assert ctx.execution_envelope.candidate_admission_count == 4
    assert dispatched(3) == [{"bad-a", :http}, {"bad-b", :http}, {"capable", :http}]
  end

  test "explicit recovered-head preference preserves observed transport and remaining order" do
    {chain, snapshot, plan} = fixture([{"bad-a", true, [:http, :ws]}, {"capable", true, [:http]}])
    ahead = Catalog.lookup_instance_id("public", chain, "bad-a")
    capable = Catalog.lookup_instance_id("public", chain, "capable")
    Lasso.BlockSync.Registry.put_height(chain, ahead, 100_000_000, :http)
    Lasso.BlockSync.Registry.put_height(chain, capable, 99_999_999, :http)

    {seed, _} =
      find_order(snapshot, plan, [], :both, fn order ->
        order == [{"bad-a", :ws}, {"capable", :http}, {"bad-a", :http}]
      end)

    :rand.seed(:exsss, {seed, seed + 1, seed + 2})

    cursor =
      CandidateCursor.new(snapshot, plan, "eth_getBalance",
        strategy: :load_balanced,
        attempted_instances: [ahead],
        preferred_head_height: 100_000_000
      )

    assert {:ok, %{provider_id: "bad-a", transport: :http}, cursor} = CandidateCursor.next(cursor)
    assert {:ok, %{provider_id: "bad-a", transport: :ws}, cursor} = CandidateCursor.next(cursor)
    assert {:ok, %{provider_id: "capable"}, _} = CandidateCursor.next(cursor)
  end

  defp dispatched(count) do
    Enum.map(1..count, fn _ ->
      receive do
        {:dispatched, id, transport} -> {id, transport}
      after
        100 -> flunk("missing dispatch")
      end
    end)
  end

  defp execute(chain, params, transport, override \\ nil) do
    RequestPipeline.execute_via_channels(chain, "eth_getBalance", params, %RequestOptions{
      profile: "public",
      strategy: :load_balanced,
      transport: transport,
      provider_override: override,
      failover_on_override: false,
      timeout_ms: 2_000
    })
  end

  defp find_order(snapshot, plan, params, transport, predicate) do
    Enum.find_value(1..100, fn seed ->
      :rand.seed(:exsss, {seed, seed + 1, seed + 2})

      cursor =
        CandidateCursor.new(snapshot, plan, "eth_getBalance",
          strategy: :load_balanced,
          params: params,
          transport: transport
        )

      order = Enum.map(cursor.descriptors, fn {provider, protocol} -> {provider.id, protocol} end)
      if predicate.(order), do: {seed, order}
    end) || flunk("no deterministic failing permutation")
  end

  defp fixture(specs) do
    chain = 70_000_000 + System.unique_integer([:positive])

    providers =
      Enum.map(specs, fn {id, archival, transports} ->
        %{
          id: id,
          name: id,
          priority: if(id == "capable", do: 1000, else: 1),
          url: "http://#{id}.fixture.invalid",
          ws_url: if(:ws in transports, do: "ws://#{id}.fixture.invalid", else: nil),
          archival: archival,
          capabilities: %{}
        }
      end)

    :ok =
      ConfigStore.register_chain_runtime("public", chain, %{
        chain_id: chain,
        name: "Archive study",
        providers: providers
      })

    Catalog.build_from_config()
    snapshot = Catalog.snapshot()
    {:ok, plan} = Catalog.get_routing_plan(snapshot, "public", chain)

    for provider <- plan.providers do
      id = provider.instance_id

      :ets.insert(
        :lasso_instance_state,
        {{:health_probe, id}, %{status: :healthy, http_status: :healthy, consecutive_failures: 0}}
      )

      :ets.insert(:lasso_instance_state, {{:ws_status, id}, %{status: :connected}})

      for transport <- provider.transports do
        start_supervised!(
          Supervisor.child_spec({CircuitBreaker, {{id, transport}, %{}}}, id: {id, transport})
        )

        CircuitBreaker.close({id, transport})
        assert CircuitBreaker.get_state({id, transport}).state == :closed
        Lasso.BlockSync.Registry.put_height(chain, id, 100_000_000, transport)

        channel =
          Channel.new(
            "public",
            chain,
            provider.id,
            transport,
            %{observer: self(), provider_id: provider.id, transport: transport},
            ControlledTransport,
            instance_id: id,
            route_generation: snapshot.generation,
            provider_capabilities: %{}
          )

        key = {"public", chain, provider.id, transport}
        :ets.insert(:transport_channel_cache, {key, channel})
        on_exit(fn -> :ets.delete(:transport_channel_cache, key) end)
      end

      on_exit(fn -> InstanceState.clear(id) end)
    end

    on_exit(fn ->
      Lasso.BlockSync.Registry.clear_chain(chain)
      ConfigStore.unregister_chain_runtime("public", chain)
      Catalog.build_from_config()
    end)

    {chain, snapshot, plan}
  end
end
