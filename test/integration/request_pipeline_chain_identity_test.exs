defmodule Lasso.RPC.RequestPipelineChainIdentityTest do
  use Lasso.Test.LassoIntegrationCase

  @moduletag :integration

  alias Lasso.Core.Support.CircuitBreaker.Snapshot
  alias Lasso.Providers.{Catalog, ChainIdentity}
  alias Lasso.RPC.{RequestOptions, RequestPipeline}

  defmodule PausedSelection do
    @behaviour Lasso.RPC.Strategy
    def prepare_context(_profile, chain, _method, timeout),
      do: Lasso.RPC.StrategyContext.new(chain, timeout)

    def rank_channels(channels, _method, _context, _profile, _chain) do
      observer = Application.fetch_env!(:lasso, :chain_identity_selection_observer)
      send(observer, {:identity_selection_ready, self()})

      receive do
        :resume_identity_selection -> channels
      end
    end
  end

  test "identity learned after selection still prevents dispatch", %{chain: chain} do
    setup_providers([%{id: "selected", priority: 1, behavior: :healthy}])
    registry = Application.get_env(:lasso, :strategy_registry)
    observer = Application.get_env(:lasso, :chain_identity_selection_observer)

    Application.put_env(
      :lasso,
      :strategy_registry,
      Map.put(
        registry || Lasso.RPC.Strategies.Registry.default_registry(),
        :identity_pause,
        PausedSelection
      )
    )

    Application.put_env(:lasso, :chain_identity_selection_observer, self())

    on_exit(fn ->
      if registry,
        do: Application.put_env(:lasso, :strategy_registry, registry),
        else: Application.delete_env(:lasso, :strategy_registry)

      if observer,
        do: Application.put_env(:lasso, :chain_identity_selection_observer, observer),
        else: Application.delete_env(:lasso, :chain_identity_selection_observer)
    end)

    task =
      Task.async(fn ->
        RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [], %RequestOptions{
          profile: "public",
          strategy: :identity_pause,
          transport: :http,
          timeout_ms: 2_000
        })
      end)

    assert_receive {:identity_selection_ready, owner}
    id = Catalog.lookup_instance_id("public", chain, "selected")
    ChainIdentity.record(ChainIdentity.capture(id, Catalog.snapshot()), :rejected)
    send(owner, :resume_identity_selection)
    assert {:error, _, ctx} = Task.await(task)
    assert ctx.execution_envelope.dispatch_count == 0
    assert ctx.terminal_reason == :admission_unavailable
  end

  test "never-observed identity preserves admission", %{chain: chain} do
    setup_providers([%{id: "unknown", priority: 1, behavior: :healthy}])
    assert {:ok, _, ctx} = request(chain, "unknown")
    assert ctx.execution_envelope.dispatch_count == 1
  end

  test "a closed circuit cannot dispatch a rejected HTTP identity, and a matching probe restores it",
       %{chain: chain} do
    setup_providers([%{id: "identity-provider", priority: 1, behavior: :healthy}])
    id = Catalog.lookup_instance_id("public", chain, "identity-provider")
    snapshot = Catalog.snapshot()
    assert {:ok, %{state: :closed} = breaker} = Snapshot.lookup({id, :http})

    ChainIdentity.record(ChainIdentity.capture(id, snapshot), :rejected)
    assert {:error, _, ctx} = request(chain, "identity-provider")
    assert ctx.execution_envelope.dispatch_count == 0
    assert ctx.terminal_reason == :admission_unavailable
    assert Snapshot.lookup({id, :http}) == {:ok, breaker}

    ChainIdentity.record(ChainIdentity.capture(id, snapshot), :verified)
    assert {:ok, _, ctx} = request(chain, "identity-provider")
    assert ctx.execution_envelope.dispatch_count == 1
    assert ctx.executed_channel.provider_id == "identity-provider"
  end

  test "rejected primary fails over without attempting transport", %{chain: chain} do
    setup_providers([
      %{id: "wrong-chain", priority: 1, behavior: :healthy},
      %{id: "matching-chain", priority: 2, behavior: :healthy}
    ])

    id = Catalog.lookup_instance_id("public", chain, "wrong-chain")
    ChainIdentity.record(ChainIdentity.capture(id, Catalog.snapshot()), :rejected)

    assert {:ok, _, ctx} = request(chain, nil)
    assert ctx.executed_channel.provider_id == "matching-chain"
    assert ctx.execution_envelope.dispatch_count == 1
  end

  test "unrelated configuration publication cannot clear a physical endpoint rejection", %{
    chain: chain
  } do
    setup_providers([%{id: "persistent", priority: 1, behavior: :healthy}])
    id = Catalog.lookup_instance_id("public", chain, "persistent")
    old_snapshot = Catalog.snapshot()
    stale_probe = ChainIdentity.capture(id, old_snapshot)
    ChainIdentity.record(ChainIdentity.capture(id, old_snapshot), :rejected)

    unrelated_chain = chain + 100_000_000

    :ok =
      Lasso.Config.ConfigStore.register_chain_runtime("public", unrelated_chain, %{
        chain_id: unrelated_chain,
        name: "Unrelated",
        providers: []
      })

    Catalog.build_from_config()

    on_exit(fn ->
      Lasso.Config.ConfigStore.unregister_chain_runtime("public", unrelated_chain)
      Catalog.build_from_config()
    end)

    assert Catalog.active_generation() > old_snapshot.generation
    assert Catalog.lookup_instance_id("public", chain, "persistent") == id
    ChainIdentity.record(stale_probe, :verified)
    assert {:error, _, ctx} = request(chain, "persistent")
    assert ctx.execution_envelope.dispatch_count == 0

    ChainIdentity.record(ChainIdentity.capture(id, Catalog.snapshot()), :verified)
    assert {:ok, _, ctx} = request(chain, "persistent")
    assert ctx.execution_envelope.dispatch_count == 1
  end

  test "identity rejection abandons an acquired half-open lease", %{chain: chain} do
    setup_providers([%{id: "probation", priority: 1, behavior: :healthy}])
    id = Catalog.lookup_instance_id("public", chain, "probation")
    breaker_id = {id, :http}
    breaker_pid = GenServer.whereis(Lasso.Core.Support.CircuitBreaker.via_name(breaker_id))
    :sys.replace_state(breaker_pid, &%{&1 | state: :half_open})
    {:ok, snapshot} = Snapshot.lookup(breaker_id)
    Snapshot.put(%{snapshot | state: :half_open, half_open_inflight: 0})

    ChainIdentity.record(ChainIdentity.capture(id, Catalog.snapshot()), :rejected)
    assert {:error, _, ctx} = request(chain, "probation")
    assert ctx.execution_envelope.dispatch_count == 0
    assert ctx.execution_envelope.candidate_admission_count > 0
    assert %{state: :half_open, inflight_count: 0} = :sys.get_state(breaker_pid)

    deadline = System.monotonic_time(:microsecond) + 1_000_000

    assert {:ok, %{kind: :half_open} = receipt} =
             Lasso.Core.Support.CircuitBreaker.admit(breaker_id, deadline)

    assert :ok = Lasso.Core.Support.CircuitBreaker.abandon_unclaimed(receipt, self())
  end

  defp request(chain, provider) do
    RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [], %RequestOptions{
      profile: "public",
      strategy: :priority,
      transport: :http,
      timeout_ms: 2_000,
      provider_override: provider,
      failover_on_override: false
    })
  end
end
