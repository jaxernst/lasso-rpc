defmodule Lasso.RPC.HeadEvidenceReloadTest do
  use ExUnit.Case, async: false

  alias Lasso.BlockSync.Registry
  alias Lasso.Config.Backend.File, as: FileBackend
  alias Lasso.Config.ConfigStore
  alias Lasso.Observations.HeadSnapshot
  alias Lasso.Providers.{Catalog, HeadEvidence}
  alias Lasso.RPC.{RequestOptions, RequestPipeline}
  alias LassoWeb.Dashboard.StatusHelpers

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
            "0x" <> Integer.to_string(opts[:chain_id], 16)

          "eth_blockNumber" ->
            height = Agent.get(opts[:heights], &Map.fetch!(&1, opts[:result]))
            "0x" <> Integer.to_string(height, 16)

          _ ->
            opts[:result]
        end

      send_resp(
        conn,
        200,
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
      )
    end
  end

  test "file reload recovers routing without mixing another profile's head evidence" do
    chain_id = 700_000_000 + rem(System.unique_integer([:positive]), 100_000_000)
    slug = "head-reload-#{chain_id}"
    other_slug = "head-other-#{chain_id}"
    root = Path.join(System.tmp_dir!(), slug)
    File.mkdir_p!(root)

    File.write!(
      Path.join(root, "public.yml"),
      "---\nname: Public\nslug: public\n---\nchains: {}\n"
    )

    heights =
      start_supervised!(
        {Agent,
         fn ->
           %{
             "behind" => 90,
             "peer-a" => 100,
             "peer-b" => 100,
             "other-a" => 200,
             "other-b" => 200
           }
         end}
      )

    endpoints =
      Map.new(["behind", "peer-a", "peer-b", "other-a", "other-b"], fn provider ->
        ref = {:head_reload, provider, chain_id}

        {:ok, _} =
          Plug.Cowboy.http(
            Upstream,
            [
              chain_id: chain_id,
              heights: heights,
              result: provider
            ],
            ref: ref,
            port: 0
          )

        {provider, {ref, :ranch.get_port(ref)}}
      end)

    original_state = :sys.get_state(ConfigStore)
    original_client = Application.get_env(:lasso, :http_client)

    on_exit(fn ->
      :sys.replace_state(ConfigStore, fn _ -> original_state end)
      ConfigStore.reload()
      Registry.clear_chain(chain_id)
      Application.put_env(:lasso, :http_client, original_client)
      Enum.each(endpoints, fn {_provider, {ref, _port}} -> Plug.Cowboy.shutdown(ref) end)
      File.rm_rf!(root)
    end)

    {:ok, backend_state} =
      FileBackend.init(profiles_dir: root, legacy_config_path: root <> "/absent")

    :sys.replace_state(ConfigStore, fn state ->
      %{state | backend_module: FileBackend, backend_state: backend_state}
    end)

    Application.put_env(:lasso, :http_client, Lasso.RPC.Transport.HTTP.Client.Finch)
    write_profile(root, slug, chain_id, endpoints, ["behind", "peer-a", "peer-b"])
    write_profile(root, other_slug, chain_id, endpoints, ["other-a", "other-b"])
    assert :ok = ConfigStore.reload()

    ids =
      Map.new(
        ["behind", "peer-a", "peer-b"],
        &{&1, Catalog.lookup_instance_id(slug, chain_id, &1)}
      )

    assert Enum.all?(ids, fn {_provider, id} -> is_binary(id) end)
    assert {:ok, initial_snapshot} = HeadEvidence.snapshot(slug, chain_id)

    for peer <- ["peer-a", "peer-b"] do
      assert :ok = Registry.put_height(chain_id, ids[peer], 100, :ws)
    end

    assert :ok = Registry.put_height(chain_id, ids["behind"], 90, :ws)
    assert cached_snapshot(initial_snapshot).reference_height == 100
    assert {:ok, snapshot} = HeadEvidence.snapshot(slug, chain_id)
    assert snapshot.qualification == :qualified
    assert_cached(snapshot)
    assert {:ok, reference} = HeadSnapshot.reference(snapshot)

    Lasso.Test.Eventually.assert_eventually(fn ->
      match?(
        {:ok, %{height: 90, poll_references: [_ | _]}},
        Registry.get_observation(chain_id, ids["behind"], :http)
      )
    end)

    assert {:ok, %{poll_references: [%{scope_id: scope_id} | _]}} =
             Registry.get_observation(chain_id, ids["behind"], :http)

    assert scope_id == reference.scope_id

    other_ids =
      Map.new(["other-a", "other-b"], &{&1, Catalog.lookup_instance_id(other_slug, chain_id, &1)})

    Lasso.Test.Eventually.assert_eventually(fn ->
      Enum.all?(other_ids, fn {_provider, id} ->
        match?({:ok, %{height: 200}}, Registry.get_observation(chain_id, id, :http))
      end)
    end)

    assert {:ok, other_snapshot} = HeadEvidence.snapshot(other_slug, chain_id)
    assert other_snapshot.qualification == :qualified
    assert other_snapshot.reference_height == 200
    refute other_snapshot.scope_id == snapshot.scope_id
    assert_cached(other_snapshot)

    assert {:ok, %{qualification: :qualified, reference_height: 100}} =
             HeadEvidence.snapshot(slug, chain_id)

    Lasso.Test.Eventually.assert_eventually(fn ->
      StatusHelpers.check_block_lag(chain_id, other_ids["other-a"], other_slug) == :synced
    end)

    assert StatusHelpers.check_block_lag(chain_id, other_ids["other-a"], slug) == :unavailable
    assert_routed_to(other_slug, chain_id, "other-a")

    assert StatusHelpers.check_block_lag(chain_id, ids["behind"], slug) == :lagging
    assert_routed_to(slug, chain_id, "peer-a")

    generation = ConfigStore.route_generation()
    write_profile(root, slug, chain_id, endpoints, ["behind"])
    assert :ok = ConfigStore.reload()
    assert ConfigStore.route_generation() > generation
    assert Catalog.lookup_instance_id(slug, chain_id, "peer-a") == nil
    assert Catalog.lookup_instance_id(slug, chain_id, "peer-b") == nil
    assert Registry.get_observations(chain_id, ids["peer-a"]) == []
    assert Registry.get_observations(chain_id, ids["peer-b"]) == []

    assert {:ok, alone} = HeadEvidence.snapshot(slug, chain_id)
    assert alone.qualification != :qualified
    assert alone.revision > snapshot.revision
    assert_cached(alone)
    assert StatusHelpers.check_block_lag(chain_id, ids["behind"], slug) == :unavailable
    assert_routed_to(slug, chain_id, "behind")

    assert {:ok, %{qualification: :qualified, reference_height: 200}} =
             HeadEvidence.snapshot(other_slug, chain_id)

    assert_routed_to(other_slug, chain_id, "other-a")

    write_profile(root, slug, chain_id, endpoints, ["behind", "peer-a", "peer-b"])
    assert :ok = ConfigStore.reload()

    for provider <- ["behind", "peer-a", "peer-b"] do
      instance_id = Catalog.lookup_instance_id(slug, chain_id, provider)
      assert is_binary(instance_id)
      assert :ok = Registry.put_height(chain_id, instance_id, 100, :ws)
    end

    assert {:ok, recovered} = HeadEvidence.snapshot(slug, chain_id)
    assert recovered.qualification == :qualified
    assert recovered.reference_height == 100
    assert recovered.revision > alone.revision
    assert_cached(recovered)
    Agent.update(heights, &Map.put(&1, "behind", 100))

    Lasso.Test.Eventually.assert_eventually(fn ->
      match?({:ok, %{height: 100}}, Registry.get_observation(chain_id, ids["behind"], :http))
    end)

    assert StatusHelpers.check_block_lag(chain_id, ids["behind"], slug) == :synced
    assert_routed_to(slug, chain_id, "behind")
  end

  defp assert_cached(%HeadSnapshot{scope_id: scope_id} = snapshot) do
    cached = cached_snapshot(snapshot)
    assert cached.scope_id == scope_id
    assert cached.reference_height == snapshot.reference_height
  end

  defp cached_snapshot(%HeadSnapshot{scope_id: scope_id, revision: generation}) do
    cache_key = put_elem(scope_id, 0, :head_snapshot_scope)

    assert [{^cache_key, _source_revision, ^generation, cached}] =
             :ets.lookup(:block_sync_registry, cache_key)

    cached
  end

  defp assert_routed_to(profile, chain_id, provider) do
    assert {:ok, response, context} = request(profile, chain_id)
    assert context.executed_channel.provider_id == provider
    assert Jason.decode!(response.raw_bytes)["result"] == provider
  end

  defp request(profile, chain_id) do
    RequestPipeline.execute_via_channels(
      chain_id,
      "eth_getBalance",
      ["0x0000000000000000000000000000000000000000", "latest"],
      %RequestOptions{
        profile: profile,
        strategy: :priority,
        transport: :http,
        timeout_ms: 5_000
      }
    )
  end

  defp write_profile(root, slug, chain_id, endpoints, provider_names) do
    providers =
      provider_names
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {provider, priority} ->
        {_ref, port} = endpoints[provider]

        "      - id: #{provider}\n        priority: #{priority}\n        url: http://127.0.0.1:#{port}"
      end)

    File.write!(Path.join(root, "#{slug}.yml"), """
    ---
    name: Head Reload
    slug: #{slug}
    ---
    chains:
      test:
        chain_id: #{chain_id}
        block_time_ms: 1000
        monitoring:
          probe_interval_ms: 200
        selection:
          max_lag_blocks: 2
        providers:
    #{providers}
    """)
  end
end
