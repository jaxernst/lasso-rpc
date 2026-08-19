defmodule Lasso.RPC.SelectionTest do
  @moduledoc """
  Strategy-agnostic tests for the Selection module.

  Tests the core coordinator responsibilities:
  - Context validation
  - Filter handling (exclude, protocol)
  - CandidateListing integration
  - Error handling
  - Telemetry emission
  - Metadata enrichment

  NOTE: Strategy-specific logic (priority, fastest, cheapest, etc.) is NOT tested here
  as strategies are subject to change and extension. Test those in strategy-specific files.
  """

  use Lasso.Test.LassoIntegrationCase

  alias Lasso.Providers.Catalog
  alias Lasso.RPC.{AttemptIdentity, AttemptProjection, AttemptTerminal, Selection}
  alias Lasso.RPC.Selection.CandidateCursor

  defmodule CatalogSwapStrategy do
    @behaviour Lasso.RPC.Strategy

    @impl true
    def prepare_context(_profile, chain_id, _method, timeout) do
      Lasso.RPC.StrategyContext.new(chain_id, timeout)
    end

    @impl true
    def rank_channels(channels, _method, _context, _profile, _chain_id) do
      :ok = Lasso.Providers.Catalog.build_from_config()
      channels
    end
  end

  defmodule ContextCaptureStrategy do
    @behaviour Lasso.RPC.Strategy

    alias Lasso.RPC.StrategyContext

    @impl true
    def prepare_context(_profile, chain_id, _method, timeout) do
      StrategyContext.new(chain_id, timeout)
    end

    @impl true
    def rank_channels(channels, _method, context, _profile, _chain_id) do
      send(
        Application.fetch_env!(:lasso, :selection_context_test_pid),
        {:strategy_context, context}
      )

      channels
    end
  end

  describe "select_provider/3 - filter handling" do
    test "respects exclude filter", %{chain: chain} do
      profile = "public"

      setup_providers([
        %{id: "provider_1", priority: 10, behavior: :healthy, profile: profile},
        %{id: "provider_2", priority: 20, behavior: :healthy, profile: profile},
        %{id: "provider_3", priority: 30, behavior: :healthy, profile: profile}
      ])

      # Select without exclusions
      {:ok, selected1} = Selection.select_provider(profile, chain, "eth_blockNumber")
      assert selected1 in ["provider_1", "provider_2", "provider_3"]

      # Select with exclusion
      {:ok, selected2} =
        Selection.select_provider(profile, chain, "eth_blockNumber", exclude: [selected1])

      assert selected2 != selected1
      assert selected2 in ["provider_1", "provider_2", "provider_3"]
    end

    test "respects protocol filter for http", %{chain: chain} do
      profile = "public"

      setup_providers([
        %{id: "http_only", priority: 10, behavior: :healthy, profile: profile}
      ])

      # HTTP protocol should work
      {:ok, selected} =
        Selection.select_provider(profile, chain, "eth_blockNumber", protocol: :http)

      assert selected == "http_only"
    end

    test "combines exclude and protocol filters", %{chain: chain} do
      profile = "public"

      setup_providers([
        %{id: "provider_1", priority: 10, behavior: :healthy, profile: profile},
        %{id: "provider_2", priority: 20, behavior: :healthy, profile: profile}
      ])

      # Exclude provider_1 and use HTTP protocol
      {:ok, selected} =
        Selection.select_provider(profile, chain, "eth_blockNumber",
          exclude: ["provider_1"],
          protocol: :http
        )

      assert selected == "provider_2"
    end

    test "excludes half-open provider when include_half_open is false", %{chain: chain} do
      profile = "public"

      setup_providers([
        %{id: "provider_1", priority: 10, behavior: :healthy, profile: profile},
        %{id: "provider_2", priority: 20, behavior: :healthy, profile: profile}
      ])

      [provider_1, provider_2] =
        Enum.map(["provider_1", "provider_2"], fn provider_id ->
          Lasso.Providers.Catalog.lookup_instance_id(profile, chain, provider_id)
        end)

      set_circuit_snapshot(provider_1, :half_open)
      set_circuit_snapshot(provider_2, :closed)

      assert {:error, :no_providers_available} =
               Selection.select_provider(profile, chain, "eth_blockNumber",
                 protocol: :http,
                 strategy: :priority,
                 exclude: ["provider_2"],
                 include_half_open: false
               )
    end

    test "includes half-open provider when include_half_open is true", %{chain: chain} do
      profile = "public"

      setup_providers([
        %{id: "provider_1", priority: 10, behavior: :healthy, profile: profile},
        %{id: "provider_2", priority: 20, behavior: :healthy, profile: profile}
      ])

      [provider_1, provider_2] =
        Enum.map(["provider_1", "provider_2"], fn provider_id ->
          Lasso.Providers.Catalog.lookup_instance_id(profile, chain, provider_id)
        end)

      set_circuit_snapshot(provider_1, :half_open)
      set_circuit_snapshot(provider_2, :closed)

      {:ok, selected} =
        Selection.select_provider(profile, chain, "eth_blockNumber",
          protocol: :http,
          strategy: :priority,
          exclude: ["provider_2"],
          include_half_open: true
        )

      assert selected == "provider_1"
    end
  end

  describe "select_provider/3 - error handling" do
    test "returns error when no providers available", %{chain: chain} do
      profile = "public"
      # Don't setup any providers

      assert {:error, :no_providers_available} =
               Selection.select_provider(profile, chain, "eth_blockNumber")
    end

    test "returns error when all providers excluded", %{chain: chain} do
      profile = "public"

      setup_providers([
        %{id: "provider_1", priority: 10, behavior: :healthy, profile: profile}
      ])

      assert {:error, :no_providers_available} =
               Selection.select_provider(profile, chain, "eth_blockNumber",
                 exclude: ["provider_1"]
               )
    end

    test "returns error for invalid chain" do
      profile = "public"
      # Non-existent chain with no providers
      assert {:error, :no_providers_available} =
               Selection.select_provider(profile, 999_999_999, "eth_blockNumber")
    end
  end

  describe "select_provider/3 - observer isolation" do
    test "selects successfully without synchronous selection telemetry", %{chain: chain} do
      profile = "public"

      setup_providers([
        %{id: "provider_1", priority: 10, behavior: :healthy, profile: profile}
      ])

      ref =
        :telemetry_test.attach_event_handlers(self(), [[:lasso, :selection, :success]])

      try do
        assert {:ok, "provider_1"} =
                 Selection.select_provider(profile, chain, "eth_blockNumber")

        refute_receive {[:lasso, :selection, :success], ^ref, _, _}, 50
      after
        :telemetry.detach(ref)
      end
    end

    test "single-channel fastest selection records unqualified evidence degradation", %{
      chain: chain
    } do
      profile = "public"

      setup_providers([
        %{id: "provider_1", priority: 10, behavior: :healthy, profile: profile}
      ])

      before_count =
        AttemptProjection.availability_degradation_count(
          profile,
          chain,
          :fastest,
          :default
        )

      assert [%{provider_id: "provider_1"}] =
               Selection.select_channels(profile, chain, "eth_blockNumber",
                 strategy: :fastest,
                 transport: :http
               )

      assert AttemptProjection.availability_degradation_count(
               profile,
               chain,
               :fastest,
               :default
             ) == before_count + 1
    end

    test "fastest selection consumes a shared physical system prior", %{chain: chain} do
      profile = "public"

      setup_providers([
        %{id: "a_slow", priority: 10, behavior: :healthy, profile: profile},
        %{id: "z_fast", priority: 20, behavior: :healthy, profile: profile}
      ])

      generation = Catalog.active_generation()
      instance_id = Catalog.lookup_instance_id(profile, chain, "z_fast")

      source_route = %{
        profile: "poller-profile",
        chain_id: chain,
        instance_id: instance_id,
        transport: :http
      }

      :ok =
        AttemptProjection.prepare_routes(
          generation,
          [source_route | Catalog.routing_control_routes()]
        )

      now_us = System.monotonic_time(:microsecond)

      for offset <- 0..2 do
        event =
          system_success_event(
            chain,
            instance_id,
            generation,
            now_us + offset,
            10_000
          )

        assert :ok = AttemptProjection.apply_control(event)
      end

      public_scope = AttemptProjection.scope_state(profile, chain, generation)
      assert is_nil(AttemptProjection.route_state(public_scope, instance_id, :http, "system"))

      assert {:ok, "z_fast"} =
               Selection.select_provider(profile, chain, "eth_blockNumber",
                 strategy: :fastest,
                 protocol: :http,
                 request_origin: :client
               )

      assert [%{provider_id: "z_fast"} | _rest] =
               Selection.select_channels(profile, chain, "eth_blockNumber",
                 strategy: :fastest,
                 transport: :http,
                 request_origin: :client
               )
    end

    test "same-generation catalog swaps during ranking fail both entrypoints closed", %{
      chain: chain
    } do
      profile = "public"

      setup_providers([
        %{id: "snapshot_provider", priority: 10, behavior: :healthy, profile: profile}
      ])

      previous_registry = Application.get_env(:lasso, :strategy_registry)

      Application.put_env(
        :lasso,
        :strategy_registry,
        Map.put(
          Lasso.RPC.Strategies.Registry.default_registry(),
          :snapshot_swap,
          CatalogSwapStrategy
        )
      )

      on_exit(fn ->
        if previous_registry,
          do: Application.put_env(:lasso, :strategy_registry, previous_registry),
          else: Application.delete_env(:lasso, :strategy_registry)
      end)

      provider_snapshot = Lasso.Providers.Catalog.snapshot()

      assert {:error, :no_providers_available} =
               Selection.select_provider(profile, chain, "eth_blockNumber",
                 strategy: :snapshot_swap,
                 protocol: :http
               )

      after_provider = Lasso.Providers.Catalog.snapshot()
      assert after_provider.generation == provider_snapshot.generation
      refute after_provider.table == provider_snapshot.table

      assert [] ==
               Selection.select_channels(profile, chain, "eth_blockNumber",
                 strategy: :snapshot_swap,
                 transport: :http
               )

      after_channels = Lasso.Providers.Catalog.snapshot()
      assert after_channels.generation == after_provider.generation
      refute after_channels.table == after_provider.table

      assert {:ok, "snapshot_provider"} =
               Selection.select_provider(profile, chain, "eth_blockNumber",
                 strategy: :priority,
                 protocol: :http
               )

      assert [%{provider_id: "snapshot_provider"}] =
               Selection.select_channels(profile, chain, "eth_blockNumber",
                 strategy: :priority,
                 transport: :http
               )
    end

    test "custom strategies retain the complete routing context", %{chain: chain} do
      profile = "public"

      setup_providers([
        %{id: "context_provider", priority: 10, behavior: :healthy, profile: profile}
      ])

      previous_registry = Application.get_env(:lasso, :strategy_registry)
      previous_pid = Application.get_env(:lasso, :selection_context_test_pid)

      Application.put_env(
        :lasso,
        :strategy_registry,
        Map.put(
          Lasso.RPC.Strategies.Registry.default_registry(),
          :context_capture,
          ContextCaptureStrategy
        )
      )

      Application.put_env(:lasso, :selection_context_test_pid, self())

      on_exit(fn ->
        restore_env(:strategy_registry, previous_registry)
        restore_env(:selection_context_test_pid, previous_pid)
      end)

      assert {:ok, "context_provider"} =
               Selection.select_provider(profile, chain, "eth_blockNumber",
                 strategy: :context_capture,
                 protocol: :http
               )

      assert_receive {:strategy_context,
                      %{routing_summaries: summaries, provider_priorities: priorities}}

      assert map_size(summaries) == 1
      assert priorities == %{"context_provider" => 10}
    end
  end

  describe "select_channels/4 - archival filtering" do
    test "excludes non-archival providers for historical eth_getLogs requests", %{chain: chain} do
      profile = "public"

      # Setup providers with archival: false
      setup_providers([
        %{id: "provider_1", priority: 10, behavior: :healthy, profile: profile, archival: false},
        %{id: "provider_2", priority: 20, behavior: :healthy, profile: profile, archival: false}
      ])

      params = [%{"fromBlock" => "earliest", "toBlock" => "earliest"}]

      # Should return empty list - no archival providers available
      channels = Selection.select_channels(profile, chain, "eth_getLogs", params: params)

      assert channels == []
    end

    test "includes archival providers for historical eth_getLogs requests", %{chain: chain} do
      profile = "public"

      # Setup one archival and one non-archival provider
      setup_providers([
        %{id: "archival", priority: 10, behavior: :healthy, profile: profile, archival: true},
        %{id: "non_archival", priority: 20, behavior: :healthy, profile: profile, archival: false}
      ])

      params = [%{"fromBlock" => "earliest", "toBlock" => "earliest"}]

      # Should return only the archival provider
      channels = Selection.select_channels(profile, chain, "eth_getLogs", params: params)

      assert length(channels) == 1
      channel = hd(channels)
      assert channel.provider_id == "archival"
    end

    test "includes all providers for recent eth_getLogs requests", %{chain: chain} do
      profile = "public"

      setup_providers([
        %{id: "provider_1", priority: 10, behavior: :healthy, profile: profile, archival: false},
        %{id: "provider_2", priority: 20, behavior: :healthy, profile: profile, archival: true}
      ])

      # Recent request using "latest"
      params = [%{"fromBlock" => "latest", "toBlock" => "latest"}]

      # Should return both providers - archival not required
      channels = Selection.select_channels(profile, chain, "eth_getLogs", params: params)

      assert length(channels) == 2
      provider_ids = Enum.map(channels, & &1.provider_id)
      assert "provider_1" in provider_ids
      assert "provider_2" in provider_ids
    end
  end

  describe "lazy execution candidates" do
    test "priority materializes later candidates only when requested", %{chain: chain} do
      profile = "public"

      setup_providers([
        %{id: "first", priority: 10, behavior: :healthy, profile: profile},
        %{id: "second", priority: 20, behavior: :healthy, profile: profile}
      ])

      cursor =
        Selection.select_channel_candidates(profile, chain, "eth_blockNumber",
          strategy: :priority,
          transport: :http,
          limit: 10
        )

      assert {:ok, %{provider_id: "first"}, cursor} = CandidateCursor.next(cursor)

      second_instance = Catalog.lookup_instance_id(profile, chain, "second")
      set_circuit_snapshot(second_instance, :open)

      assert :done = CandidateCursor.next(cursor)
    end

    test "closed candidates remain ahead of earlier half-open candidates", %{chain: chain} do
      profile = "public"

      setup_providers([
        %{id: "half_open", priority: 10, behavior: :healthy, profile: profile},
        %{id: "closed", priority: 20, behavior: :healthy, profile: profile}
      ])

      half_open_instance = Catalog.lookup_instance_id(profile, chain, "half_open")
      set_circuit_snapshot(half_open_instance, :half_open)

      cursor =
        Selection.select_channel_candidates(profile, chain, "eth_blockNumber",
          strategy: :priority,
          transport: :http,
          include_half_open: true
        )

      assert {:ok, %{provider_id: "closed"}, cursor} = CandidateCursor.next(cursor)
      assert {:ok, %{provider_id: "half_open"}, cursor} = CandidateCursor.next(cursor)
      assert :done = CandidateCursor.next(cursor)
    end

    test "catalog pointer changes invalidate a cursor", %{chain: chain} do
      profile = "public"

      setup_providers([
        %{id: "provider", priority: 10, behavior: :healthy, profile: profile}
      ])

      cursor =
        Selection.select_channel_candidates(profile, chain, "eth_blockNumber",
          strategy: :priority,
          transport: :http
        )

      :ok = Catalog.build_from_config()

      assert :stale = CandidateCursor.next(cursor)
    end

    test "candidate limits bound incremental fallback", %{chain: chain} do
      profile = "public"

      setup_providers([
        %{id: "first", priority: 10, behavior: :healthy, profile: profile},
        %{id: "second", priority: 20, behavior: :healthy, profile: profile}
      ])

      cursor =
        Selection.select_channel_candidates(profile, chain, "eth_blockNumber",
          strategy: :priority,
          transport: :http,
          limit: 1
        )

      assert {:ok, %{provider_id: "first"}, cursor} = CandidateCursor.next(cursor)
      assert :done = CandidateCursor.next(cursor)
    end

    test "evidence-driven strategies retain the eager channel list", %{chain: chain} do
      profile = "public"

      setup_providers([
        %{id: "provider", priority: 10, behavior: :healthy, profile: profile}
      ])

      assert [%Lasso.RPC.Channel{}] =
               Selection.select_channel_candidates(profile, chain, "eth_blockNumber",
                 strategy: :fastest,
                 transport: :http
               )
    end
  end

  defp set_circuit_snapshot(instance_id, state) do
    alias Lasso.Core.Support.CircuitBreaker.Snapshot

    {:ok, current} = Snapshot.lookup({instance_id, :http})
    Snapshot.put(%{current | state: state, control_health: :healthy})
  end

  defp restore_env(key, nil), do: Application.delete_env(:lasso, key)
  defp restore_env(key, value), do: Application.put_env(:lasso, key, value)

  defp system_success_event(chain, instance_id, generation, emitted_at_us, duration_us) do
    identity =
      AttemptIdentity.new(
        request_id: "selection-system-request",
        attempt_id: "selection-system-attempt-#{emitted_at_us}",
        profile: "poller-profile",
        chain_id: chain,
        upstream_instance_id: instance_id,
        transport: :http,
        route_generation: generation,
        circuit_scope: :broad,
        circuit_epoch: 1,
        execution_safety: :replay_safe,
        routing_intent: "fastest",
        workload_key: "system",
        request_budget_ms: 100,
        candidate_admission_count: 1,
        dispatch_count: 1
      )

    fact = AttemptTerminal.Response.new(identity, :success, duration_us)
    %{AttemptProjection.new(fact, "z_fast", "eth_blockNumber") | emitted_at_us: emitted_at_us}
  end
end
