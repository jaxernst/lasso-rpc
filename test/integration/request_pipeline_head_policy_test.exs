defmodule Lasso.RPC.RequestPipelineHeadPolicyTest do
  use Lasso.Test.LassoIntegrationCase

  alias Lasso.Config.ConfigStore
  alias Lasso.JSONRPC.{Error, Quantity}
  alias Lasso.RPC.{Observability, RequestOptions, RequestPipeline, Response}

  setup %{chain: chain} do
    :ok = ConfigStore.register_chain_runtime("public", chain, %{head_policy: "local"})
    on_exit(fn -> :ets.delete(:lasso_accepted_heads, {"public", chain}) end)
    :ok
  end

  test "head acquisitions advance, repeat, and preserve ordinary JSON-RPC IDs", %{chain: chain} do
    setup_providers([%{id: "head", priority: 1, behavior: :healthy}])
    serve("head", header(100))
    assert {:ok, response, ctx} = request(chain)
    assert result(response) == "0x64"
    assert response.id == "client-id"
    assert ctx.head_policy.evidence.scope == "profile_chain_instance"
    assert Observability.build_client_metadata(ctx).head_policy.block_hash == header(100)["hash"]
    assert {:ok, response, _} = request(chain)
    assert result(response) == "0x64"

    serve("head", header(101))
    assert {:ok, response, _} = request(chain)
    assert result(response) == "0x65"
    assert_received {:head_request, "head", ["latest", false]}
  end

  test "a lagging latest triggers an optimistic exact-block attempt on another provider", %{
    chain: chain
  } do
    setup_providers([
      %{id: "head-a", priority: 1, behavior: :healthy},
      %{id: "head-b", priority: 2, behavior: :healthy}
    ])

    serve("head-a", header(100))
    assert {:ok, response, _} = request(chain)
    assert result(response) == "0x64"
    assert_receive {:head_request, "head-a", ["latest", false]}
    serve("head-a", header(99))
    serve("head-b", header(100))

    assert {:ok, response, ctx} = request(chain)
    assert result(response) == "0x64"
    assert ctx.execution_envelope.dispatch_count == 2
    assert_receive {:head_request, "head-a", ["latest", false]}
    assert_receive {:head_request, "head-b", ["0x64", false]}
  end

  test "unavailable providers cannot lower the floor and consume only the existing budget", %{
    chain: chain
  } do
    setup_providers(for n <- 1..4, do: %{id: "head-#{n}", priority: n, behavior: :healthy})
    serve("head-1", header(100))
    assert {:ok, response, _} = request(chain)
    result(response)
    assert_receive {:head_request, "head-1", ["latest", false]}
    for n <- 1..4, do: serve("head-#{n}", header(99))

    assert {:error, %Error{category: :block_not_available, data: data}, ctx} = request(chain)
    assert data.minimum_height == 100
    assert ctx.execution_envelope.dispatch_count == 3
    assert_receive {:head_request, "head-1", ["latest", false]}
    assert_receive {:head_request, "head-2", ["0x64", false]}
    assert_receive {:head_request, "head-3", ["0x64", false]}
    refute_receive {:head_request, "head-4", _}
  end

  test "stale, null, malformed and future headers fail closed", %{chain: chain} do
    setup_providers([%{id: "head", priority: 1, behavior: :healthy}])

    for invalid <- [
          nil,
          %{},
          header(100, timestamp: System.system_time(:second) - 120),
          header(100, timestamp: System.system_time(:second) + 120),
          Map.put(header(100), "hash", "0xabc")
        ] do
      serve("head", invalid)
      assert {:error, %Error{category: :block_not_available}, _} = request(chain)
    end
  end

  test "a different hash at the accepted height fails without silently resetting the floor", %{
    chain: chain
  } do
    setup_providers([%{id: "head", priority: 1, behavior: :healthy}])
    serve("head", header(100))
    assert {:ok, response, _} = request(chain)
    result(response)
    serve("head", Map.put(header(100), "hash", header(101)["hash"]))
    assert {:error, %Error{data: %{reason: "block_hash_changed"}}, _} = request(chain)
  end

  test "latest headers preserve full-transaction requests and explicit historic reads bypass the floor",
       %{chain: chain} do
    setup_providers([%{id: "head", priority: 1, behavior: :healthy}])
    full = Map.put(header(100), "transactions", [%{"hash" => "0xtransaction"}])
    serve("head", full)
    assert {:ok, response, ctx} = request(chain, "eth_getBlockByNumber", ["latest", true])
    assert result(response) == full
    assert ctx.head_policy.evidence.block_number == "0x64"
    assert_receive {:head_request, "head", ["latest", true]}

    serve("head", header(90))
    assert {:ok, response, ctx} = request(chain, "eth_getBlockByNumber", ["0x5a", false])
    assert result(response)["number"] == "0x5a"
    assert ctx.head_policy == nil
    assert_receive {:head_request, "head", ["0x5a", false]}
  end

  test "dependent eth_call parameters are preserved across provider failover", %{chain: chain} do
    setup_providers([
      %{id: "head-a", priority: 1, behavior: :healthy},
      %{id: "head-b", priority: 2, behavior: :healthy}
    ])

    serve("head-a", header(100))
    assert {:ok, response, _} = request(chain)
    block = result(response)
    params = [%{"to" => "0x0000000000000000000000000000000000000001", "data" => "0x"}, block]
    observer = self()

    for {id, reply} <- [
          {"head-a",
           {:error,
            Error.new(-32001, "missing block",
              category: :block_not_available,
              retriable?: true,
              breaker_penalty?: false
            )}},
          {"head-b", {:ok, "0x1234"}}
        ] do
      set_behavior(
        id,
        {:conditional,
         fn method, actual, _ ->
           send(observer, {id, method, actual})
           reply
         end}
      )
    end

    assert {:ok, response, ctx} = request(chain, "eth_call", params)
    assert result(response) == "0x1234"
    assert ctx.head_policy == nil
    assert_receive {"head-a", "eth_call", ^params}
    assert_receive {"head-b", "eth_call", ^params}
  end

  test "disabled policy preserves the original head RPC", %{chain: chain} do
    {:ok, config} = ConfigStore.get_chain("public", chain)
    :ok = ConfigStore.unregister_chain_runtime("public", chain)
    :ok = ConfigStore.register_chain_runtime("public", chain, %{config | head_policy: "off"})
    setup_providers([%{id: "head", priority: 1, behavior: :healthy}])
    observer = self()

    set_behavior(
      "head",
      {:conditional,
       fn method, params, _ ->
         send(observer, {method, params})
         {:ok, "0x63"}
       end}
    )

    assert {:ok, response, ctx} = request(chain)
    assert result(response) == "0x63"
    assert ctx.head_policy == nil
    assert_receive {"eth_blockNumber", []}
  end

  test "a slower concurrent acquisition cannot commit below a completed acquisition", %{
    chain: chain
  } do
    setup_providers([
      %{id: "slow-head", priority: 1, behavior: :healthy},
      %{id: "fast-head", priority: 2, behavior: :healthy}
    ])

    observer = self()

    set_behavior(
      "slow-head",
      {:conditional,
       fn _method, _params, _ ->
         send(observer, {:blocked_head, self()})

         receive do
           :release_head -> {:ok, header(100)}
         after
           2_000 -> {:ok, header(100)}
         end
       end}
    )

    serve("fast-head", header(101))

    slow =
      Task.async(fn ->
        RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [], %RequestOptions{
          profile: "public",
          strategy: :priority,
          transport: :http,
          provider_override: "slow-head",
          timeout_ms: 1_000
        })
      end)

    assert_receive {:blocked_head, provider}

    assert {:ok, response, _} =
             RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [], %RequestOptions{
               profile: "public",
               strategy: :priority,
               transport: :http,
               provider_override: "fast-head",
               timeout_ms: 1_000
             })

    assert result(response) == "0x65"
    send(provider, :release_head)
    assert {:error, %Error{data: %{reason: "head_regression"}}, _} = Task.await(slow)
  end

  defp request(chain, method \\ "eth_blockNumber", params \\ []) do
    RequestPipeline.execute_via_channels(chain, method, params, %RequestOptions{
      profile: "public",
      strategy: :priority,
      transport: :http,
      timeout_ms: 1_000,
      jsonrpc_id: "client-id",
      jsonrpc_id_present?: true
    })
  end

  defp header(height, opts \\ []) do
    %{
      "number" => Quantity.encode(height),
      "timestamp" => Quantity.encode(Keyword.get(opts, :timestamp, System.system_time(:second))),
      "hash" => "0x" <> String.pad_leading(Integer.to_string(height, 16), 64, "0")
    }
  end

  defp serve(id, header) do
    observer = self()

    set_behavior(
      id,
      {:conditional,
       fn method, params, _ ->
         if method == "eth_getBlockByNumber" do
           send(observer, {:head_request, id, params})
           {:ok, header}
         else
           Lasso.Testing.MockProviderBehavior.execute_behavior(:healthy, method, params, %{})
         end
       end}
    )
  end

  defp set_behavior(id, behavior) do
    [{pid, _}] = Registry.lookup(Lasso.Registry, {:http_provider, id})
    :sys.replace_state(pid, &%{&1 | behavior: behavior})
  end

  defp result(response) do
    assert {:ok, value} = Response.Success.decode_result(response)
    value
  end
end
