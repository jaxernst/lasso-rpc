defmodule Lasso.RPC.RequestPipelineGlobalPublicationTest do
  use Lasso.Test.LassoIntegrationCase
  alias Lasso.BlockPublication.{Block, Gate, Handoff, Publication}
  alias Lasso.Core.Request.ExecutionScope
  alias Lasso.Config.ConfigStore
  alias Lasso.JSONRPC.{Error, Quantity}
  alias Lasso.RPC.{RequestOptions, RequestPipeline, RequestTerminal}
  alias Lasso.RPC.Response.Success
  require Lasso.Test.Eventually

  setup %{chain: chain} = context do
    if mode = context[:policy_mode] || (context[:global_mode] && "global") do
      :ok = ConfigStore.register_chain_runtime("public", chain, %{head_policy: mode})
    end

    setup_providers([%{id: "publication-upstream", priority: 1, behavior: :healthy}])

    on_exit(fn ->
      :ets.delete(:lasso_block_publications, {"public", chain})
      :ets.delete(:lasso_accepted_heads, {"public", chain})
    end)

    :ok
  end

  test "repeated numbers and headers are local successes even when providers lag", %{chain: chain} do
    publication = publish(chain, 101)
    observer = self()

    set_behavior(
      "publication-upstream",
      {:conditional,
       fn method, params, _ ->
         send(observer, {:unexpected_upstream, method, params})
         {:ok, header(100)}
       end}
    )

    for id <- ["customer-id", 17, nil] do
      assert {:ok, response, ctx} = request(chain, "eth_blockNumber", [], id)
      assert result(response) == "0x65"
      assert response.id == id
      assert ctx.executed_channel == nil
      assert ctx.execution_envelope.dispatch_count == 0
      assert ctx.head_policy.evidence.source == "published_block"

      assert %RequestTerminal.LocalSuccess{} =
               RequestPipeline.build_request_terminal(:ok, response, ctx)
    end

    assert {:ok, response, _} = request(chain, "eth_getBlockByNumber", ["latest", false])
    assert result(response) == publication["published"]["header"]
    refute_receive {:unexpected_upstream, _, _}
  end

  test "stale local configuration cannot bypass a global grant or its closed gate", %{
    chain: chain
  } do
    s = publish(chain, 101)
    {:ok, config} = ConfigStore.get_chain("public", chain)
    assert config.head_policy == "off"
    prepare_handoff(chain, s, 102)
    assert {:error, %Error{data: %{reason: "publication_changing"}} = error, ctx} = request(chain)
    assert ctx.execution_envelope.dispatch_count == 0

    assert %RequestTerminal.LocalFailure{reason: :block_publication, dispatch_count: 0} =
             RequestPipeline.build_request_terminal(:error, error, ctx)
  end

  test "handoff wakes a block choice without delaying pinned state or dispatching a head probe",
       %{
         chain: chain
       } do
    closing = prepare_handoff(chain, publish(chain, 101), 102)
    task = Task.async(fn -> request(chain) end)
    topic = Handoff.topic({"public", chain})
    Lasso.Test.Eventually.assert_eventually(fn -> Registry.lookup(Lasso.PubSub, topic) != [] end)
    assert Task.yield(task, 0) == nil

    Handoff.notify({"public", chain}, :lasso_block_publications)
    assert {:error, :publication_changing} = Gate.read({"public", chain})
    assert Task.yield(task, 0) == nil

    set_behavior("publication-upstream", {:conditional, fn _, _, _ -> {:ok, "0x42"} end})
    selector = %{"blockHash" => hash(101), "requireCanonical" => true}

    assert {:ok, state, state_ctx} =
             request(chain, "eth_call", [%{"to" => "0x" <> String.duplicate("1", 40)}, selector])

    assert result(state) == "0x42"
    assert state_ctx.execution_envelope.dispatch_count == 1

    {:ok, committed} =
      Publication.apply(closing, {:closed, closing["epoch"], node_id(), Gate.boot()})

    Gate.install({"public", chain}, committed, node_id())
    assert {:ok, response, ctx} = Task.await(task)
    assert result(response) == "0x66"
    assert ctx.execution_envelope.dispatch_count == 0
    assert Registry.lookup(Lasso.PubSub, topic) == []
  end

  test "a handoff wait respects the existing request deadline and releases its subscription", %{
    chain: chain
  } do
    prepare_handoff(chain, publish(chain, 101), 102)

    assert {:error, %Error{category: :timeout}, ctx} =
             RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [], %RequestOptions{
               profile: "public",
               strategy: :priority,
               timeout_ms: 40
             })

    assert ctx.execution_envelope.dispatch_count == 0
    assert Registry.lookup(Lasso.PubSub, Handoff.topic({"public", chain})) == []
  end

  test "an abandoned caller cancels a waiting choice without dispatch", %{chain: chain} do
    prepare_handoff(chain, publish(chain, 101), 102)
    caller = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> Process.exit(caller, :kill) end)

    task =
      Task.async(fn ->
        RequestPipeline.execute_owned(
          ExecutionScope.monitored(self(), caller),
          chain,
          "eth_blockNumber",
          [],
          %RequestOptions{profile: "public", strategy: :priority, timeout_ms: 5_000}
        )
      end)

    topic = Handoff.topic({"public", chain})
    Lasso.Test.Eventually.assert_eventually(fn -> Registry.lookup(Lasso.PubSub, topic) != [] end)
    Process.exit(caller, :kill)
    assert {:error, %Error{category: :cancelled}, ctx} = Task.await(task, 500)
    assert ctx.execution_envelope.dispatch_count == 0
    assert Registry.lookup(Lasso.PubSub, topic) == []
  end

  defp prepare_handoff(chain, state, height) do
    {:ok, preparing} = Publication.apply(state, {:propose, node_id(), Gate.boot(), block(height)})

    {:ok, closing} =
      Publication.apply(
        preparing,
        {:ready, preparing["epoch"], node_id(), Gate.boot(),
         %{"block_hash" => hash(height), "anchor_hash" => state["published"]["hash"]}}
      )

    Gate.install({"public", chain}, closing, node_id())
    closing
  end

  test "full transaction reads keep the published hash while explicit and latest state reads keep their selectors",
       %{chain: chain} do
    publish(chain, 101)
    observer = self()

    set_behavior(
      "publication-upstream",
      {:conditional,
       fn method, params, _ ->
         send(observer, {:upstream, method, params})

         if method == "eth_getBlockByHash",
           do: {:ok, Map.put(header(101), "transactions", [%{"hash" => hash(900)}])},
           else: {:ok, "0x42"}
       end}
    )

    assert {:ok, response, ctx} = request(chain, "eth_getBlockByNumber", ["latest", true])
    assert result(response)["number"] == "0x65"
    assert ctx.executed_channel.provider_id == "publication-upstream"
    expected_hash = hash(101)
    assert_receive {:upstream, "eth_getBlockByHash", [^expected_hash, true]}

    for target <- ["latest", "0x64", %{"blockHash" => hash(100), "requireCanonical" => true}] do
      params = [%{"to" => "0x" <> String.duplicate("1", 40), "data" => "0x"}, target]
      assert {:ok, response, ctx} = request(chain, "eth_call", params)
      assert result(response) == "0x42"
      assert ctx.head_policy == nil
      assert_receive {:upstream, "eth_call", ^params}
    end
  end

  test "a full block response at another height or hash is never accepted", %{chain: chain} do
    publish(chain, 101)
    set_behavior("publication-upstream", {:conditional, fn _, _, _ -> {:ok, header(100)} end})

    assert {:error, %Error{data: %{reason: "published_block_unavailable"}} = error, ctx} =
             request(chain, "eth_getBlockByNumber", ["latest", true])

    assert ctx.execution_envelope.dispatch_count > 0

    assert %RequestTerminal.LocalFailure{reason: :block_publication} =
             terminal =
             RequestPipeline.build_request_terminal(:error, error, ctx)

    assert terminal.dispatch_count == ctx.execution_envelope.dispatch_count
  end

  test "freshness expires from the block timestamp and requests cannot renew it", %{chain: chain} do
    publish(chain, 101, System.system_time(:second) - 120)
    assert {:error, %Error{data: %{reason: "block_stale"}} = error, ctx} = request(chain)
    assert ctx.execution_envelope.dispatch_count == 0

    assert %RequestTerminal.LocalFailure{reason: :block_publication, dispatch_count: 0} =
             RequestPipeline.build_request_terminal(:error, error, ctx)
  end

  test "an in-flight unprotected response cannot escape after activation", %{chain: chain} do
    observer = self()

    set_behavior(
      "publication-upstream",
      {:conditional,
       fn _, _, _ ->
         send(observer, {:waiting, self()})

         receive do
           :release -> {:ok, "0x999"}
         after
           2_000 -> {:ok, "0x999"}
         end
       end}
    )

    task = Task.async(fn -> request(chain) end)
    assert_receive {:waiting, provider}
    publish(chain, 101)
    send(provider, :release)
    assert {:error, %Error{data: %{reason: "publication_changing"}}, _} = Task.await(task)
  end

  @tag global_mode: true
  test "system probes bypass publication while global mode without a grant fails closed", %{
    chain: chain
  } do
    assert {:error, %Error{data: %{reason: "publication_pending"}}, _} = request(chain)
    set_behavior("publication-upstream", {:conditional, fn _, _, _ -> {:ok, "0x64"} end})

    assert {:ok, response, ctx} =
             RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [], %RequestOptions{
               profile: "public",
               request_origin: :system,
               strategy: :priority,
               timeout_ms: 1_000
             })

    assert result(response) == "0x64"
    assert ctx.head_policy == nil
  end

  for mode <- ["off", "local", "global"] do
    @tag policy_mode: mode
    test "cold #{mode} enrollment blocks block choices but not explicit reads or probes", %{
      chain: chain
    } do
      :ets.insert(:lasso_block_publications, {:bootstrapped, false})

      set_behavior(
        "publication-upstream",
        {:conditional,
         fn method, _, _ ->
           if method == "eth_getBlockByNumber", do: {:ok, header(100)}, else: {:ok, "0x64"}
         end}
      )

      try do
        for {method, params} <- [
              {"eth_blockNumber", []},
              {"eth_getBlockByNumber", ["latest", false]},
              {"eth_getBlockByNumber", ["latest", true]}
            ] do
          assert {:error, %Error{data: %{reason: "publication_bootstrapping"}} = error, ctx} =
                   request(chain, method, params)

          assert %RequestTerminal.LocalFailure{reason: :block_publication, dispatch_count: 0} =
                   RequestPipeline.build_request_terminal(:error, error, ctx)
        end

        assert {:ok, response, _} = request(chain, "eth_getBlockByNumber", ["0x64", false])
        assert result(response)["number"] == "0x64"

        assert {:ok, response, _} =
                 RequestPipeline.execute_via_channels(
                   chain,
                   "eth_blockNumber",
                   [],
                   %RequestOptions{
                     profile: "public",
                     request_origin: :system,
                     strategy: :priority,
                     timeout_ms: 1_000
                   }
                 )

        assert result(response) == "0x64"
      after
        Gate.bootstrapped()
      end
    end
  end

  for mode <- ["off", "local"] do
    @tag policy_mode: mode
    test "Core #{mode} choices await recovery of possible retained global history", %{
      chain: chain
    } do
      :ets.insert(:lasso_block_publications, {:bootstrapped, false})

      try do
        assert {:error, %Error{data: %{reason: "publication_bootstrapping"}}, ctx} =
                 request(chain)

        assert ctx.execution_envelope.dispatch_count == 0
      after
        Gate.bootstrapped()
      end
    end
  end

  defp publish(chain, height, timestamp \\ System.system_time(:second)) do
    b = block(height) |> Map.put("timestamp_ms", timestamp * 1_000)
    b = put_in(b, ["header", "timestamp"], Quantity.encode(timestamp))

    {:ok, s} =
      Publication.new([node_id()], 60_000)
      |> Publication.apply({:join, node_id(), Gate.boot(), nil})

    {:ok, s} = Publication.apply(s, {:propose, node_id(), Gate.boot(), b})

    {:ok, s} =
      Publication.apply(
        s,
        {:ready, s["epoch"], node_id(), Gate.boot(),
         %{"block_hash" => hash(height), "anchor_hash" => nil}}
      )

    Gate.install({"public", chain}, s, node_id())
    {:ok, s} = Publication.apply(s, {:closed, s["epoch"], node_id(), Gate.boot()})
    Gate.install({"public", chain}, s, node_id())
    s
  end

  defp request(chain, method \\ "eth_blockNumber", params \\ [], id \\ "customer-id"),
    do:
      RequestPipeline.execute_via_channels(chain, method, params, %RequestOptions{
        profile: "public",
        strategy: :priority,
        transport: :http,
        timeout_ms: 2_000,
        jsonrpc_id: id,
        jsonrpc_id_present?: true
      })

  defp result(response) do
    {:ok, result} = Success.decode_result(response)
    result
  end

  test "cached responses retain request validation", %{chain: chain} do
    publish(chain, 101)

    assert {:error, %Error{category: :invalid_params}, ctx} =
             request(chain, "eth_blockNumber", [], %{"bad" => "id"})

    assert ctx.execution_envelope.dispatch_count == 0
  end

  defp node_id, do: Lasso.Cluster.Topology.self_node_id()

  defp set_behavior(id, behavior) do
    [{pid, _}] = Registry.lookup(Lasso.Registry, {:http_provider, id})
    :sys.replace_state(pid, &%{&1 | behavior: behavior})
  end

  defp hash(n),
    do: ("0x" <> String.pad_leading(Integer.to_string(n, 16), 64, "0")) |> String.downcase()

  defp header(n),
    do: %{
      "number" => Quantity.encode(n),
      "hash" => hash(n),
      "parentHash" => hash(n - 1),
      "timestamp" => Quantity.encode(System.system_time(:second)),
      "transactions" => []
    }

  defp block(n) do
    {:ok, block} = Block.decode(header(n), System.system_time(:millisecond), 60_000)
    block
  end
end
