defmodule Lasso.Providers.CandidateListingTest do
  use ExUnit.Case, async: false

  alias Lasso.Config.ConfigStore
  alias Lasso.Core.Support.CircuitBreaker.{Snapshot, Storage}
  alias Lasso.Providers.{Catalog, CandidateListing}
  alias Lasso.RPC.{AttemptIdentity, AttemptProjection, AttemptTerminal}

  @profile "cl_test"
  @chain 99
  @instance_table :lasso_instance_state

  setup do
    register_chain(@profile, @chain, [
      %{id: "p1", name: "P1", url: "https://cl-test-1.example.com", priority: 1},
      %{
        id: "p2",
        name: "P2",
        url: "https://cl-test-2.example.com",
        ws_url: "wss://cl-test-2.example.com/ws",
        priority: 2
      },
      %{id: "p3", name: "P3", url: "https://cl-test-3.example.com", priority: 3, archival: false}
    ])

    Catalog.build_from_config()

    # Clean any leftover instance state before each test
    clean_instance_state()

    Enum.each(Catalog.get_profile_providers(@profile, @chain), fn provider ->
      set_circuit_state(provider.instance_id, :http, :closed)
      set_circuit_state(provider.instance_id, :ws, :closed)
    end)

    on_exit(fn ->
      clean_instance_state()
      ConfigStore.unregister_chain_runtime(@profile, @chain)
      Catalog.build_from_config()
    end)

    :ok
  end

  describe "list_candidates/3 basic" do
    test "returns all providers when no filters active" do
      candidates = CandidateListing.list_candidates(@profile, @chain, %{})
      assert length(candidates) == 3
      ids = Enum.map(candidates, & &1.id)
      assert "p1" in ids
      assert "p2" in ids
      assert "p3" in ids
    end

    test "candidate shape includes required fields" do
      [c | _] = CandidateListing.list_candidates(@profile, @chain, %{})

      assert Map.has_key?(c, :id)
      assert Map.has_key?(c, :instance_id)
      assert Map.has_key?(c, :config)
      assert Map.has_key?(c, :availability)
      assert Map.has_key?(c, :circuit_state)
      assert Map.has_key?(c, :rate_limited)

      assert Map.has_key?(c.circuit_state, :http)
      assert Map.has_key?(c.circuit_state, :ws)
      assert Map.has_key?(c.rate_limited, :http)
      assert Map.has_key?(c.rate_limited, :ws)
    end

    test "does not read or expose a disconnected WebSocket route" do
      candidate =
        @profile
        |> CandidateListing.list_candidates(@chain, %{})
        |> Enum.find(&(&1.id == "p2"))

      assert candidate.transports == [:http]
      assert candidate.circuit_state.ws == :unavailable
      assert candidate.routing_states.ws == nil
    end

    test "returns empty list for unknown profile" do
      assert CandidateListing.list_candidates("nonexistent", @chain, %{}) == []
    end

    test "returns empty list for unknown chain" do
      assert CandidateListing.list_candidates(@profile, 98, %{}) == []
    end

    test "desired configuration is fail-closed until its catalog generation publishes" do
      active = Catalog.snapshot()

      assert :ok =
               ConfigStore.register_provider_runtime(@profile, @chain, %{
                 id: "pending",
                 name: "Pending",
                 url: "https://pending.example.com",
                 priority: 10
               })

      desired_generation = ConfigStore.route_generation()
      assert desired_generation > active.generation
      assert Catalog.snapshot() == active
      assert CandidateListing.list_candidates(@profile, @chain, %{}) == []

      assert :ok = Catalog.build_from_config()
      assert Catalog.active_generation() == desired_generation

      assert Enum.any?(
               Catalog.get_profile_providers(@profile, @chain),
               &(&1.provider_id == "pending")
             )
    end

    test "catalog publication exposes no generation before all direct rows exist" do
      active = Catalog.snapshot()

      assert :ok =
               ConfigStore.register_provider_runtime(@profile, @chain, %{
                 id: "barrier",
                 name: "Barrier",
                 url: "https://barrier.example.com",
                 priority: 11
               })

      desired_generation = ConfigStore.route_generation()
      ref = make_ref()
      Application.put_env(:lasso, :catalog_publication_barrier, {self(), ref})

      on_exit(fn ->
        Application.delete_env(:lasso, :catalog_publication_barrier)

        for phase <- [:after_catalog_populate, :after_control_populate, :before_pointer_swap] do
          send(Process.whereis(Catalog.Owner), {:catalog_publication_continue, ref, phase})
        end
      end)

      task = Task.async(&Catalog.build_from_config/0)

      assert_publication_phase(ref, :after_catalog_populate, desired_generation)
      assert Catalog.snapshot() == active
      assert CandidateListing.list_candidates(@profile, @chain, %{}) == []
      continue_publication(ref, :after_catalog_populate)

      assert_publication_phase(ref, :after_control_populate, desired_generation)
      assert Catalog.snapshot() == active

      [{_, scope}] =
        :ets.lookup(:lasso_instance_state, {:routing_control_scope, @profile, @chain})

      assert scope.generation == desired_generation
      continue_publication(ref, :after_control_populate)

      assert_publication_phase(ref, :before_pointer_swap, desired_generation)
      assert Catalog.snapshot() == active
      continue_publication(ref, :before_pointer_swap)

      assert :ok = Task.await(task)
      Application.delete_env(:lasso, :catalog_publication_barrier)
      assert Catalog.active_generation() == desired_generation
    end

    test "generation change after catalog population retries without publishing partial control" do
      active = Catalog.snapshot()
      owner = Process.whereis(Catalog.Owner)
      instance_id = Catalog.lookup_instance_id(@profile, @chain, "p1")

      assert :ok =
               ConfigStore.register_provider_runtime(@profile, @chain, %{
                 id: "superseded-one",
                 name: "Superseded One",
                 url: "https://superseded-one.example.com",
                 priority: 12
               })

      generation_one = ConfigStore.route_generation()
      ref = make_ref()
      Application.put_env(:lasso, :catalog_publication_barrier, {self(), ref})

      on_exit(fn ->
        Application.delete_env(:lasso, :catalog_publication_barrier)

        for phase <- [:after_catalog_populate, :after_control_populate, :before_pointer_swap] do
          send(Process.whereis(Catalog.Owner), {:catalog_publication_continue, ref, phase})
        end
      end)

      task = Task.async(&Catalog.build_from_config/0)
      assert_publication_phase(ref, :after_catalog_populate, generation_one)

      assert :ok =
               ConfigStore.register_provider_runtime(@profile, @chain, %{
                 id: "superseding-two",
                 name: "Superseding Two",
                 url: "https://superseding-two.example.com",
                 priority: 13
               })

      generation_two = ConfigStore.route_generation()
      assert generation_two > generation_one

      stale_fact =
        AttemptTerminal.Response.new(
          attempt_identity(instance_id, active.generation),
          :success,
          10
        )

      stale_event = AttemptProjection.new(stale_fact, "p1", "eth_call")
      assert :stale = AttemptProjection.apply_control(stale_event)

      [{_, tombstone}] =
        :ets.lookup(:lasso_instance_state, {:routing_control_scope, @profile, @chain})

      assert tombstone.generation == active.generation
      assert tombstone.publication_loss_generation == generation_two

      continue_publication(ref, :after_catalog_populate)
      assert_publication_phase(ref, :after_catalog_populate, generation_two)

      refute_receive {:catalog_publication_phase, ^owner, ^ref, :after_control_populate,
                      ^generation_one},
                     0

      assert Process.whereis(Catalog.Owner) == owner
      assert Process.alive?(owner)
      assert Catalog.snapshot() == active

      [{_, unchanged}] =
        :ets.lookup(:lasso_instance_state, {:routing_control_scope, @profile, @chain})

      assert unchanged.generation == active.generation
      assert unchanged.publication_loss_generation == generation_two

      continue_publication(ref, :after_catalog_populate)
      assert_publication_phase(ref, :after_control_populate, generation_two)

      scope = AttemptProjection.scope_state(@profile, @chain, generation_two)
      assert scope.degraded?
      assert scope.publication_loss_generation == generation_two
      assert scope.stale_drops >= 1

      continue_publication(ref, :after_control_populate)
      assert_publication_phase(ref, :before_pointer_swap, generation_two)
      continue_publication(ref, :before_pointer_swap)

      assert :ok = Task.await(task)
      Application.delete_env(:lasso, :catalog_publication_barrier)

      assert Process.whereis(Catalog.Owner) == owner
      assert Process.alive?(owner)
      assert Catalog.active_generation() == generation_two
    end

    test "a loss tombstone survives a superseded prepared generation" do
      active_generation = Catalog.active_generation()
      instance_id = Catalog.lookup_instance_id(@profile, @chain, "p1")

      assert :ok =
               ConfigStore.register_provider_runtime(@profile, @chain, %{
                 id: "generation-one",
                 name: "Generation One",
                 url: "https://generation-one.example.com",
                 priority: 12
               })

      generation_one = ConfigStore.route_generation()
      ref = make_ref()
      Application.put_env(:lasso, :catalog_publication_barrier, {self(), ref})

      on_exit(fn ->
        Application.delete_env(:lasso, :catalog_publication_barrier)

        for phase <- [:after_catalog_populate, :after_control_populate, :before_pointer_swap] do
          send(Process.whereis(Catalog.Owner), {:catalog_publication_continue, ref, phase})
        end
      end)

      task = Task.async(&Catalog.build_from_config/0)
      assert_publication_phase(ref, :after_catalog_populate, generation_one)
      continue_publication(ref, :after_catalog_populate)
      assert_publication_phase(ref, :after_control_populate, generation_one)

      stale_fact =
        AttemptTerminal.Response.new(
          attempt_identity(instance_id, active_generation),
          :success,
          10
        )

      stale_event = %{AttemptProjection.new(stale_fact, "p1", "eth_call") | emitted_at_us: 100}
      assert :stale = AttemptProjection.apply_control(stale_event)

      assert :ok =
               ConfigStore.register_provider_runtime(@profile, @chain, %{
                 id: "generation-two",
                 name: "Generation Two",
                 url: "https://generation-two.example.com",
                 priority: 13
               })

      generation_two = ConfigStore.route_generation()
      assert generation_two > generation_one
      continue_publication(ref, :after_control_populate)

      assert_publication_phase(ref, :after_catalog_populate, generation_two)
      continue_publication(ref, :after_catalog_populate)
      assert_publication_phase(ref, :after_control_populate, generation_two)

      scope = AttemptProjection.scope_state(@profile, @chain, generation_two)
      assert scope.degraded?
      assert scope.publication_loss_generation == generation_one
      assert scope.stale_drops >= 1

      continue_publication(ref, :after_control_populate)
      assert_publication_phase(ref, :before_pointer_swap, generation_two)
      continue_publication(ref, :before_pointer_swap)

      assert :ok = Task.await(task)
      Application.delete_env(:lasso, :catalog_publication_barrier)

      for stamp <- 101..132 do
        fact =
          AttemptTerminal.Response.new(
            attempt_identity(instance_id, generation_two),
            :success,
            10
          )

        event = %{AttemptProjection.new(fact, "p1", "eth_call") | emitted_at_us: stamp}
        assert :ok = AttemptProjection.apply_control(event)
      end

      recovered = AttemptProjection.scope_state(@profile, @chain, generation_two)
      refute recovered.degraded?
      assert recovered.publication_loss_generation == nil
    end

    test "a same-generation catalog rebuild preserves learned control" do
      generation = Catalog.active_generation()
      instance_id = Catalog.lookup_instance_id(@profile, @chain, "p1")

      fact =
        AttemptTerminal.Response.new(attempt_identity(instance_id, generation), :success, 10)

      event = %{AttemptProjection.new(fact, "p1", "eth_call") | emitted_at_us: 100}
      assert :ok = AttemptProjection.apply_control(event)

      key = {:routing_control, @profile, @chain, instance_id, :http, "default"}
      [{^key, before_row}] = :ets.lookup(:lasso_instance_state, key)
      assert before_row.revision == 1

      assert :ok = Catalog.build_from_config()

      [{^key, after_row}] = :ets.lookup(:lasso_instance_state, key)
      assert after_row == before_row
      assert Catalog.active_generation() == generation
    end

    test "a generation change between control precheck and CAS is stale" do
      generation = Catalog.active_generation()
      instance_id = Catalog.lookup_instance_id(@profile, @chain, "p1")

      fact = AttemptTerminal.Response.new(attempt_identity(instance_id, generation), :success, 10)
      event = %{AttemptProjection.new(fact, "p1", "eth_call") | emitted_at_us: 100}
      release_ref = make_ref()
      parent = self()

      task =
        Task.async(fn ->
          AttemptProjection.apply_control_after_barrier(event, parent, release_ref)
        end)

      assert_receive {:attempt_projection_before_cas, producer, ^release_ref}
      assert producer == task.pid

      assert :ok =
               ConfigStore.register_provider_runtime(@profile, @chain, %{
                 id: "cas-generation",
                 name: "CAS Generation",
                 url: "https://cas-generation.example.com",
                 priority: 14
               })

      next_generation = ConfigStore.route_generation()
      assert next_generation > generation
      send(task.pid, release_ref)
      assert :stale = Task.await(task)

      assert :ok = Catalog.build_from_config()
      scope = AttemptProjection.scope_state(@profile, @chain, next_generation)
      assert scope.degraded?
      assert scope.stale_drops >= 1

      key = {:routing_control, @profile, @chain, instance_id, :http, "default"}
      [{^key, row}] = :ets.lookup(:lasso_instance_state, key)
      assert row.comparable_attempts == 0
    end
  end

  describe "circuit breaker filtering" do
    test "excludes providers with open HTTP circuit when protocol is :http" do
      instance_id = Catalog.lookup_instance_id(@profile, @chain, "p1")
      set_circuit_state(instance_id, :http, :open)

      candidates = CandidateListing.list_candidates(@profile, @chain, %{protocol: :http})
      ids = Enum.map(candidates, & &1.id)
      refute "p1" in ids
    end

    test "includes providers with closed circuit" do
      instance_id = Catalog.lookup_instance_id(@profile, @chain, "p1")
      set_circuit_state(instance_id, :http, :closed)

      candidates = CandidateListing.list_candidates(@profile, @chain, %{protocol: :http})
      ids = Enum.map(candidates, & &1.id)
      assert "p1" in ids
    end

    test "includes half-open circuits when include_half_open is true" do
      instance_id = Catalog.lookup_instance_id(@profile, @chain, "p1")
      set_circuit_state(instance_id, :http, :half_open)

      excluded =
        CandidateListing.list_candidates(@profile, @chain, %{
          protocol: :http,
          include_half_open: false
        })

      included =
        CandidateListing.list_candidates(@profile, @chain, %{
          protocol: :http,
          include_half_open: true
        })

      excluded_ids = Enum.map(excluded, & &1.id)
      included_ids = Enum.map(included, & &1.id)

      refute "p1" in excluded_ids
      assert "p1" in included_ids
    end

    test "all circuits open returns empty list" do
      for pid <- ["p1", "p2", "p3"] do
        instance_id = Catalog.lookup_instance_id(@profile, @chain, pid)
        set_circuit_state(instance_id, :http, :open)
      end

      candidates = CandidateListing.list_candidates(@profile, @chain, %{protocol: :http})
      assert candidates == []
    end
  end

  describe "rate limit filtering" do
    test "excludes rate-limited providers when exclude_rate_limited is true" do
      instance_id = Catalog.lookup_instance_id(@profile, @chain, "p1")
      set_rate_limited(instance_id, :http)

      candidates =
        CandidateListing.list_candidates(@profile, @chain, %{
          protocol: :http,
          exclude_rate_limited: true
        })

      ids = Enum.map(candidates, & &1.id)
      refute "p1" in ids
    end

    test "includes rate-limited providers when exclude_rate_limited is false" do
      instance_id = Catalog.lookup_instance_id(@profile, @chain, "p1")
      set_rate_limited(instance_id, :http)

      candidates = CandidateListing.list_candidates(@profile, @chain, %{protocol: :http})
      ids = Enum.map(candidates, & &1.id)
      assert "p1" in ids
    end
  end

  describe "transport filtering" do
    test "protocol :http filters to providers with url" do
      candidates = CandidateListing.list_candidates(@profile, @chain, %{protocol: :http})
      assert length(candidates) == 3
    end
  end

  describe "archival filtering" do
    test "requires_archival: true excludes non-archival providers" do
      candidates = CandidateListing.list_candidates(@profile, @chain, %{requires_archival: true})
      ids = Enum.map(candidates, & &1.id)
      refute "p3" in ids
      assert "p1" in ids
    end

    test "without requires_archival includes all providers" do
      candidates = CandidateListing.list_candidates(@profile, @chain, %{})
      assert length(candidates) == 3
    end
  end

  describe "exclude list" do
    test "excludes providers by id" do
      candidates = CandidateListing.list_candidates(@profile, @chain, %{exclude: ["p1", "p3"]})
      ids = Enum.map(candidates, & &1.id)
      assert ids == ["p2"]
    end

    test "nil exclude list includes all" do
      candidates = CandidateListing.list_candidates(@profile, @chain, %{exclude: nil})
      assert length(candidates) == 3
    end
  end

  describe "combined filters" do
    test "circuit open + rate limited + archival filters compose correctly" do
      id_p1 = Catalog.lookup_instance_id(@profile, @chain, "p1")
      id_p2 = Catalog.lookup_instance_id(@profile, @chain, "p2")

      set_circuit_state(id_p1, :http, :open)
      set_rate_limited(id_p2, :http)

      candidates =
        CandidateListing.list_candidates(@profile, @chain, %{
          protocol: :http,
          exclude_rate_limited: true,
          requires_archival: true
        })

      # p1 is circuit-open, p2 is rate-limited, p3 is non-archival → none pass
      assert candidates == []
    end
  end

  describe "get_min_recovery_time/3" do
    test "returns nil when no circuits are open" do
      assert {:ok, nil} = CandidateListing.get_min_recovery_time(@profile, @chain)
    end

    test "returns minimum recovery time across open circuits" do
      id_p1 = Catalog.lookup_instance_id(@profile, @chain, "p1")
      id_p2 = Catalog.lookup_instance_id(@profile, @chain, "p2")
      now_ms = System.monotonic_time(:millisecond)

      set_circuit_state(id_p1, :http, :open, now_ms + 5_000)
      set_circuit_state(id_p2, :http, :open, now_ms + 2_000)

      {:ok, min_time} = CandidateListing.get_min_recovery_time(@profile, @chain)
      assert is_integer(min_time)
      assert min_time > 0
      assert min_time <= 5_000
    end

    test "filters by transport" do
      id_p1 = Catalog.lookup_instance_id(@profile, @chain, "p1")
      now_ms = System.monotonic_time(:millisecond)

      set_circuit_state(id_p1, :ws, :open, now_ms + 3_000)

      assert {:ok, nil} =
               CandidateListing.get_min_recovery_time(@profile, @chain, transport: :http)

      {:ok, ws_time} = CandidateListing.get_min_recovery_time(@profile, @chain, transport: :ws)
      assert is_integer(ws_time)
    end
  end

  describe "availability mapping" do
    test "healthy instance shows :up availability" do
      instance_id = Catalog.lookup_instance_id(@profile, @chain, "p1")
      set_health_status(instance_id, :healthy)

      [c] =
        CandidateListing.list_candidates(@profile, @chain, %{protocol: :http})
        |> Enum.filter(&(&1.id == "p1"))

      assert c.availability == :up
    end

    test "unhealthy instance shows :down availability" do
      instance_id = Catalog.lookup_instance_id(@profile, @chain, "p1")
      set_health_status(instance_id, :unhealthy)

      [c] =
        CandidateListing.list_candidates(@profile, @chain, %{protocol: :http})
        |> Enum.filter(&(&1.id == "p1"))

      assert c.availability == :down
    end

    test "degraded instance shows :limited availability" do
      instance_id = Catalog.lookup_instance_id(@profile, @chain, "p1")
      set_health_status(instance_id, :degraded)

      [c] =
        CandidateListing.list_candidates(@profile, @chain, %{protocol: :http})
        |> Enum.filter(&(&1.id == "p1"))

      assert c.availability == :limited
    end

    test "misconfigured instance shows :down availability" do
      instance_id = Catalog.lookup_instance_id(@profile, @chain, "p1")
      set_health_status(instance_id, :misconfigured)

      [c] =
        CandidateListing.list_candidates(@profile, @chain, %{protocol: :http})
        |> Enum.filter(&(&1.id == "p1"))

      assert c.availability == :down
    end

    test "learned HTTP failure does not poison WebSocket availability" do
      instance_id = Catalog.lookup_instance_id(@profile, @chain, "p2")
      generation = ConfigStore.route_generation()

      identity =
        AttemptIdentity.new(
          request_id: "transport-isolation",
          attempt_id: "transport-isolation-http",
          profile: @profile,
          chain_id: @chain,
          upstream_instance_id: instance_id,
          transport: :http,
          route_generation: generation,
          circuit_scope: :broad,
          circuit_epoch: 1,
          execution_safety: :replay_safe,
          routing_intent: "default",
          workload_key: "default",
          request_budget_ms: 100,
          candidate_admission_count: 1,
          dispatch_count: 1
        )

      for stamp <- 1..3 do
        fact = AttemptTerminal.InvalidResponse.new(identity, :invalid_json, 10)
        event = %{AttemptProjection.new(fact, "p2", "eth_call") | emitted_at_us: stamp}
        assert :ok = AttemptProjection.apply_control(event)
      end

      [candidate] =
        CandidateListing.list_candidates(@profile, @chain, %{protocol: :http})
        |> Enum.filter(&(&1.id == "p2"))

      assert candidate.availability == :up
      assert candidate.transport_availability.http == :down
      assert candidate.transport_availability.ws == :up
    end
  end

  # Helpers

  defp register_chain(profile, chain, providers) do
    ConfigStore.register_chain_runtime(profile, chain, %{
      chain_id: chain,
      name: "cl_test_chain",
      providers: providers
    })
  end

  defp set_circuit_state(instance_id, transport, state, recovery_deadline_ms \\ nil) do
    Snapshot.put(%Snapshot{
      breaker_id: {instance_id, transport},
      state: state,
      generation: 1,
      epoch: 1,
      owner_pid: self(),
      ready?: true,
      recovery_deadline_us: recovery_deadline_ms && recovery_deadline_ms * 1_000,
      half_open_capacity: 1,
      half_open_inflight: 0,
      control_health: :healthy
    })
  end

  defp set_rate_limited(instance_id, transport) do
    expiry = System.monotonic_time(:millisecond) + 60_000

    :ets.insert(@instance_table, {
      {:rate_limit, instance_id, transport},
      %{expiry_ms: expiry}
    })
  end

  defp set_health_status(instance_id, status) do
    :ets.insert(@instance_table, {
      {:health_probe, instance_id},
      %{
        status: status,
        http_status: status,
        last_health_check: System.system_time(:millisecond),
        consecutive_failures: 0,
        last_error: nil
      }
    })
  end

  defp clean_instance_state do
    providers = Catalog.get_profile_providers(@profile, @chain)

    Enum.each(providers, fn pp ->
      :ets.delete(@instance_table, {:circuit, pp.instance_id, :http})
      :ets.delete(@instance_table, {:circuit, pp.instance_id, :ws})
      :ets.delete(Storage.snapshot_table(), {pp.instance_id, :http})
      :ets.delete(Storage.snapshot_table(), {pp.instance_id, :ws})
      :ets.delete(@instance_table, {:rate_limit, pp.instance_id, :http})
      :ets.delete(@instance_table, {:rate_limit, pp.instance_id, :ws})
      :ets.delete(@instance_table, {:health_probe, pp.instance_id})
      :ets.delete(@instance_table, {:health_block_sync, pp.instance_id})
      :ets.delete(@instance_table, {:health_routing, pp.instance_id})
    end)
  rescue
    ArgumentError -> :ok
  end

  defp attempt_identity(instance_id, generation) do
    AttemptIdentity.new(
      request_id: "catalog-generation-test",
      attempt_id: "catalog-attempt-#{generation}",
      profile: @profile,
      chain_id: @chain,
      upstream_instance_id: instance_id,
      transport: :http,
      route_generation: generation,
      circuit_scope: :broad,
      circuit_epoch: 1,
      execution_safety: :replay_safe,
      routing_intent: "default",
      workload_key: "default",
      request_budget_ms: 100,
      candidate_admission_count: 1,
      dispatch_count: 1
    )
  end

  defp assert_publication_phase(ref, phase, generation) do
    assert_receive {:catalog_publication_phase, owner, ^ref, ^phase, ^generation}, 1_000
    assert owner == Process.whereis(Catalog.Owner)
  end

  defp continue_publication(ref, phase) do
    send(Process.whereis(Catalog.Owner), {:catalog_publication_continue, ref, phase})
  end
end
