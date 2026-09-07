defmodule Lasso.Config.EffectiveRuntimePolicyTest do
  use ExUnit.Case, async: false

  alias Lasso.Config.ConfigStore
  alias Lasso.Core.Streaming.StreamCoordinator
  alias Lasso.Testing.MockWSProvider

  test "supervised instance circuit breakers consume application thresholds" do
    previous = Application.get_env(:lasso, :circuit_breaker)

    Application.put_env(:lasso, :circuit_breaker,
      failure_threshold: 9,
      success_threshold: 4,
      recovery_timeout: 1234
    )

    chain = 9_000_000 + System.unique_integer([:positive])
    provider = "policy-#{chain}"

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lasso, :circuit_breaker, previous),
        else: Application.delete_env(:lasso, :circuit_breaker)

      MockWSProvider.stop_mock(chain, provider)
      Lasso.ProfileChainSupervisor.stop_profile_chain("public", chain)
      ConfigStore.unregister_chain_runtime("public", chain)
    end)

    assert {:ok, ^provider} =
             MockWSProvider.start_mock(chain, %{id: provider, auto_confirm: true})

    instance = Lasso.Providers.Catalog.lookup_instance_id("public", chain, provider)

    {:ok, {_flags, children}} = Lasso.Providers.InstanceSupervisor.init(instance)
    child = Enum.find(children, &(&1.id == {:circuit, :ws}))
    start_supervised!(child)

    state =
      :sys.get_state({:via, Registry, {Lasso.Registry, {:circuit_breaker, "#{instance}:ws"}}})

    assert state.failure_threshold == 9
    assert state.success_threshold == 4
    assert state.base_recovery_timeout == 1234
  end

  test "an existing stream captures active profile backfill policy when recovery begins" do
    chain = 9_000_000 + System.unique_integer([:positive])
    owner = self()
    :ok = ConfigStore.register_chain_runtime("public", chain, %{providers: []})

    on_exit(fn ->
      Lasso.ProfileChainSupervisor.stop_profile_chain("public", chain)
      ConfigStore.unregister_chain_runtime("public", chain)
    end)

    pid =
      start_supervised!(
        {StreamCoordinator,
         {"public", chain, {:newHeads},
          [
            primary_provider_id: "old",
            backfill_provider_selector: fn _, _, _ -> {:ok, "http"} end,
            replacement_requester: fn _, _, _, provider, coordinator ->
              send(coordinator, {:subscription_confirmed, provider, "sub"})
            end,
            backfill_requester: fn _, _, method, _, opts ->
              send(owner, {:backfill, method, opts.timeout_ms})

              receive do
                :finish -> {:ok, "0x1", %{}}
              end
            end
          ]}}
      )

    assert :sys.get_state(pid).max_backfill_blocks == 100

    :ok = ConfigStore.unregister_chain_runtime("public", chain)

    :ok =
      ConfigStore.register_chain_runtime("public", chain, %{
        providers: [],
        websocket: %{failover: %{max_backfill_blocks: 7, backfill_timeout_ms: 750}}
      })

    GenServer.cast(pid, {:upstream_event, "old", "sub", %{"number" => "0x1", "hash" => "0x1"}, 1})
    GenServer.cast(pid, {:provider_unhealthy, "old", "new"})
    assert_receive {:backfill, "eth_blockNumber", timeout}, 1000
    assert timeout > 0 and timeout <= 750
    state = :sys.get_state(pid)
    assert state.max_backfill_blocks == 7
    assert state.failover_context.backfill_context.max_backfill == 7
  end

  test "LW_BETA runtime setting rejects invalid tuning" do
    previous = System.get_env("LW_BETA")

    on_exit(fn ->
      if previous, do: System.put_env("LW_BETA", previous), else: System.delete_env("LW_BETA")
    end)

    System.put_env("LW_BETA", "2.5")
    assert Config.Reader.read!("config/runtime.exs", env: :test)[:lasso][:lw_beta] == 2.5

    for value <- ["0", "-2", "not-a-number"] do
      System.put_env("LW_BETA", value)

      assert_raise RuntimeError, "LW_BETA must be a positive number", fn ->
        Config.Reader.read!("config/runtime.exs", env: :test)
      end
    end
  end
end
