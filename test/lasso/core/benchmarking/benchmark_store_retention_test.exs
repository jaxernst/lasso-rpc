defmodule Lasso.Benchmarking.BenchmarkStoreRetentionTest do
  use ExUnit.Case, async: false

  alias Lasso.Benchmarking.BenchmarkStore
  alias Lasso.RPC.Metrics.BenchmarkStore, as: MetricsAdapter
  alias LassoWeb.Dashboard.MetricsHelpers

  setup do
    suffix = System.unique_integer([:positive]) |> Integer.to_string()
    profile = "retention-profile-" <> suffix
    chain = System.unique_integer([:positive])

    on_exit(fn -> BenchmarkStore.clear_chain_metrics(profile, chain) end)

    %{profile: profile, chain: chain}
  end

  test "retention stays at the configured limit under sustained ingress", context do
    %{profile: profile, chain: chain} = context
    %{limit: limit} = BenchmarkStore.get_retention_stats(profile, chain)
    call_count = limit * 3 + 117

    record_calls(profile, chain, call_count)
    performance = BenchmarkStore.get_rpc_performance(profile, chain, "provider", "eth_call")

    assert BenchmarkStore.get_retention_stats(profile, chain) == %{
             retained: limit,
             dropped: call_count - limit,
             limit: limit
           }

    assert performance.total_calls == call_count
  end

  test "routing metrics and dashboard read the registered table for a file-profile chain",
       context do
    %{profile: profile, chain: chain} = context

    assert :ok =
             MetricsAdapter.record_request(
               profile,
               chain,
               "provider",
               "eth_call",
               12,
               :success,
               transport: :http
             )

    assert BenchmarkStore.get_rpc_performance(profile, chain, "provider", "eth_call@http").total_calls ==
             1

    assert %{{"provider", "eth_call", :http} => %{total_calls: 1}} =
             MetricsAdapter.batch_get_transport_performance(profile, chain, [
               {"provider", "eth_call", :http}
             ])

    assert MetricsHelpers.get_windowed_success_rate_from_ets(profile, chain) == 100.0
  end

  test "diagnostic ingress is bounded while the store cannot consume", context do
    %{profile: profile, chain: chain} = context
    owner = Process.whereis(BenchmarkStore)
    :sys.get_state(owner)
    %{limit: limit, dropped: before_dropped} = BenchmarkStore.ingress_stats()
    :ok = :sys.suspend(owner)

    try do
      record_calls(profile, chain, limit * 3)
      assert %{queued: ^limit, dropped: dropped} = BenchmarkStore.ingress_stats()
      assert dropped == before_dropped + limit * 2
      assert {:message_queue_len, queued} = Process.info(owner, :message_queue_len)
      assert queued <= limit + 2
    after
      :sys.resume(owner)
    end

    :sys.get_state(owner)
    assert BenchmarkStore.ingress_stats().queued == 0
  end

  test "distinct caller methods cannot exceed score cardinality and admitted scores keep updating",
       context do
    %{profile: profile, chain: chain} = context
    %{limit: limit} = BenchmarkStore.get_score_retention_stats(profile, chain)
    BenchmarkStore.record_rpc_call(profile, chain, "provider", "eth_call", 10, :success)

    for index <- 1..(limit + 100) do
      BenchmarkStore.record_rpc_call(profile, chain, "provider", "unknown_#{index}", 1, :error)
    end

    BenchmarkStore.record_rpc_call(profile, chain, "provider", "eth_call", 20, :success)
    performance = BenchmarkStore.get_rpc_performance(profile, chain, "provider", "eth_call")

    assert performance.total_calls == 2

    assert %{retained: ^limit, dropped: 101, limit: ^limit} =
             BenchmarkStore.get_score_retention_stats(profile, chain)

    assert BenchmarkStore.get_retention_stats(profile, chain).retained <=
             BenchmarkStore.get_retention_stats(profile, chain).limit

    assert :ok = BenchmarkStore.clear_chain_metrics(profile, chain)
    assert %{retained: 0, dropped: 0} = BenchmarkStore.get_score_retention_stats(profile, chain)
  end

  test "profile and chain churn reclaims tables without creating identity atoms", context do
    %{profile: profile, chain: chain} = context

    identities =
      Enum.map(1..50, fn index ->
        {profile <> "-" <> Integer.to_string(index), chain + index}
      end)

    table_ids =
      Enum.map(identities, fn {churn_profile, churn_chain} ->
        atom_names = dynamic_table_atom_names(churn_profile, churn_chain)

        Enum.each(atom_names, fn name ->
          assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
        end)

        record_calls(churn_profile, churn_chain, 1)
        BenchmarkStore.get_rpc_performance(churn_profile, churn_chain, "provider", "eth_call")

        score_table = BenchmarkStore.score_table(churn_profile, churn_chain)
        assert score_table != :undefined
        assert :ets.info(score_table) != :undefined

        [{{:rpc, ^churn_profile, ^churn_chain}, rpc_table}] =
          :ets.lookup(:lasso_benchmark_table_registry, {:rpc, churn_profile, churn_chain})

        assert :ok = BenchmarkStore.clear_chain_metrics(churn_profile, churn_chain)
        assert BenchmarkStore.score_table(churn_profile, churn_chain) == :undefined
        assert BenchmarkStore.get_retention_stats(churn_profile, churn_chain).retained == 0

        assert :ets.lookup(
                 :lasso_benchmark_table_registry,
                 {:rpc, churn_profile, churn_chain}
               ) == []

        Enum.each(atom_names, fn name ->
          assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
        end)

        [rpc_table, score_table]
      end)
      |> List.flatten()

    assert Enum.all?(table_ids, &(:ets.info(&1) == :undefined))
  end

  test "retention telemetry reports retained, dropped, and cleanup work", context do
    %{profile: profile, chain: chain} = context
    handler_id = {__MODULE__, self()}
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:lasso, :benchmark_store, :retention],
        fn event, measurements, metadata, pid ->
          send(pid, {:retention_telemetry, event, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    %{limit: limit} = BenchmarkStore.get_retention_stats(profile, chain)
    call_count = limit + 23
    record_calls(profile, chain, call_count)

    send(BenchmarkStore, :report_retention)
    BenchmarkStore.get_rpc_performance(profile, chain, "provider", "eth_call")

    assert_receive {:retention_telemetry, [:lasso, :benchmark_store, :retention], measurements,
                    %{profile: ^profile, chain: ^chain} = metadata}

    assert measurements == %{retained: limit, dropped: 23, cleanup_work: 23}
    assert metadata == %{profile: profile, chain: chain, limit: limit}

    send(BenchmarkStore, :report_retention)
    BenchmarkStore.get_rpc_performance(profile, chain, "provider", "eth_call")

    assert_receive {:retention_telemetry, [:lasso, :benchmark_store, :retention], measurements,
                    ^metadata}

    assert measurements.cleanup_work == 0
    assert measurements.dropped == 23
  end

  defp record_calls(profile, chain, count) do
    Enum.each(1..count, fn duration ->
      BenchmarkStore.record_rpc_call(
        profile,
        chain,
        "provider",
        "eth_call",
        duration,
        :success
      )
    end)
  end

  defp dynamic_table_atom_names(profile, chain) do
    [
      "rpc_metrics_#{profile}_#{chain}",
      "provider_scores_#{profile}_#{chain}"
    ]
  end
end
