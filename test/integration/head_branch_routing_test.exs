defmodule Lasso.RPC.HeadBranchRoutingTest do
  use Lasso.Test.LassoIntegrationCase

  alias Lasso.BlockSync.Registry
  alias Lasso.RPC.{AttemptIdentity, AttemptProjection, AttemptTerminal}
  alias Lasso.Core.Support.CircuitBreaker.Snapshot
  alias Lasso.Config.ConfigStore
  alias Lasso.Providers.Catalog
  alias Lasso.RPC.Selection
  alias Lasso.RPC.Selection.CandidateCursor

  test "a minority WebSocket branch is not the first route", %{chain: chain} do
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

    for {provider, hash} <- [{minority, "0xbbb"}, {majority_a, "0xaaa"}] do
      instance_id = Catalog.lookup_instance_id(profile, chain, provider)
      assert :ok = Registry.put_height(chain, instance_id, 100, :ws, %{hash: hash})
    end

    ambiguous =
      Selection.select_channel_candidates(profile, chain, "eth_blockNumber",
        strategy: :priority,
        transport: :ws
      )

    assert ambiguous.filters.head_snapshot.qualification == :ambiguous
    assert {:ok, %{provider_id: ^minority}, _} = CandidateCursor.next(ambiguous)

    instance_id = Catalog.lookup_instance_id(profile, chain, majority_b)
    assert :ok = Registry.put_height(chain, instance_id, 100, :ws, %{hash: "0xaaa"})

    cursor =
      Selection.select_channel_candidates(profile, chain, "eth_blockNumber",
        strategy: :priority,
        transport: :ws
      )

    assert cursor.filters.head_snapshot.qualification == :qualified
    assert {:ok, %{provider_id: ^majority_a}, _} = CandidateCursor.next(cursor)

    # A cached fastest hint must be assessed against the complete route set.
    # The minority is fastest, but it is on a conflicting branch.
    generation = Catalog.active_generation()
    now_us = System.monotonic_time(:microsecond)

    for {provider, index} <- Enum.with_index([minority, majority_a, majority_b]) do
      instance_id = Catalog.lookup_instance_id(profile, chain, provider)

      for offset <- 0..2 do
        emitted_at_us = now_us + index * 10 + offset

        identity =
          AttemptIdentity.new(
            request_id: "head-fastest-request",
            attempt_id: "head-fastest-attempt-#{emitted_at_us}",
            profile: profile,
            chain_id: chain,
            upstream_instance_id: instance_id,
            transport: :ws,
            route_generation: generation,
            circuit_scope: :broad,
            circuit_epoch: 1,
            execution_safety: :replay_safe,
            routing_intent: "fastest",
            workload_key: "client",
            request_budget_ms: 100,
            candidate_admission_count: 1,
            dispatch_count: 1
          )

        fact =
          AttemptTerminal.Response.new(
            identity,
            :success,
            if(index == 0, do: 10_000, else: 100_000)
          )

        assert :ok =
                 AttemptProjection.apply_control(%{
                   AttemptProjection.new(fact, provider, "eth_blockNumber")
                   | emitted_at_us: emitted_at_us
                 })
      end
    end

    minority_id = Catalog.lookup_instance_id(profile, chain, minority)
    scope = AttemptProjection.scope_state(profile, chain)
    assert %{route: {^minority_id, :ws}} = AttemptProjection.fastest_winner(scope)

    fastest =
      Selection.select_channel_candidates(profile, chain, "eth_blockNumber",
        strategy: :fastest,
        transport: :ws
      )

    assert {:ok, %{provider_id: selected}, _} = CandidateCursor.next(fastest)
    assert selected in [majority_a, majority_b]

    # Hard exclusions must be applied before deciding the all-routes fallback.
    for strategy <- [:priority, :load_balanced] do
      restricted =
        Selection.select_channel_candidates(profile, chain, "eth_blockNumber",
          strategy: strategy,
          transport: :ws,
          exclude: [majority_a, majority_b]
        )

      assert {:ok, %{provider_id: ^minority}, _} = CandidateCursor.next(restricted)
    end

    assert {:ok, http_snapshot} = Snapshot.lookup({minority_id, :http})
    assert true = Snapshot.put(%{http_snapshot | state: :open, epoch: http_snapshot.epoch + 1})

    for strategy <- [:priority, :load_balanced, :fastest, :balanced_fast] do
      restricted =
        Selection.select_channel_candidates(profile, chain, "eth_blockNumber",
          strategy: strategy,
          transport: :both,
          exclude: [majority_a, majority_b]
        )

      assert {:ok, %{provider_id: ^minority, transport: :ws}, _} =
               CandidateCursor.next(restricted)
    end

    # A snapshot that is not ready is just as unusable as an open circuit.
    assert true =
             Snapshot.put(%{
               http_snapshot
               | state: :closed,
                 ready?: false,
                 epoch: http_snapshot.epoch + 2
             })

    for strategy <- [:priority, :load_balanced, :fastest, :balanced_fast] do
      restricted =
        Selection.select_channel_candidates(profile, chain, "eth_blockNumber",
          strategy: strategy,
          transport: :both,
          exclude: [majority_a, majority_b]
        )

      assert {:ok, %{provider_id: ^minority, transport: :ws}, _} =
               CandidateCursor.next(restricted)
    end

    assert :ok = Registry.put_height(chain, minority_id, 90, :ws, %{hash: "0xbbb"})

    for strategy <- [:priority, :load_balanced] do
      restricted =
        Selection.select_channel_candidates(profile, chain, "eth_blockNumber",
          strategy: strategy,
          transport: :ws,
          exclude: [majority_a, majority_b]
        )

      assert {:ok, %{provider_id: ^minority}, _} = CandidateCursor.next(restricted)
    end

    for strategy <- [:priority, :load_balanced, :fastest, :balanced_fast] do
      restricted =
        Selection.select_channel_candidates(profile, chain, "eth_blockNumber",
          strategy: strategy,
          transport: :both,
          exclude: [majority_a, majority_b]
        )

      assert {:ok, %{provider_id: ^minority, transport: :ws}, _} =
               CandidateCursor.next(restricted)
    end
  end

  test "head fallback keeps the sole method-capable minority branch", %{chain: chain} do
    profile = "public"

    assert :ok =
             ConfigStore.register_chain_runtime(profile, chain, %{
               block_time_ms: 1_000,
               selection: %{max_lag_blocks: 2},
               providers: []
             })

    suffix = Integer.to_string(chain)
    minority = "minority-capable-#{suffix}"
    majority_a = "majority-refusing-a-#{suffix}"
    majority_b = "majority-refusing-b-#{suffix}"
    refuses_balance = %{unsupported_methods: ["eth_getBalance"]}

    setup_providers(
      [
        %{id: minority, priority: 1},
        %{id: majority_a, priority: 2, capabilities: refuses_balance},
        %{id: majority_b, priority: 3, capabilities: refuses_balance}
      ],
      provider_type: :ws
    )

    for {provider, hash} <- [
          {minority, "0xbbb"},
          {majority_a, "0xaaa"},
          {majority_b, "0xaaa"}
        ] do
      instance_id = Catalog.lookup_instance_id(profile, chain, provider)
      assert :ok = Registry.put_height(chain, instance_id, 100, :ws, %{hash: hash})
    end

    for strategy <- [:priority, :load_balanced, :fastest, :balanced_fast] do
      cursor =
        Selection.select_channel_candidates(profile, chain, "eth_getBalance",
          strategy: strategy,
          transport: :ws
        )

      assert cursor.filters.head_snapshot.qualification == :qualified
      assert {:ok, %{provider_id: ^minority}, _} = CandidateCursor.next(cursor)
    end

    cursor =
      Selection.select_channel_candidates(profile, chain, "eth_getBalance",
        strategy: :priority,
        transport: :ws,
        exclude: [minority]
      )

    assert {:ok, %{provider_id: selected}, _} = CandidateCursor.next(cursor)
    assert selected in [majority_a, majority_b]
  end
end
