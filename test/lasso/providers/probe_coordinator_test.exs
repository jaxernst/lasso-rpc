defmodule Lasso.Providers.ProbeCoordinatorTest do
  use ExUnit.Case, async: false

  alias Lasso.Config.ConfigStore
  alias Lasso.Providers.{Catalog, ProbeCoordinator}

  @profile "pc_test"
  @chain "pc_test_chain"
  @config_table :lasso_config_store
  @instance_table :lasso_instance_state

  setup do
    original_profiles = ConfigStore.list_profiles()

    register_chain(@profile, @chain, [
      %{id: "pc_p1", name: "P1", url: "https://pc-test-1.example.com", priority: 1},
      %{id: "pc_p2", name: "P2", url: "https://pc-test-2.example.com", priority: 2}
    ])

    Catalog.build_from_config()

    on_exit(fn ->
      # Stop any test probe coordinators (catch exits from already-dead processes)
      try do
        case GenServer.whereis(ProbeCoordinator.via_name(@chain)) do
          nil -> :ok
          pid -> GenServer.stop(pid, :normal, 1_000)
        end
      catch
        :exit, _ -> :ok
      end

      ConfigStore.unregister_chain_runtime(@profile, @chain)
      ConfigStore.unregister_chain_runtime("pc_test_b", @chain)
      :ets.insert(@config_table, {{:profile_list}, original_profiles})
      clean_instance_state()
      Catalog.build_from_config()
    end)

    :ok
  end

  describe "start_link/1" do
    test "starts and registers via Registry" do
      {:ok, pid} = ProbeCoordinator.start_link(@chain)
      assert Process.alive?(pid)
      assert GenServer.whereis(ProbeCoordinator.via_name(@chain)) == pid
    end

    test "loads instances from catalog on init" do
      {:ok, pid} = ProbeCoordinator.start_link(@chain)
      state = :sys.get_state(pid)

      instance_ids = Catalog.list_instances_for_chain(@chain)
      assert map_size(state.instances) == length(instance_ids)
      assert state.chain == @chain
    end
  end

  describe "tick cycle and probing" do
    test "writes health state to ETS after probe" do
      {:ok, _pid} = ProbeCoordinator.start_link(@chain)
      instance_ids = Catalog.list_instances_for_chain(@chain)

      # Wait for at least one tick cycle to fire probes
      Process.sleep(500)

      # At least one instance should have health data written
      has_health =
        Enum.any?(instance_ids, fn id ->
          case :ets.lookup(@instance_table, {:health, id}) do
            [{_, _}] -> true
            [] -> false
          end
        end)

      assert has_health
    end
  end

  describe "reload_instances/1" do
    test "picks up new instances after catalog rebuild" do
      {:ok, pid} = ProbeCoordinator.start_link(@chain)
      state_before = :sys.get_state(pid)
      count_before = map_size(state_before.instances)
      assert count_before == 2

      # Add a new instance via a second profile with a unique provider URL
      register_chain("pc_test_b", @chain, [
        %{id: "pc_p3", name: "P3", url: "https://pc-test-reload-new.example.com", priority: 1}
      ])

      Catalog.build_from_config()

      # Verify catalog sees the new instance
      catalog_instances = Catalog.list_instances_for_chain(@chain)
      assert length(catalog_instances) == 3

      ProbeCoordinator.reload_instances(@chain)
      Process.sleep(100)

      state_after = :sys.get_state(pid)
      assert map_size(state_after.instances) == 3
    end

    test "preserves backoff state for existing instances on reload" do
      {:ok, pid} = ProbeCoordinator.start_link(@chain)
      instance_ids = Catalog.list_instances_for_chain(@chain)
      [first_id | _] = instance_ids

      # Simulate failure state in the coordinator
      state = :sys.get_state(pid)
      inst = Map.get(state.instances, first_id)
      modified = %{inst | consecutive_failures: 3, current_backoff_ms: 8_000}
      new_state = %{state | instances: Map.put(state.instances, first_id, modified)}
      :sys.replace_state(pid, fn _ -> new_state end)

      # Reload should preserve the failure state
      ProbeCoordinator.reload_instances(@chain)
      Process.sleep(50)

      reloaded_state = :sys.get_state(pid)
      reloaded_inst = Map.get(reloaded_state.instances, first_id)
      assert reloaded_inst.consecutive_failures == 3
      assert reloaded_inst.current_backoff_ms == 8_000
    end
  end

  describe "backoff behavior" do
    test "successful probe resets failure count" do
      {:ok, pid} = ProbeCoordinator.start_link(@chain)
      instance_ids = Catalog.list_instances_for_chain(@chain)
      [first_id | _] = instance_ids

      # Simulate receiving a success result
      ref = make_ref()
      send(pid, {ref, {first_id, :success}})
      Process.sleep(50)

      state = :sys.get_state(pid)
      inst = Map.get(state.instances, first_id)
      assert inst.consecutive_failures == 0
      assert inst.current_backoff_ms == 0
    end

    test "failure increments failure count and sets backoff" do
      {:ok, pid} = ProbeCoordinator.start_link(@chain)
      instance_ids = Catalog.list_instances_for_chain(@chain)
      [first_id | _] = instance_ids

      # Simulate receiving a failure result
      ref = make_ref()
      send(pid, {ref, {first_id, {:failure, :timeout}}})
      Process.sleep(50)

      state = :sys.get_state(pid)
      inst = Map.get(state.instances, first_id)
      assert inst.consecutive_failures == 1
      assert inst.current_backoff_ms > 0
    end

    test "multiple failures increase backoff exponentially" do
      {:ok, pid} = ProbeCoordinator.start_link(@chain)
      instance_ids = Catalog.list_instances_for_chain(@chain)
      [first_id | _] = instance_ids

      # Send multiple failures
      for _ <- 1..4 do
        ref = make_ref()
        send(pid, {ref, {first_id, {:failure, :timeout}}})
        Process.sleep(10)
      end

      state = :sys.get_state(pid)
      inst = Map.get(state.instances, first_id)
      assert inst.consecutive_failures == 4
      # Backoff should be significant after 4 failures (2s * 2^3 = 16s, capped at 30s)
      assert inst.current_backoff_ms >= 2_000
    end
  end

  describe "minimum probe interval" do
    test "enforces 10s floor between probes regardless of backoff" do
      {:ok, pid} = ProbeCoordinator.start_link(@chain)
      instance_ids = Catalog.list_instances_for_chain(@chain)
      [first_id | _] = instance_ids

      state = :sys.get_state(pid)
      inst = Map.get(state.instances, first_id)

      # Set last_probe_monotonic to 5 seconds ago with zero backoff
      now = System.monotonic_time(:millisecond)

      modified = %{
        inst
        | last_probe_monotonic: now - 5_000,
          current_backoff_ms: 0
      }

      new_state = %{state | instances: Map.put(state.instances, first_id, modified)}
      :sys.replace_state(pid, fn _ -> new_state end)

      # Wait for a tick cycle
      Process.sleep(300)

      # The instance should NOT have been probed (5s < 10s minimum)
      after_state = :sys.get_state(pid)
      after_inst = Map.get(after_state.instances, first_id)
      assert after_inst.last_probe_monotonic == now - 5_000
    end

    test "allows probing after minimum interval has elapsed" do
      {:ok, pid} = ProbeCoordinator.start_link(@chain)
      instance_ids = Catalog.list_instances_for_chain(@chain)
      [first_id | _] = instance_ids

      state = :sys.get_state(pid)
      inst = Map.get(state.instances, first_id)

      # Set last_probe_monotonic to 11 seconds ago with zero backoff
      now = System.monotonic_time(:millisecond)

      modified = %{
        inst
        | last_probe_monotonic: now - 11_000,
          current_backoff_ms: 0
      }

      new_state = %{state | instances: Map.put(state.instances, first_id, modified)}
      :sys.replace_state(pid, fn _ -> new_state end)

      # Wait for a tick cycle
      Process.sleep(300)

      # The instance should have been probed (11s > 10s minimum)
      after_state = :sys.get_state(pid)
      after_inst = Map.get(after_state.instances, first_id)
      assert after_inst.last_probe_monotonic > now - 11_000
    end
  end

  describe "via_name/1" do
    test "returns a Registry via tuple" do
      {:via, Registry, {Lasso.Registry, key}} = ProbeCoordinator.via_name("ethereum")
      assert key == {:probe_coordinator, "ethereum"}
    end
  end

  describe "probe result for unknown instance" do
    test "ignores results for instance_ids not in state" do
      {:ok, pid} = ProbeCoordinator.start_link(@chain)

      ref = make_ref()
      send(pid, {ref, {"unknown:fake:000000000000", :success}})
      Process.sleep(50)

      # Should not crash
      assert Process.alive?(pid)
    end
  end

  describe "DOWN message handling" do
    test "handles DOWN messages without crashing" do
      {:ok, pid} = ProbeCoordinator.start_link(@chain)

      send(pid, {:DOWN, make_ref(), :process, self(), :normal})
      Process.sleep(50)

      assert Process.alive?(pid)
    end
  end

  # Helpers

  defp register_chain(profile, chain, providers) do
    current = ConfigStore.list_profiles()

    unless profile in current do
      :ets.insert(@config_table, {{:profile_list}, [profile | current]})
    end

    ConfigStore.register_chain_runtime(profile, chain, %{
      chain_id: 99,
      name: chain,
      providers: providers
    })
  end

  defp clean_instance_state do
    instance_ids = Catalog.list_instances_for_chain(@chain)

    Enum.each(instance_ids, fn id ->
      :ets.delete(@instance_table, {:health, id})
      :ets.delete(@instance_table, {:circuit, id, :http})
      :ets.delete(@instance_table, {:circuit, id, :ws})
    end)
  rescue
    ArgumentError -> :ok
  end
end
