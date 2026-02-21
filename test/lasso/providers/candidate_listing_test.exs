defmodule Lasso.Providers.CandidateListingTest do
  use ExUnit.Case, async: false

  alias Lasso.Config.ConfigStore
  alias Lasso.Providers.{Catalog, CandidateListing}

  @profile "cl_test"
  @chain "cl_test_chain"
  @config_table :lasso_config_store
  @instance_table :lasso_instance_state

  setup do
    original_profiles = ConfigStore.list_profiles()

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

    on_exit(fn ->
      clean_instance_state()
      ConfigStore.unregister_chain_runtime(@profile, @chain)
      :ets.insert(@config_table, {{:profile_list}, original_profiles})
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

    test "returns empty list for unknown profile" do
      assert CandidateListing.list_candidates("nonexistent", @chain, %{}) == []
    end

    test "returns empty list for unknown chain" do
      assert CandidateListing.list_candidates(@profile, "nonexistent", %{}) == []
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

  defp set_circuit_state(instance_id, transport, state, recovery_deadline_ms \\ nil) do
    :ets.insert(@instance_table, {
      {:circuit, instance_id, transport},
      %{state: state, error: nil, recovery_deadline_ms: recovery_deadline_ms}
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
      {:health, instance_id},
      %{
        status: status,
        http_status: status,
        ws_status: nil,
        last_health_check: System.system_time(:millisecond),
        consecutive_failures: 0,
        consecutive_successes: 0,
        last_error: nil
      }
    })
  end

  defp clean_instance_state do
    providers = Catalog.get_profile_providers(@profile, @chain)

    Enum.each(providers, fn pp ->
      :ets.delete(@instance_table, {:circuit, pp.instance_id, :http})
      :ets.delete(@instance_table, {:circuit, pp.instance_id, :ws})
      :ets.delete(@instance_table, {:rate_limit, pp.instance_id, :http})
      :ets.delete(@instance_table, {:rate_limit, pp.instance_id, :ws})
      :ets.delete(@instance_table, {:health, pp.instance_id})
    end)
  rescue
    ArgumentError -> :ok
  end
end
