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

    test "#{mode}: unknown capability categories reject without allocating atoms or restarting the owner",
         ctx do
      mode = Map.fetch!(%{mode: unquote(mode)}, :mode)

      config =
        provider(ctx, "categories")
        |> Map.put(:capabilities, %{
          unsupported_categories: ["local_only"],
          error_rules: [%{code: -32001, category: "timeout"}]
        })

      assert :ok = apply_provider(ctx, mode, "public", config)
      assert {:ok, accepted} = Providers.get_provider(@chain, "categories")
      assert accepted.capabilities.unsupported_categories == [:local_only]
      assert hd(accepted.capabilities.error_rules).category == :timeout
      owner = Process.whereis(ConfigStore)
      before = snapshot()
      unknown = "unregistered-category-#{System.unique_integer([:positive])}"
      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

      for name <- [unknown, String.duplicate("x", 256)],
          caps <- [
            %{unsupported_categories: [name]},
            %{error_rules: [%{code: -32001, category: name}]}
          ] do
        result =
          if mode == :runtime do
            Providers.update_provider(@chain, "categories", %{capabilities: caps})
          else
            apply_provider(ctx, mode, "public", Map.put(config, :capabilities, caps))
          end

        assert {:error, _} = result
        assert Process.whereis(ConfigStore) == owner
        assert snapshot() == before
      end

      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
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

  test "struct and non-map patches reject without changing the configuration owner", ctx do
    assert :ok = apply_provider(ctx, :runtime, "public", provider(ctx, "patch"))
    owner = Process.whereis(ConfigStore)
    assert {:ok, provider} = Providers.get_provider(@chain, "patch")
    before = snapshot()

    for bad <- [nil, [], "invalid", %URI{}, %{provider | ws_url: nil}] do
      assert {:error, :invalid_provider_updates} = Providers.update_provider(@chain, "patch", bad)
      assert Process.whereis(ConfigStore) == owner
    end

    assert snapshot() == before
    assert_ready()
  end

  test "concurrent partial updates reject stale replacements", ctx do
    assert :ok = apply_provider(ctx, :runtime, "public", provider(ctx, "race"))
    owner = Process.whereis(ConfigStore)
    :ok = :sys.suspend(owner)
    on_exit(fn -> :sys.resume(owner) end)

    first =
      Task.async(fn ->
        Providers.update_provider(@chain, "race", %{
          request_budget: %{requests_per_second: 1, burst: 2}
        })
      end)

    wait_for_updates(owner, 1)
    second = Task.async(fn -> Providers.update_provider(@chain, "race", %{priority: 17}) end)
    wait_for_updates(owner, 2)
    :ok = :sys.resume(owner)

    assert Task.await(first, 15_000) == :ok
    assert Task.await(second, 15_000) == {:error, :provider_changed}
    assert {:ok, updated} = Providers.get_provider(@chain, "race")
    assert updated.request_budget == %{requests_per_second: 1, burst: 2}
    assert updated.priority == 100
    assert_ready()
  end

  defp wait_for_updates(owner, count, attempts \\ 1_000)
  defp wait_for_updates(_owner, _count, 0), do: flunk("updates did not reach owner")

  defp wait_for_updates(owner, count, attempts) do
    {:messages, messages} = Process.info(owner, :messages)

    queued =
      Enum.count(messages, fn
        {:"$gen_call", _, {:update_provider_runtime, _, _, _, _, _}} -> true
        _ -> false
      end)

    if queued < count do
      Process.sleep(5)
      wait_for_updates(owner, count, attempts - 1)
    end
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
