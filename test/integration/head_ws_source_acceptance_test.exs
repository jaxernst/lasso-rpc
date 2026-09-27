defmodule Lasso.RPC.HeadWsSourceAcceptanceTest do
  use Lasso.Test.LassoIntegrationCase

  alias Lasso.BlockSync.{Registry, Worker}
  alias Lasso.Config.ConfigStore
  alias Lasso.Events.HeadObserved
  alias Lasso.Observations.HeadObservation
  alias Lasso.Providers.{Catalog, HeadEvidence}
  alias Lasso.RPC.Selection
  alias Lasso.RPC.Selection.CandidateCursor
  alias LassoWeb.Dashboard.StatusHelpers
  alias LassoWeb.Dashboard.EventStream

  test "newHeads source events drive branch and lag evidence for operators and routing", %{
    chain: chain
  } do
    profile = "public"

    assert :ok =
             ConfigStore.register_chain_runtime(profile, chain, %{
               block_time_ms: 1_000,
               selection: %{max_lag_blocks: 2},
               providers: []
             })

    suffix = Integer.to_string(chain)
    minority = "minority-#{suffix}"
    majority_a = "majority-a-#{suffix}"
    majority_b = "majority-b-#{suffix}"

    setup_providers(
      [
        %{id: minority, priority: 1},
        %{id: majority_a, priority: 2},
        %{id: majority_b, priority: 3}
      ],
      provider_type: :ws
    )

    ids =
      Map.new([minority, majority_a, majority_b], fn provider ->
        {provider, Catalog.lookup_instance_id(profile, chain, provider)}
      end)

    for {_provider, id} <- ids do
      start_supervised!(Supervisor.child_spec({Worker, {chain, id}}, id: {:head_worker, id}))
    end

    Lasso.Test.Eventually.assert_eventually(fn ->
      Enum.all?(ids, fn {_provider, id} ->
        match?({:ok, %{mode: :http_with_ws}}, Worker.get_status(chain, id))
      end)
    end)

    for {_provider, id} <- ids do
      assert Registry.get_observation(chain, id, :ws) == {:error, :not_found}
    end

    for {provider, hash} <- [{minority, "0xbbb"}, {majority_a, "0xaaa"}] do
      send_head(chain, provider, 100, hash)
    end

    Lasso.Test.Eventually.assert_eventually(fn ->
      match?({:ok, %{qualification: :ambiguous}}, HeadEvidence.snapshot(profile, chain))
    end)

    assert {:ok, %{provider_id: ^minority}, _} =
             profile
             |> Selection.select_channel_candidates(chain, "eth_blockNumber",
               strategy: :priority,
               transport: :ws
             )
             |> CandidateCursor.next()

    send_head(chain, majority_b, 100, "0xaaa")

    Lasso.Test.Eventually.assert_eventually(fn ->
      match?({:ok, %{qualification: :qualified}}, HeadEvidence.snapshot(profile, chain))
    end)

    for {provider, hash} <-
          [{minority, "0xbbb"}, {majority_a, "0xaaa"}, {majority_b, "0xaaa"}] do
      assert {:ok, %{height: 100, block_hash: ^hash}} =
               Registry.get_observation(chain, ids[provider], :ws)
    end

    cursor =
      Selection.select_channel_candidates(profile, chain, "eth_blockNumber",
        strategy: :priority,
        transport: :ws
      )

    assert {:ok, %{provider_id: ^majority_a}, _} = CandidateCursor.next(cursor)

    send_head(chain, minority, 90, "0xbbb")

    Lasso.Test.Eventually.assert_eventually(fn ->
      StatusHelpers.check_block_lag(chain, ids[minority], profile) == :lagging
    end)

    assert {:ok, %{provider_id: ^majority_a}, _} =
             profile
             |> Selection.select_channel_candidates(chain, "eth_blockNumber",
               strategy: :priority,
               transport: :ws
             )
             |> CandidateCursor.next()

    assert {:ok, %{ws_status: %{status: :active}}} = Worker.get_status(chain, ids[majority_a])
  end

  test "dashboard attributes a delivered head to its remote member and active profile instance",
       %{
         chain: chain
       } do
    profile = "head-origin-#{chain}"
    provider_id = "provider-#{chain}"
    remote_node_id = "remote-member-#{chain}"

    assert :ok =
             ConfigStore.register_chain_runtime(profile, chain, %{
               block_time_ms: 1_000,
               providers: []
             })

    setup_providers([%{id: provider_id, priority: 1}], profile: profile)
    instance_id = Catalog.lookup_instance_id(profile, chain, provider_id)
    assert is_binary(instance_id)

    {:ok, stream} = EventStream.ensure_started(profile)

    on_exit(fn ->
      if Process.alive?(stream) do
        DynamicSupervisor.terminate_child(Lasso.Dashboard.StreamSupervisor, stream)
      end
    end)

    observation = %HeadObservation{
      chain_id: chain,
      instance_id: instance_id,
      transport: :ws,
      height: 123,
      observed_at_ms: System.system_time(:millisecond),
      origin_member_id: remote_node_id
    }

    event = %HeadObserved{
      profile: profile,
      provider_id: provider_id,
      node_id: remote_node_id,
      observation: observation
    }

    topic = Lasso.Topics.block_sync(profile, chain)
    assert :ok = Phoenix.PubSub.broadcast(Lasso.PubSub, topic, event)

    Lasso.Test.Eventually.assert_eventually(fn ->
      get_in(:sys.get_state(stream).block_heights, [
        {provider_id, chain, remote_node_id},
        :height
      ]) == 123
    end)

    refute Map.has_key?(
             :sys.get_state(stream).block_heights,
             {provider_id, chain, Lasso.Cluster.Topology.self_node_id()}
           )

    assert :ok =
             Phoenix.PubSub.broadcast(Lasso.PubSub, topic, %{
               event
               | observation: %{observation | instance_id: "stale-instance"},
                 node_id: "rejected-member"
             })

    assert :ok =
             Phoenix.PubSub.broadcast(Lasso.PubSub, topic, %{
               event
               | profile: "other",
                 node_id: "other-profile-member"
             })

    :sys.get_state(stream)

    refute Map.has_key?(
             :sys.get_state(stream).block_heights,
             {provider_id, chain, "rejected-member"}
           )

    refute Map.has_key?(
             :sys.get_state(stream).block_heights,
             {provider_id, chain, "other-profile-member"}
           )
  end

  defp send_head(chain, provider, height, hash) do
    assert :ok =
             MockWSProvider.send_block(chain, provider, %{
               "number" => "0x" <> Integer.to_string(height, 16),
               "hash" => hash,
               "timestamp" => "0x" <> Integer.to_string(System.system_time(:second), 16)
             })
  end
end
