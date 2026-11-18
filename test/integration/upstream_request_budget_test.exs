defmodule Lasso.UpstreamRequestBudgetTest do
  use ExUnit.Case, async: false

  alias Lasso.Operator.Commands
  alias Lasso.Test.Harness.Fleet

  @moduletag :integration

  setup do
    directory = Application.fetch_env!(:lasso, :backend_config)[:config][:profiles_dir]

    files =
      Map.new(["public", "testnet"], fn profile ->
        path = Path.join(directory, profile <> ".yml")
        {profile, {path, File.read!(path)}}
      end)

    client = Application.fetch_env!(:lasso, :http_client)
    ws_client = Application.fetch_env!(:lasso, :ws_client_module)
    Application.put_env(:lasso, :http_client, Lasso.RPC.Transport.HTTP.Client.Finch)
    Application.put_env(:lasso, :ws_client_module, Lasso.RPC.Transport.WebSocket.Client)
    limited = Fleet.start!(self(), "metered")
    unlimited = Fleet.start!(self(), "unlimited")
    observer = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler,
        [
          [:lasso, :upstream_admission, :accepted],
          [:lasso, :upstream_admission, :rejected],
          [:lasso, :circuit_breaker, :open]
        ],
        fn event, measurements, metadata, pid ->
          send(pid, {:event, event, measurements, metadata})
        end,
        observer
      )

    on_exit(fn ->
      Enum.each(files, fn {_profile, {path, contents}} -> File.write!(path, contents) end)
      assert :ok = Commands.reload()
      :telemetry.detach(handler)
      Application.put_env(:lasso, :http_client, client)
      Application.put_env(:lasso, :ws_client_module, ws_client)
    end)

    {:ok, files: files, limited: limited, unlimited: unlimited}
  end

  test "shared profile budget caps client and background work, falls back neutrally, and preserves unlimited traffic",
       ctx do
    started = System.monotonic_time(:millisecond)
    publish(ctx, %{requests_per_second: 1, burst: 20}, true)

    assert_receive {:event, [:lasso, :upstream_admission, :accepted], _,
                    %{reason: :upstream_request_budget}},
                   2_500

    responses =
      1..60
      |> Task.async_stream(
        fn n ->
          rpc(if(rem(n, 2) == 0, do: "public", else: "testnet"), "eth_getBalance")
        end,
        max_concurrency: 12,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, body} -> body end)

    assert Enum.all?(responses, &Map.has_key?(&1, "result"))
    assert Enum.any?(responses, &(&1["lasso_meta"]["selected_provider"]["id"] == "unlimited"))
    assert Enum.any?(responses, &(&1["lasso_meta"]["budget_refusals"] != []))

    discard_budget_refusals()
    # With client work finished, subsequent budget refusals come from periodic observations.
    assert_receive {:event, [:lasso, :upstream_admission, :rejected], _,
                    %{reason: :upstream_request_budget} = metadata},
                   2_500

    refute Map.has_key?(metadata, :request_origin)

    elapsed = System.monotonic_time(:millisecond) - started
    calls = rpc_calls(ctx.limited)
    assert length(calls) <= 20 + div(elapsed, 1_000)
    assert Enum.any?(calls, &(&1.request["method"] in ["eth_chainId", "eth_blockNumber"]))
    refute_receive {:event, [:lasso, :circuit_breaker, :open], _, _}, 20

    # Provider overrides leave only the metered route eligible.
    bodies = for _ <- 1..5, do: rpc("testnet", "eth_getBalance", "provider/metered/")
    error = Enum.find(bodies, &Map.has_key?(&1, "error"))
    assert error["error"]["code"] == -32005
    assert error["error"]["data"]["reason"] == "upstream_request_budget_exhausted"
    assert error["error"]["data"]["retry_after_ms"] > 0
    assert error["lasso_meta"]["circuit_breaker_state"] == "closed"

    before = length(rpc_calls(ctx.unlimited))

    for _ <- 1..25 do
      assert %{"result" => _, "lasso_meta" => %{"budget_refusals" => []}} =
               rpc("public", "eth_getBalance", "provider/unlimited/")
    end

    assert length(rpc_calls(ctx.unlimited)) == before + 25

    # An unchanged reload cannot grant another burst; an omitted reference inherits.
    assert :ok = Commands.reload()
    assert rpc("public", "eth_getBalance", "provider/metered/")["error"]["code"] == -32005

    publish(ctx, %{requests_per_second: 1, burst: 2}, false)
    assert rpc("public", "eth_getBalance", "provider/metered/")["result"]
    assert rpc("testnet", "eth_getBalance", "provider/metered/")["result"]
    assert rpc("public", "eth_getBalance", "provider/metered/")["error"]["code"] == -32005
  end

  test "WebSocket requests and subscriptions share the HTTP bucket; conflicting file budgets reject reload",
       ctx do
    started = System.monotonic_time(:millisecond)
    publish(ctx, %{requests_per_second: 1, burst: 6}, false, true)
    # Background identity/connection establishment may consume part of the burst.
    port = LassoWeb.Endpoint.config(:http)[:port]

    wire =
      Lasso.Test.Harness.Rpc.wire!("ws://127.0.0.1:#{port}/ws/rpc/profile/public/priority/31337")

    on_exit(fn -> if Process.alive?(wire.pid), do: GenServer.stop(wire.pid) end)
    Lasso.Test.Harness.Rpc.send!(wire, "eth_subscribe", ["newHeads"], 99)
    assert_receive {:rpc_frame, _, {:text, subscription}}, 3_000
    assert Jason.decode!(subscription)["result"]
    for id <- 1..12, do: Lasso.Test.Harness.Rpc.send!(wire, "eth_getBalance", [], id)

    for _ <- 1..12 do
      assert_receive {:rpc_frame, _, {:text, bytes}}, 3_000
      assert Jason.decode!(bytes)["result"] || Jason.decode!(bytes)["error"]
    end

    calls = rpc_calls(ctx.limited)
    assert Enum.any?(calls, &(&1.transport == :ws and &1.request["method"] == "eth_subscribe"))
    assert length(calls) <= 6 + div(System.monotonic_time(:millisecond) - started, 1_000)
    assert rpc("testnet", "eth_getBalance", "provider/metered/")["error"]["code"] == -32005

    write_profile(ctx, "testnet", %{requests_per_second: 2}, false, true)
    assert {:error, _} = Commands.reload()
    assert rpc("public", "eth_getBalance", "provider/metered/")["error"]["code"] == -32005
  end

  defp discard_budget_refusals do
    receive do
      {:event, [:lasso, :upstream_admission, :rejected], _, %{reason: :upstream_request_budget}} ->
        discard_budget_refusals()
    after
      0 -> :ok
    end
  end

  defp rpc(profile, method, route \\ "priority/") do
    port = LassoWeb.Endpoint.config(:http)[:port]

    {:ok, response} =
      Finch.build(
        :post,
        "http://127.0.0.1:#{port}/rpc/profile/#{profile}/#{route}31337?include_meta=body",
        [{"content-type", "application/json"}],
        Jason.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: []})
      )
      |> Finch.request(Lasso.Finch, receive_timeout: 5_000)

    Jason.decode!(response.body)
  end

  defp rpc_calls(fleet), do: Enum.filter(Fleet.drain(fleet), &Map.has_key?(&1, :request))

  defp publish(ctx, budget, observations, ws \\ false) do
    write_profile(ctx, "public", budget, observations, ws)
    write_profile(ctx, "testnet", nil, observations, ws)
    assert :ok = Commands.reload()
  end

  defp write_profile(ctx, profile, budget, observations, ws) do
    providers = [
      %{
        id: "metered",
        url: ctx.limited.url,
        priority: 1,
        background_observations: observations,
        subscribe_new_heads: ws
      }
      |> maybe_put(:request_budget, budget)
      |> maybe_put(:ws_url, if(ws, do: ctx.limited.ws_url)),
      %{
        id: "unlimited",
        url: ctx.unlimited.url,
        priority: 2,
        background_observations: false,
        subscribe_new_heads: false
      }
    ]

    config = %{
      chains: %{
        anvil: %{
          chain_id: 31337,
          providers: providers,
          monitoring: %{http_heads_interval_ms: 1_000, chain_identity_interval_ms: 1_000}
        }
      }
    }

    {path, _} = ctx.files[profile]
    File.write!(path, "---\nname: #{profile}\nslug: #{profile}\n---\n" <> Jason.encode!(config))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
