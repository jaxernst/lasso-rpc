defmodule Lasso.RPC.AdmissionHardeningTest do
  use Lasso.Test.LassoIntegrationCase

  alias Lasso.BlockSync.Registry, as: BlockSyncRegistry
  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.Providers.Catalog
  alias Lasso.RPC.{RequestOptions, RequestPipeline, Selection}
  alias Lasso.RPC.Selection.CandidateCursor

  @strategies [:priority, :load_balanced, :fastest, :latency_weighted]
  @wallet "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
  @usdc "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
  @balance_of "0x70a08231" <> String.pad_leading(String.trim_leading(@wallet, "0x"), 64, "0")
  @reads [
    {"eth_getBalance", [@wallet, "0x31108f1"]},
    {"eth_call", [%{"to" => @usdc, "data" => @balance_of}, "0x31108f1"]},
    {"eth_call", [%{"to" => @usdc, "data" => "0x95d89b41"}, "0x31108f1"]},
    {"eth_call", [%{"to" => @usdc, "data" => "0x313ce567"}, "0x31108f1"]},
    {"eth_call", [%{"to" => @usdc, "data" => "0x06fdde03"}, "0x31108f1"]},
    {"eth_getCode", [@usdc, "0x31108f1"]},
    {"eth_getLogs", [%{"fromBlock" => "0x31108f0", "toBlock" => "0x31108f1"}]}
  ]

  test "pinned reads reach non-archival upstreams when head age is unknown", %{chain: chain} do
    setup_non_archival()
    BlockSyncRegistry.clear_chain(chain)

    for strategy <- @strategies, {method, params} <- @reads do
      assert {:ok, _result, ctx} = execute(chain, method, params, strategy)
      assert ctx.execution_envelope.dispatch_count == 1
      assert ctx.executed_channel.provider_id in ["primary", "backup"]
    end
  end

  test "all selection entry points retain providers when head age is unknown", %{chain: chain} do
    setup_non_archival()
    BlockSyncRegistry.clear_chain(chain)

    for strategy <- @strategies, {method, params} <- @reads do
      opts = [strategy: strategy, params: params, transport: :http]
      assert length(Selection.select_channels("public", chain, method, opts)) == 2

      assert {:ok, _} =
               Selection.select_provider(
                 "public",
                 chain,
                 method,
                 Keyword.put(opts, :protocol, :http)
               )

      cursor = Selection.select_channel_candidates("public", chain, method, opts)
      assert {:ok, _, _} = CandidateCursor.next(cursor)
    end
  end

  test "known historical exclusion reports archive admission without dispatch", %{chain: chain} do
    setup_non_archival()

    for strategy <- @strategies do
      assert {:error, error, ctx} =
               execute(chain, "eth_getLogs", [%{"fromBlock" => "earliest"}], strategy)

      assert error.data.reason == :archive_required
      assert error.data.upstream_attempts == 0
      assert error.message =~ "archival support"
      refute error.retriable?
      refute error.breaker_penalty?
      refute Map.has_key?(error.data, :retry_after_ms)
      assert ctx.attempted_channels == []

      assert %{
               "jsonrpc" => "2.0",
               "id" => 27,
               "error" => %{
                 "code" => -32_000,
                 "data" => %{"reason" => "archive_required", "upstream_attempts" => 0}
               }
             } = error |> JError.to_response(27) |> Jason.encode!() |> Jason.decode!()
    end
  end

  test "known old numeric blocks still require declared archive capability", %{chain: chain} do
    setup_non_archival()
    BlockSyncRegistry.clear_chain(chain)
    put_height(chain, "primary", 51_448_049)

    for strategy <- @strategies do
      assert {:error, error, _ctx} = execute(chain, "eth_call", [%{}, "0x64"], strategy)
      assert error.data.reason == :archive_required
      assert error.data.upstream_attempts == 0
    end
  end

  test "missing transport is distinct from an upstream outage", %{chain: chain} do
    setup_non_archival()

    for strategy <- @strategies do
      assert {:error, error, _ctx} =
               RequestPipeline.execute_via_channels(
                 chain,
                 "eth_call",
                 [%{}, "latest"],
                 %RequestOptions{
                   profile: "public",
                   strategy: strategy,
                   transport: :ws,
                   timeout_ms: 2_000
                 }
               )

      assert error.data.reason == :transport_unavailable
      assert error.data.upstream_attempts == 0
      refute error.breaker_penalty?
      refute error.retriable?
    end
  end

  defp setup_non_archival do
    setup_providers([
      %{
        id: "primary",
        priority: 1,
        archival: false,
        background_observations: false,
        behavior: :healthy
      },
      %{
        id: "backup",
        priority: 2,
        archival: false,
        background_observations: false,
        behavior: :healthy
      }
    ])
  end

  defp put_height(chain, provider, height) do
    instance = Catalog.lookup_instance_id("public", chain, provider)
    BlockSyncRegistry.put_height(chain, instance, height, :ws)
  end

  defp execute(chain, method, params, strategy) do
    RequestPipeline.execute_via_channels(chain, method, params, %RequestOptions{
      profile: "public",
      strategy: strategy,
      transport: :http,
      timeout_ms: 2_000
    })
  end
end
