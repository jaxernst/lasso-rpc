defmodule Lasso.Config.ObservationPolicyReloadTest do
  use ExUnit.Case, async: false

  alias Lasso.BlockSync.Worker
  alias Lasso.Config.Backend.File, as: FileBackend
  alias Lasso.Config.ConfigStore
  alias Lasso.Providers.{Catalog, ProbeCoordinator}

  @moduletag :integration

  defmodule Upstream do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      request = Jason.decode!(body)

      result =
        case request["method"] do
          "eth_chainId" ->
            Agent.update(opts[:polls], &Map.update!(&1, :identity, fn n -> n + 1 end))
            "0x" <> Integer.to_string(opts[:chain_id], 16)

          "eth_blockNumber" ->
            Agent.update(opts[:polls], &Map.update!(&1, :heads, fn n -> n + 1 end))
            "0x64"

          _ ->
            "0x0"
        end

      send_resp(
        conn,
        200,
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
      )
    end
  end

  test "file-profile reload starts and stops physical head polling with observation demand" do
    chain_id = 730_000_000 + rem(System.unique_integer([:positive]), 100_000_000)
    slug = "observation-reload-#{chain_id}"
    other_slug = "observation-other-#{chain_id}"
    root = Path.join(System.tmp_dir!(), slug)
    File.mkdir_p!(root)

    File.write!(
      Path.join(root, "public.yml"),
      "---\nname: Public\nslug: public\n---\nchains: {}\n"
    )

    polls = start_supervised!({Agent, fn -> %{heads: 0, identity: 0} end})
    ref = {:observation_reload, chain_id}
    {:ok, _} = Plug.Cowboy.http(Upstream, [chain_id: chain_id, polls: polls], ref: ref, port: 0)
    url = "http://127.0.0.1:#{:ranch.get_port(ref)}"

    original_state = :sys.get_state(ConfigStore)
    original_client = Application.get_env(:lasso, :http_client)

    on_exit(fn ->
      :sys.replace_state(ConfigStore, fn _ -> original_state end)
      ConfigStore.reload()
      Application.put_env(:lasso, :http_client, original_client)
      Plug.Cowboy.shutdown(ref)
      File.rm_rf!(root)
    end)

    {:ok, backend_state} =
      FileBackend.init(profiles_dir: root, legacy_config_path: root <> "/absent")

    :sys.replace_state(ConfigStore, fn state ->
      %{state | backend_module: FileBackend, backend_state: backend_state}
    end)

    Application.put_env(:lasso, :http_client, Lasso.RPC.Transport.HTTP.Client.Finch)
    write_profile(root, slug, chain_id, url, false)
    assert :ok = ConfigStore.reload()
    instance_id = Catalog.lookup_instance_id(slug, chain_id, "rpc")
    assert is_binary(instance_id)

    Lasso.Test.Eventually.assert_eventually(fn ->
      match?({:ok, %{mode: :standby, http_status: nil}}, Worker.get_status(chain_id, instance_id))
    end)

    probe = GenServer.whereis(ProbeCoordinator.via_name(chain_id))
    assert is_pid(probe)

    Lasso.Test.Eventually.assert_eventually(fn ->
      Map.has_key?(:sys.get_state(probe).instances, instance_id)
    end)

    send(probe, :tick)
    Process.sleep(300)
    assert Agent.get(polls, & &1) == %{heads: 0, identity: 0}

    write_profile(root, slug, chain_id, url, true, 1_000, nil, 1_000)
    assert :ok = ConfigStore.reload()

    Lasso.Test.Eventually.assert_eventually(fn ->
      match?(
        {:ok, %{mode: :http_only, config: %{poll_interval_ms: 1_000}}},
        Worker.get_status(chain_id, instance_id)
      )
    end)

    Lasso.Test.Eventually.assert_eventually(fn -> Agent.get(polls, & &1.heads) > 0 end)
    Lasso.Test.Eventually.assert_eventually(fn -> Agent.get(polls, & &1.identity) > 0 end)

    write_profile(root, other_slug, chain_id, url, true, 5_000, 2_000)
    assert :ok = ConfigStore.reload()
    assert Catalog.lookup_instance_id(other_slug, chain_id, "rpc") == instance_id

    assert {:ok, %{config: %{poll_interval_ms: 1_000}}} =
             Worker.get_status(chain_id, instance_id)

    write_profile(root, slug, chain_id, url, false, 1_000, nil, 1_000)
    assert :ok = ConfigStore.reload()

    Lasso.Test.Eventually.assert_eventually(fn ->
      match?(
        {:ok, %{mode: :http_only, config: %{poll_interval_ms: 2_000}}},
        Worker.get_status(chain_id, instance_id)
      )
    end)

    write_profile(root, other_slug, chain_id, url, true, 5_000, 1)
    assert {:error, _reason} = ConfigStore.reload()
    assert {:ok, %{config: %{poll_interval_ms: 2_000}}} = Worker.get_status(chain_id, instance_id)

    write_profile(root, other_slug, chain_id, url, false, 5_000, 2_000)
    assert :ok = ConfigStore.reload()

    Lasso.Test.Eventually.assert_eventually(fn ->
      match?({:ok, %{mode: :standby, http_status: nil}}, Worker.get_status(chain_id, instance_id))
    end)

    stopped_count = Agent.get(polls, & &1)
    Process.sleep(2_200)
    assert Agent.get(polls, & &1) == stopped_count
  end

  defp write_profile(
         root,
         slug,
         chain_id,
         url,
         enabled?,
         interval_ms \\ 1_000,
         override_ms \\ nil,
         identity_ms \\ 0
       ) do
    provider_override =
      if override_ms,
        do: "        observation_overrides:\n          http_heads_interval_ms: #{override_ms}\n",
        else: ""

    File.write!(Path.join(root, "#{slug}.yml"), """
    ---
    name: Observation Reload
    slug: #{slug}
    ---
    chains:
      test:
        chain_id: #{chain_id}
        monitoring:
          background_observations: #{enabled?}
          http_heads_interval_ms: #{interval_ms}
          http_backup_interval_ms: 3000
          chain_identity_interval_ms: #{identity_ms}
          evidence_freshness_ms: 5000
        websocket:
          subscribe_new_heads: false
        providers:
          - id: rpc
            url: #{url}
    #{provider_override}
    """)
  end
end
