defmodule Lasso.Integration.ProviderCandidatePublicationTest do
  use ExUnit.Case, async: false

  alias Lasso.Config.ConfigStore
  alias Lasso.Operator.Commands
  alias Lasso.Providers
  alias Lasso.Test.Harness.{Fleet, Rpc}

  @moduletag :integration
  @chain 31337

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
    upstream = Fleet.start!(self(), "candidate")
    ctx = %{files: files, upstream: upstream}
    write_profile(ctx, "public", [])
    write_profile(ctx, "testnet", [])
    assert :ok = Commands.reload()

    on_exit(fn ->
      Enum.each(files, fn {_, {path, contents}} -> File.write!(path, contents) end)
      assert :ok = Commands.reload()
      Application.put_env(:lasso, :http_client, client)
      Application.put_env(:lasso, :ws_client_module, ws_client)
    end)

    ctx
  end

  for mode <- [:runtime, :yaml] do
    test "#{mode}: conflicting shared budgets reject before publication and preserve readiness",
         ctx do
      mode = Map.fetch!(%{mode: unquote(mode)}, :mode)

      first =
        provider(ctx, "first") |> Map.put(:request_budget, %{requests_per_second: 1, burst: 2})

      assert :ok = apply_provider(ctx, mode, "public", first)
      assert_ready()
      before = snapshot()
      second = %{first | id: "second", request_budget: %{requests_per_second: 2, burst: 2}}
      assert {:error, _} = apply_provider(ctx, mode, "testnet", second)
      assert snapshot() == before
      assert_ready()

      if mode == :runtime do
        assert :ok =
                 Providers.add_provider("testnet", @chain, provider(ctx, "second"), []) |> added()

        before = snapshot()

        assert {:error, _} =
                 Providers.update_provider(
                   "testnet",
                   @chain,
                   "second",
                   %{request_budget: %{requests_per_second: 3}},
                   []
                 )

        assert snapshot() == before
        assert_ready()
      end
    end

    test "#{mode}: WebSocket-only providers publish safely; removing every endpoint rejects",
         ctx do
      mode = Map.fetch!(%{mode: unquote(mode)}, :mode)
      config = provider(ctx, "ws-only") |> Map.delete(:url)
      assert :ok = apply_provider(ctx, mode, "public", config)
      assert_ready()
      assert {:ok, %{url: nil, ws_url: ws_url}} = Providers.get_provider(@chain, "ws-only")
      assert ws_url == ctx.upstream.ws_url
      before = snapshot()

      if mode == :runtime do
        assert {:error, _} = Providers.update_provider(@chain, "ws-only", %{ws_url: nil})
      else
        assert {:error, _} = apply_provider(ctx, mode, "public", Map.delete(config, :ws_url))
      end

      assert snapshot() == before
      assert_ready()
    end

    test "#{mode}: an already connected WebSocket adopts a new shared budget", ctx do
      mode = Map.fetch!(%{mode: unquote(mode)}, :mode)
      first = provider(ctx, "first")
      assert :ok = apply_provider(ctx, mode, "public", first)
      port = LassoWeb.Endpoint.config(:http)[:port]
      wire = Rpc.wire!("ws://127.0.0.1:#{port}/ws/rpc/profile/public/priority/#{@chain}")
      on_exit(fn -> if Process.alive?(wire.pid), do: GenServer.stop(wire.pid) end)
      assert ws_rpc(wire, 0)["result"]

      budgeted =
        provider(ctx, "second") |> Map.put(:request_budget, %{requests_per_second: 1, burst: 2})

      assert :ok = apply_provider(ctx, mode, "testnet", budgeted)
      assert ws_rpc(wire, 1)["result"]
      assert ws_rpc(wire, 2)["result"]
      assert ws_rpc(wire, 3)["error"]["code"] == -32005
      assert_ready()
    end
  end

  test "partial updates clear an optional transport without removing the provider", ctx do
    config = provider(ctx, "both")
    assert :ok = apply_provider(ctx, :runtime, "public", config)
    assert :ok = apply_provider(ctx, :runtime, "public", provider(ctx, "other"))
    before = snapshot()

    assert {:error, :duplicate_provider_id} =
             Providers.update_provider(@chain, "both", %{id: "other"})

    assert snapshot() == before
    assert :ok = Providers.update_provider(@chain, "both", %{ws_url: nil})
    assert {:ok, %{ws_url: nil, url: url}} = Providers.get_provider(@chain, "both")
    assert url == ctx.upstream.url
    before = snapshot()
    assert {:error, _} = Providers.update_provider(@chain, "both", %{unknown: nil})
    assert {:error, _} = Providers.update_provider(@chain, "both", %{url: nil})
    assert snapshot() == before
    assert_ready()
  end

  defp provider(ctx, id),
    do: %{
      id: id,
      url: ctx.upstream.url,
      ws_url: ctx.upstream.ws_url,
      background_observations: false,
      subscribe_new_heads: false
    }

  defp apply_provider(_ctx, :runtime, profile, config),
    do: Providers.add_provider(profile, @chain, config, []) |> added()

  defp apply_provider(ctx, :yaml, profile, config) do
    write_profile(ctx, profile, [config])
    Commands.reload()
  end

  defp added({:ok, _}), do: :ok
  defp added(error), do: error

  defp write_profile(ctx, profile, providers) do
    {path, _} = ctx.files[profile]

    File.write!(
      path,
      "---\nname: #{profile}\nslug: #{profile}\n---\n" <>
        Jason.encode!(%{chains: %{anvil: %{chain_id: @chain, providers: providers}}})
    )
  end

  defp snapshot do
    {ConfigStore.route_generation(), ConfigStore.get_profile_chains("public"),
     ConfigStore.get_profile_chains("testnet")}
  end

  defp assert_ready do
    port = LassoWeb.Endpoint.config(:http)[:port]

    assert {:ok, %{status: 200}} =
             Finch.build(:get, "http://127.0.0.1:#{port}/api/ready") |> Finch.request(Lasso.Finch)
  end

  defp ws_rpc(wire, id) do
    Rpc.send!(wire, "eth_getBalance", [], id)
    assert_receive {:rpc_frame, _, {:text, bytes}}, 3_000
    Jason.decode!(bytes)
  end
end
