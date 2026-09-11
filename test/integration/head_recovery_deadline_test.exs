defmodule Lasso.Integration.HeadRecoveryDeadlineTest do
  use Lasso.Test.LassoIntegrationCase

  alias Lasso.Config.ConfigStore
  alias Lasso.RPC.{RequestOptions, RequestPipeline, Response}

  defmodule DelayedClient do
    def request(provider, method, params, opts) do
      %{observer: observer, original: original} =
        Application.fetch_env!(:lasso, :head_recovery_deadline_fixture)

      if provider.id == "delayed-ahead" and method == "eth_getBlockByNumber" and
           not is_nil(opts[:attempt_dispatch]) do
        :ok = Lasso.Core.Transport.AttemptProtocol.send_confirmed(opts[:attempt_dispatch])
        send(observer, {:preferred_attempt, self()})

        receive do
          :respond -> original.request(provider, method, params, opts)
        after
          2_000 -> original.request(provider, method, params, opts)
        end
      else
        original.request(provider, method, params, opts)
      end
    end

    def batch_request(provider, requests, opts) do
      %{original: original} = Application.fetch_env!(:lasso, :head_recovery_deadline_fixture)
      original.batch_request(provider, requests, opts)
    end
  end

  test "stalled preferred providers retain fallback time under concurrent local load", %{
    chain: chain
  } do
    :ok = ConfigStore.register_chain_runtime("public", chain, %{head_policy: "local"})

    setup_providers([
      %{id: "healthy-behind", priority: 1, behavior: :healthy, background_observations: false},
      %{id: "delayed-ahead", priority: 2, behavior: :healthy, background_observations: false}
    ])

    for {id, height} <- [{"healthy-behind", 99}, {"delayed-ahead", 100}] do
      set_behavior(
        id,
        {:conditional,
         fn
           "eth_getBlockByNumber", _, _ -> {:ok, header(height)}
           "eth_blockNumber", _, _ -> {:ok, Lasso.JSONRPC.Quantity.encode(height)}
           "eth_chainId", _, _ -> {:ok, Lasso.JSONRPC.Quantity.encode(chain)}
           _, _, _ -> {:ok, "0x0"}
         end}
      )

      instance = Lasso.Providers.Catalog.lookup_instance_id("public", chain, id)
      Lasso.BlockSync.Registry.put_height(chain, instance, height, :http)
    end

    opts = %RequestOptions{
      profile: "public",
      strategy: :priority,
      transport: :http,
      timeout_ms: 1_000
    }

    assert {:ok, response, _} =
             RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [], opts)

    assert decode(response) == "0x63"
    :ets.insert(:lasso_recovered_heads, {{"public", chain}, 100, header(100)["hash"], 0})
    original = Application.fetch_env!(:lasso, :http_client)

    Application.put_env(:lasso, :head_recovery_deadline_fixture, %{
      observer: self(),
      original: original
    })

    Application.put_env(:lasso, :http_client, DelayedClient)

    on_exit(fn ->
      Application.put_env(:lasso, :http_client, original)
      Application.delete_env(:lasso, :head_recovery_deadline_fixture)
      :ets.delete(:lasso_accepted_heads, {"public", chain})
      :ets.delete(:lasso_recovered_heads, {"public", chain})
    end)

    tasks =
      for _ <- 1..6 do
        Task.async(fn ->
          started = System.monotonic_time(:millisecond)

          assert {:ok, response, context} =
                   RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [], opts)

          {decode(response), context, System.monotonic_time(:millisecond) - started}
        end)
      end

    attempts =
      for _ <- tasks do
        assert_receive {:preferred_attempt, pid}, 500
        {pid, Process.monitor(pid)}
      end

    refute_received {:DOWN, _, :process, _, _}

    results = Enum.map(tasks, &Task.await(&1, 1_500))

    for {result, context, elapsed} <- results do
      assert result == "0x63"
      assert context.selected_provider.id == "healthy-behind"
      assert context.execution_envelope.dispatch_count == 2
      assert context.head_policy.evidence.minimum_height == 99
      assert context.head_policy.evidence.recovery_gap_blocks == 1
      assert elapsed <= 1_100
    end

    for {pid, monitor} <- attempts do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 100
      refute Process.alive?(pid)
    end

    assert [{{"public", ^chain}, 99, _, _}] =
             :ets.lookup(:lasso_accepted_heads, {"public", chain})
  end

  defp header(height) do
    %{
      "number" => Lasso.JSONRPC.Quantity.encode(height),
      "timestamp" => Lasso.JSONRPC.Quantity.encode(System.system_time(:second)),
      "hash" => "0x" <> String.pad_leading(Integer.to_string(height, 16), 64, "0")
    }
  end

  defp set_behavior(id, behavior) do
    [{pid, _}] = Registry.lookup(Lasso.Registry, {:http_provider, id})
    :sys.replace_state(pid, &%{&1 | behavior: behavior})
  end

  defp decode(response) do
    assert {:ok, result} = Response.Success.decode_result(response)
    result
  end
end
