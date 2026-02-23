defmodule LassoWeb.Dashboard.MetricsStoreTest do
  use ExUnit.Case, async: true

  alias LassoWeb.Dashboard.MetricsStore

  describe "aggregate_results(:get_provider_leaderboard, ...)" do
    test "merges entries by provider_id with weighted scores" do
      results = [
        [
          leaderboard_entry("provider_a", 80.0, 100, node: {"us-east", :node1}),
          leaderboard_entry("provider_b", 60.0, 100, node: {"us-east", :node1})
        ],
        [
          leaderboard_entry("provider_a", 90.0, 100, node: {"eu-west", :node2}),
          leaderboard_entry("provider_c", 70.0, 100, node: {"eu-west", :node2})
        ]
      ]

      aggregated = MetricsStore.aggregate_results(:get_provider_leaderboard, results)

      assert length(aggregated) == 3

      provider_a = Enum.find(aggregated, &(&1.provider_id == "provider_a"))
      assert provider_a.score == 85.0
      assert provider_a.node_count == 2
      assert provider_a.total_calls == 200

      provider_b = Enum.find(aggregated, &(&1.provider_id == "provider_b"))
      assert provider_b.score == 60.0
      assert provider_b.node_count == 1

      provider_c = Enum.find(aggregated, &(&1.provider_id == "provider_c"))
      assert provider_c.score == 70.0
      assert provider_c.node_count == 1
    end

    test "sorts results by score descending" do
      results = [
        [
          leaderboard_entry("low", 10.0, 100),
          leaderboard_entry("high", 100.0, 100)
        ],
        [
          leaderboard_entry("mid", 50.0, 100)
        ]
      ]

      aggregated = MetricsStore.aggregate_results(:get_provider_leaderboard, results)

      assert [first, second, third] = aggregated
      assert first.provider_id == "high"
      assert second.provider_id == "mid"
      assert third.provider_id == "low"
    end

    test "handles empty results" do
      assert MetricsStore.aggregate_results(:get_provider_leaderboard, []) == []
    end

    test "handles nested empty lists" do
      assert MetricsStore.aggregate_results(:get_provider_leaderboard, [[], []]) == []
    end

    test "cold_start path for entries below min_calls_threshold" do
      results = [[leaderboard_entry("low_traffic", 80.0, 5)]]

      [entry] = MetricsStore.aggregate_results(:get_provider_leaderboard, results)

      assert entry.provider_id == "low_traffic"
      assert entry.cold_start == true
      assert entry.score == 0.0
      assert entry.total_calls == 5
    end
  end

  describe "aggregate_results(:get_realtime_stats, ...)" do
    test "merges rpc_methods and sums total_entries" do
      results = [
        %{rpc_methods: ["eth_blockNumber", "eth_call"], total_entries: 100},
        %{rpc_methods: ["eth_blockNumber", "eth_getBalance"], total_entries: 150}
      ]

      aggregated = MetricsStore.aggregate_results(:get_realtime_stats, results)

      assert aggregated.total_entries == 250
      assert aggregated.node_count == 2

      assert Enum.sort(aggregated.rpc_methods) == [
               "eth_blockNumber",
               "eth_call",
               "eth_getBalance"
             ]
    end

    test "handles nil results" do
      results = [nil, %{rpc_methods: ["eth_call"], total_entries: 50}, nil]

      aggregated = MetricsStore.aggregate_results(:get_realtime_stats, results)

      assert aggregated.total_entries == 50
      assert aggregated.rpc_methods == ["eth_call"]
      assert aggregated.node_count == 1
    end

    test "handles empty results" do
      aggregated = MetricsStore.aggregate_results(:get_realtime_stats, [])

      assert aggregated.rpc_methods == []
      assert aggregated.total_entries == 0
      assert aggregated.node_count == 0
    end

    test "handles all nil results" do
      aggregated = MetricsStore.aggregate_results(:get_realtime_stats, [nil, nil, nil])

      assert aggregated.rpc_methods == []
      assert aggregated.total_entries == 0
    end

    test "deduplicates rpc_methods across nodes" do
      results = [
        %{rpc_methods: ["eth_call", "eth_call"], total_entries: 10},
        %{rpc_methods: ["eth_call"], total_entries: 20}
      ]

      aggregated = MetricsStore.aggregate_results(:get_realtime_stats, results)

      assert aggregated.rpc_methods == ["eth_call"]
      assert aggregated.total_entries == 30
    end
  end

  describe "aggregate_results(:get_rpc_method_performance_with_percentiles, ...)" do
    test "single result gets stats_by_node" do
      results = [
        method_perf_entry("p1", "eth_call", 100, node: {"us-east", :node1})
      ]

      aggregated =
        MetricsStore.aggregate_results(:get_rpc_method_performance_with_percentiles, results)

      assert aggregated.node_count == 1
      assert [stat] = aggregated.stats_by_node
      assert stat.node_id == "us-east"
      assert stat.total_calls == 100
    end

    test "returns nil when all results are nil" do
      assert MetricsStore.aggregate_results(
               :get_rpc_method_performance_with_percentiles,
               [nil, nil]
             ) == nil
    end

    test "handles empty results" do
      assert MetricsStore.aggregate_results(
               :get_rpc_method_performance_with_percentiles,
               []
             ) == nil
    end

    test "multi-node aggregation with weighted averages" do
      results = [
        method_perf_entry("p1", "eth_call", 100,
          success_rate: 0.90,
          avg_duration_ms: 50.0,
          node: {"us-east", :node1}
        ),
        method_perf_entry("p1", "eth_call", 200,
          success_rate: 0.98,
          avg_duration_ms: 60.0,
          node: {"eu-west", :node2}
        )
      ]

      aggregated =
        MetricsStore.aggregate_results(:get_rpc_method_performance_with_percentiles, results)

      assert aggregated.total_calls == 300
      assert aggregated.node_count == 2
      assert length(aggregated.stats_by_node) == 2
      # Weighted: (100*0.90 + 200*0.98) / 300 = 286/300
      assert_in_delta aggregated.success_rate, 0.9533, 0.001
    end
  end

  describe "aggregate_results(:get_all_method_performance, ...)" do
    test "merges same (provider, method) from multiple nodes" do
      results = [
        [
          method_perf_entry("p1", "eth_call", 100,
            percentiles: %{p50: 45, p95: 80, p99: 120},
            node: {"us-east", :node1}
          )
        ],
        [
          method_perf_entry("p1", "eth_call", 200,
            percentiles: %{p50: 55, p95: 90, p99: 140},
            node: {"eu-west", :node2}
          )
        ]
      ]

      [entry] = MetricsStore.aggregate_results(:get_all_method_performance, results)

      assert entry.provider_id == "p1"
      assert entry.method == "eth_call"
      assert entry.total_calls == 300
      assert entry.node_count == 2
      assert entry.percentiles == %{p50: 55, p95: 90, p99: 140}
      assert length(entry.stats_by_node) == 2
    end

    test "single-node passthrough" do
      results = [
        [
          method_perf_entry("p1", "eth_call", 500,
            percentiles: %{p50: 25, p95: 50, p99: 80},
            node: {"us-east", :node1}
          )
        ]
      ]

      [entry] = MetricsStore.aggregate_results(:get_all_method_performance, results)

      assert entry.total_calls == 500
      assert entry.node_count == 1
      assert entry.percentiles == %{p50: 25, p95: 50, p99: 80}
    end

    test "empty results" do
      assert MetricsStore.aggregate_results(:get_all_method_performance, []) == []
    end

    test "handles nil entries gracefully" do
      results = [
        [nil, method_perf_entry("p1", "eth_call", 10, node: {"x", :n})],
        [nil]
      ]

      assert length(MetricsStore.aggregate_results(:get_all_method_performance, results)) == 1
    end

    test "multiple providers and methods stay separate" do
      results = [
        [
          method_perf_entry("p1", "eth_call", 100, node: {"us", :n1}),
          method_perf_entry("p1", "eth_getBalance", 50, node: {"us", :n1}),
          method_perf_entry("p2", "eth_call", 80, node: {"us", :n1})
        ]
      ]

      aggregated = MetricsStore.aggregate_results(:get_all_method_performance, results)

      assert length(aggregated) == 3
      keys = aggregated |> Enum.map(&{&1.provider_id, &1.method}) |> Enum.sort()
      assert keys == [{"p1", "eth_call"}, {"p1", "eth_getBalance"}, {"p2", "eth_call"}]
    end
  end

  describe "aggregate_results with unknown function" do
    test "returns first result for unknown functions" do
      assert MetricsStore.aggregate_results(:unknown_function, [%{some: "data"}, %{other: "data"}]) ==
               %{some: "data"}
    end

    test "returns nil for empty results" do
      assert MetricsStore.aggregate_results(:unknown_function, []) == nil
    end
  end

  describe "weighted_average/3" do
    test "computes weighted average correctly" do
      entries = [
        %{total_calls: 100, success_rate: 90.0},
        %{total_calls: 200, success_rate: 80.0},
        %{total_calls: 100, success_rate: 70.0}
      ]

      assert MetricsStore.weighted_average(entries, :success_rate, 400) == 80.0
    end

    test "returns 0.0 when total weight is zero" do
      assert MetricsStore.weighted_average(
               [%{total_calls: 100, success_rate: 90.0}],
               :success_rate,
               0
             ) == 0.0
    end

    test "handles single entry" do
      assert MetricsStore.weighted_average(
               [%{total_calls: 50, avg_latency_ms: 120.0}],
               :avg_latency_ms,
               50
             ) == 120.0
    end

    test "handles missing field values with default 0" do
      entries = [
        %{total_calls: 100},
        %{total_calls: 100, success_rate: 80.0}
      ]

      assert MetricsStore.weighted_average(entries, :success_rate, 200) == 40.0
    end

    test "handles all-zero total_calls entries" do
      entries = [
        %{total_calls: 0, success_rate: 90.0},
        %{total_calls: 0, success_rate: 80.0}
      ]

      assert MetricsStore.weighted_average(entries, :success_rate, 0) == 0.0
    end
  end

  describe "aggregate_provider_entries/3" do
    test "computes aggregate metrics from multiple entries" do
      entries = [
        %{
          provider_id: "p1",
          total_calls: 100,
          score: 90.0,
          success_rate: 95.0,
          avg_latency_ms: 50.0
        },
        %{
          provider_id: "p1",
          total_calls: 100,
          score: 80.0,
          success_rate: 85.0,
          avg_latency_ms: 60.0
        }
      ]

      result = MetricsStore.aggregate_provider_entries("p1", entries, entries)

      assert result.provider_id == "p1"
      assert result.total_calls == 200
      assert result.node_count == 2
      assert result.score == 85.0
      assert result.success_rate == 90.0
    end

    test "builds latency_by_node from all entries" do
      entries_for_aggregates = [
        %{
          provider_id: "p1",
          total_calls: 100,
          score: 90.0,
          success_rate: 95.0,
          avg_latency_ms: 50.0,
          source_node_id: "us-east",
          source_node: :node1,
          p50_latency: 45,
          p95_latency: 80,
          p99_latency: 120
        }
      ]

      all_entries = [
        %{
          provider_id: "p1",
          total_calls: 100,
          source_node_id: "us-east",
          source_node: :node1,
          p50_latency: 45,
          p95_latency: 80,
          p99_latency: 120,
          avg_latency_ms: 50.0,
          success_rate: 95.0
        },
        %{
          provider_id: "p1",
          total_calls: 5,
          source_node_id: "eu-west",
          source_node: :node2,
          p50_latency: 100,
          p95_latency: 150,
          p99_latency: 200,
          avg_latency_ms: 110.0,
          success_rate: 90.0
        }
      ]

      result = MetricsStore.aggregate_provider_entries("p1", entries_for_aggregates, all_entries)

      assert Map.has_key?(result.latency_by_node, "us-east")
      assert Map.has_key?(result.latency_by_node, "eu-west")
      assert result.latency_by_node["us-east"].p50 == 45
      assert result.latency_by_node["eu-west"].p50 == 100
    end
  end

  describe "fetch_from_cluster coverage metadata" do
    test "all nodes succeed" do
      coverage = build_coverage([%{score: 100}, %{score: 90}, %{score: 80}], 3, [])

      assert coverage.responding == 3
      assert coverage.total == 3
      assert coverage.bad_nodes == []
    end

    test "partial node failures" do
      coverage = build_coverage([%{score: 100}], 3, [:node2, :node3])

      assert coverage.responding == 1
      assert coverage.total == 3
      assert coverage.bad_nodes == [:node2, :node3]
    end

    test "all nodes failing" do
      coverage = build_coverage([], 2, [:node1, :node2])

      assert coverage.responding == 0
      assert coverage.total == 2
    end
  end

  describe "filtering badrpc results" do
    test "filters out {:badrpc, reason} tuples" do
      raw = [%{data: "valid1"}, {:badrpc, :nodedown}, %{data: "valid2"}, {:badrpc, :timeout}]

      valid = Enum.reject(raw, &match?({:badrpc, _}, &1))

      assert length(valid) == 2
      assert Enum.all?(valid, &is_map/1)
    end

    test "handles all valid results" do
      raw = [%{a: 1}, %{b: 2}, %{c: 3}]
      assert Enum.reject(raw, &match?({:badrpc, _}, &1)) == raw
    end

    test "handles all badrpc results" do
      raw = [{:badrpc, :nodedown}, {:badrpc, :timeout}]
      assert Enum.reject(raw, &match?({:badrpc, _}, &1)) == []
    end
  end

  describe "stale-while-revalidate caching pattern" do
    test "fresh cache returns data with stale=false" do
      now = System.monotonic_time(:millisecond)

      result =
        check_cache_freshness(
          %{
            data: [%{provider_id: "p1"}],
            coverage: %{responding: 3, total: 3},
            cached_at: now - 5_000
          },
          now,
          15_000
        )

      assert result.stale == false
    end

    test "stale cache returns data with stale=true" do
      now = System.monotonic_time(:millisecond)

      result =
        check_cache_freshness(
          %{
            data: [%{provider_id: "p1"}],
            coverage: %{responding: 3, total: 3},
            cached_at: now - 20_000
          },
          now,
          15_000
        )

      assert result.stale == true
    end

    test "cache miss returns loading=true" do
      result = check_cache_freshness(nil, System.monotonic_time(:millisecond), 15_000)

      assert result.loading == true
      assert result.data == []
    end
  end

  describe "ETS cache read behavior" do
    setup do
      table = :ets.new(:test_metrics_cache, [:set, :public, read_concurrency: true])
      %{table: table}
    end

    test "returns nil for missing key", %{table: table} do
      assert :ets.lookup(table, {:provider_leaderboard, "default", "ethereum"}) == []
    end

    test "returns data for recent entry", %{table: table} do
      key = {:provider_leaderboard, "default", "ethereum"}
      now = System.monotonic_time(:millisecond)
      data = [%{provider_id: "p1", score: 90.0}]
      coverage = %{responding: 2, total: 2}

      :ets.insert(table, {key, data, coverage, now})

      [{^key, read_data, read_coverage, cached_at}] = :ets.lookup(table, key)
      assert read_data == data
      assert read_coverage == coverage
      assert cached_at == now
    end

    test "delete_all_objects clears the cache", %{table: table} do
      :ets.insert(table, {{:a, "p", "c"}, [], %{}, System.monotonic_time(:millisecond)})
      :ets.insert(table, {{:b, "p", "c"}, [], %{}, System.monotonic_time(:millisecond)})

      assert :ets.info(table, :size) == 2
      :ets.delete_all_objects(table)
      assert :ets.info(table, :size) == 0
    end

    test "select_delete removes expired entries", %{table: table} do
      now = System.monotonic_time(:millisecond)

      :ets.insert(table, {{:old, "p", "c"}, [], %{}, now - 400_000})
      :ets.insert(table, {{:new, "p", "c"}, [], %{}, now - 1_000})

      cutoff = now - 300_000
      match_spec = [{{:_, :_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}]
      :ets.select_delete(table, match_spec)

      assert :ets.info(table, :size) == 1
      assert :ets.lookup(table, {:old, "p", "c"}) == []
      assert length(:ets.lookup(table, {:new, "p", "c"})) == 1
    end
  end

  # Helpers

  defp leaderboard_entry(provider_id, score, total_calls, opts \\ []) do
    {node_id, node_name} = Keyword.get(opts, :node, {"n", :n})

    %{
      provider_id: provider_id,
      score: score,
      total_calls: total_calls,
      success_rate: Keyword.get(opts, :success_rate, 0.95),
      avg_latency_ms: Keyword.get(opts, :avg_latency_ms, 50.0),
      source_node_id: node_id,
      source_node: node_name
    }
  end

  defp method_perf_entry(provider_id, method, total_calls, opts) do
    {node_id, node_name} = Keyword.get(opts, :node, {"n", :n})

    %{
      provider_id: provider_id,
      method: method,
      success_rate: Keyword.get(opts, :success_rate, 0.95),
      total_calls: total_calls,
      avg_duration_ms: Keyword.get(opts, :avg_duration_ms, 50.0),
      percentiles: Keyword.get(opts, :percentiles, %{p50: 45}),
      source_node_id: node_id,
      source_node: node_name
    }
  end

  defp build_coverage(valid_results, total_nodes, bad_nodes) do
    %{
      responding: length(valid_results),
      total: total_nodes,
      bad_nodes: bad_nodes
    }
  end

  defp check_cache_freshness(nil, _now, _cache_ttl_ms) do
    %{data: [], coverage: %{responding: 0, total: 0}, cached_at: nil, stale: false, loading: true}
  end

  defp check_cache_freshness(cache_entry, now, cache_ttl_ms) do
    age = now - cache_entry.cached_at

    %{
      data: cache_entry.data,
      coverage: cache_entry.coverage,
      cached_at: cache_entry.cached_at,
      stale: age >= cache_ttl_ms
    }
  end
end
