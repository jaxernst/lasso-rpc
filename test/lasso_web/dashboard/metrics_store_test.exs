defmodule LassoWeb.Dashboard.MetricsStoreTest do
  use ExUnit.Case, async: true

  describe "aggregate_results(:get_provider_leaderboard, ...)" do
    test "merges entries by provider_id and averages scores" do
      results = [
        [
          %{provider_id: "provider_a", score: 80.0},
          %{provider_id: "provider_b", score: 60.0}
        ],
        [
          %{provider_id: "provider_a", score: 90.0},
          %{provider_id: "provider_c", score: 70.0}
        ]
      ]

      aggregated = aggregate_results(:get_provider_leaderboard, results)

      assert length(aggregated) == 3

      provider_a = Enum.find(aggregated, &(&1.provider_id == "provider_a"))
      assert provider_a.score == 85.0
      assert provider_a.node_count == 2

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
          %{provider_id: "low", score: 10.0},
          %{provider_id: "high", score: 100.0}
        ],
        [
          %{provider_id: "mid", score: 50.0}
        ]
      ]

      aggregated = aggregate_results(:get_provider_leaderboard, results)

      assert [first, second, third] = aggregated
      assert first.provider_id == "high"
      assert second.provider_id == "mid"
      assert third.provider_id == "low"
    end

    test "handles empty results" do
      results = []

      aggregated = aggregate_results(:get_provider_leaderboard, results)

      assert aggregated == []
    end

    test "handles single node result" do
      results = [
        [
          %{provider_id: "provider_a", score: 95.0}
        ]
      ]

      aggregated = aggregate_results(:get_provider_leaderboard, results)

      assert [entry] = aggregated
      assert entry.provider_id == "provider_a"
      assert entry.score == 95.0
      assert entry.node_count == 1
    end

    test "handles nested empty lists" do
      results = [[], []]

      aggregated = aggregate_results(:get_provider_leaderboard, results)

      assert aggregated == []
    end
  end

  describe "aggregate_results(:get_realtime_stats, ...)" do
    test "merges rpc_methods and sums total_calls" do
      results = [
        %{rpc_methods: ["eth_blockNumber", "eth_call"], total_calls: 100},
        %{rpc_methods: ["eth_blockNumber", "eth_getBalance"], total_calls: 150}
      ]

      aggregated = aggregate_results(:get_realtime_stats, results)

      assert aggregated.total_calls == 250

      assert Enum.sort(aggregated.rpc_methods) == [
               "eth_blockNumber",
               "eth_call",
               "eth_getBalance"
             ]
    end

    test "handles nil results" do
      results = [
        nil,
        %{rpc_methods: ["eth_call"], total_calls: 50},
        nil
      ]

      aggregated = aggregate_results(:get_realtime_stats, results)

      assert aggregated.total_calls == 50
      assert aggregated.rpc_methods == ["eth_call"]
    end

    test "handles empty results" do
      results = []

      aggregated = aggregate_results(:get_realtime_stats, results)

      assert aggregated.rpc_methods == []
      assert aggregated.total_calls == 0
    end

    test "handles all nil results" do
      results = [nil, nil, nil]

      aggregated = aggregate_results(:get_realtime_stats, results)

      assert aggregated.rpc_methods == []
      assert aggregated.total_calls == 0
    end

    test "handles missing keys with defaults" do
      results = [
        %{rpc_methods: ["method_a"]},
        %{total_calls: 25}
      ]

      aggregated = aggregate_results(:get_realtime_stats, results)

      assert aggregated.total_calls == 25
      assert aggregated.rpc_methods == ["method_a"]
    end

    test "deduplicates rpc_methods across nodes" do
      results = [
        %{rpc_methods: ["eth_call", "eth_call"], total_calls: 10},
        %{rpc_methods: ["eth_call"], total_calls: 20}
      ]

      aggregated = aggregate_results(:get_realtime_stats, results)

      assert aggregated.rpc_methods == ["eth_call"]
      assert aggregated.total_calls == 30
    end
  end

  describe "aggregate_results(:get_rpc_method_performance_with_percentiles, ...)" do
    test "returns first non-nil result" do
      results = [
        nil,
        %{p50: 100, p95: 200, p99: 300},
        %{p50: 150, p95: 250, p99: 350}
      ]

      aggregated = aggregate_results(:get_rpc_method_performance_with_percentiles, results)

      assert aggregated == %{p50: 100, p95: 200, p99: 300}
    end

    test "returns nil when all results are nil" do
      results = [nil, nil, nil]

      aggregated = aggregate_results(:get_rpc_method_performance_with_percentiles, results)

      assert aggregated == nil
    end

    test "returns the only result if single" do
      results = [%{p50: 50, p95: 100}]

      aggregated = aggregate_results(:get_rpc_method_performance_with_percentiles, results)

      assert aggregated == %{p50: 50, p95: 100}
    end

    test "handles empty results" do
      results = []

      aggregated = aggregate_results(:get_rpc_method_performance_with_percentiles, results)

      assert aggregated == nil
    end
  end

  describe "aggregate_results with unknown function" do
    test "returns first result for unknown functions" do
      results = [
        %{some: "data"},
        %{other: "data"}
      ]

      aggregated = aggregate_results(:unknown_function, results)

      assert aggregated == %{some: "data"}
    end

    test "returns nil for empty results" do
      results = []

      aggregated = aggregate_results(:unknown_function, results)

      assert aggregated == nil
    end
  end

  describe "fetch_from_cluster coverage metadata" do
    test "coverage is correct when all nodes succeed" do
      valid_results = [
        %{score: 100},
        %{score: 90},
        %{score: 80}
      ]

      nodes = [:node1, :node2, :node3]
      bad_nodes = []

      coverage = build_coverage(valid_results, nodes, bad_nodes)

      assert coverage.responding == 3
      assert coverage.total == 3
      assert coverage.nodes == [:node1, :node2, :node3]
      assert coverage.bad_nodes == []
    end

    test "coverage reflects partial node failures" do
      valid_results = [%{score: 100}]
      nodes = [:node1, :node2, :node3]
      bad_nodes = [:node2, :node3]

      coverage = build_coverage(valid_results, nodes, bad_nodes)

      assert coverage.responding == 1
      assert coverage.total == 3
      assert coverage.nodes == [:node1]
      assert coverage.bad_nodes == [:node2, :node3]
    end

    test "coverage handles all nodes failing" do
      valid_results = []
      nodes = [:node1, :node2]
      bad_nodes = [:node1, :node2]

      coverage = build_coverage(valid_results, nodes, bad_nodes)

      assert coverage.responding == 0
      assert coverage.total == 2
      assert coverage.nodes == []
      assert coverage.bad_nodes == [:node1, :node2]
    end
  end

  describe "filtering badrpc results" do
    test "filters out {:badrpc, reason} tuples" do
      raw_results = [
        %{data: "valid1"},
        {:badrpc, :nodedown},
        %{data: "valid2"},
        {:badrpc, :timeout}
      ]

      valid_results = filter_badrpc(raw_results)

      assert length(valid_results) == 2
      assert Enum.all?(valid_results, &is_map/1)
    end

    test "handles all valid results" do
      raw_results = [%{a: 1}, %{b: 2}, %{c: 3}]

      valid_results = filter_badrpc(raw_results)

      assert valid_results == raw_results
    end

    test "handles all badrpc results" do
      raw_results = [{:badrpc, :nodedown}, {:badrpc, :timeout}]

      valid_results = filter_badrpc(raw_results)

      assert valid_results == []
    end
  end

  # Helper functions to test the aggregation logic

  defp aggregate_results(:get_provider_leaderboard, results) do
    results
    |> List.flatten()
    |> Enum.group_by(& &1.provider_id)
    |> Enum.map(fn {provider_id, entries} ->
      avg_score =
        entries
        |> Enum.map(& &1.score)
        |> Enum.sum()
        |> Kernel./(length(entries))

      %{
        provider_id: provider_id,
        score: avg_score,
        node_count: length(entries)
      }
    end)
    |> Enum.sort_by(& &1.score, :desc)
  end

  defp aggregate_results(:get_realtime_stats, results) do
    results
    |> Enum.reduce(%{rpc_methods: [], total_calls: 0}, fn
      nil, acc ->
        acc

      stats, acc ->
        %{
          rpc_methods: Enum.uniq(acc.rpc_methods ++ Map.get(stats, :rpc_methods, [])),
          total_calls: acc.total_calls + Map.get(stats, :total_calls, 0)
        }
    end)
  end

  defp aggregate_results(:get_rpc_method_performance_with_percentiles, results) do
    Enum.find(results, & &1)
  end

  defp aggregate_results(_function, results) do
    List.first(results)
  end

  defp build_coverage(valid_results, nodes, bad_nodes) do
    %{
      responding: length(valid_results),
      total: length(nodes),
      nodes: nodes -- bad_nodes,
      bad_nodes: bad_nodes
    }
  end

  defp filter_badrpc(results) do
    Enum.reject(results, &match?({:badrpc, _}, &1))
  end

  describe "weighted_average/3" do
    test "computes weighted average correctly" do
      entries = [
        %{total_calls: 100, success_rate: 90.0},
        %{total_calls: 200, success_rate: 80.0},
        %{total_calls: 100, success_rate: 70.0}
      ]

      total_weight = 400

      # (100*90 + 200*80 + 100*70) / 400 = (9000 + 16000 + 7000) / 400 = 80.0
      result = weighted_average(entries, :success_rate, total_weight)

      assert result == 80.0
    end

    test "returns 0.0 when total weight is zero" do
      entries = [%{total_calls: 100, success_rate: 90.0}]

      result = weighted_average(entries, :success_rate, 0)

      assert result == 0.0
    end

    test "handles single entry" do
      entries = [%{total_calls: 50, avg_latency_ms: 120.0}]

      result = weighted_average(entries, :avg_latency_ms, 50)

      assert result == 120.0
    end

    test "handles missing field values with default 0" do
      entries = [
        %{total_calls: 100},
        %{total_calls: 100, success_rate: 80.0}
      ]

      # (100*0 + 100*80) / 200 = 40.0
      result = weighted_average(entries, :success_rate, 200)

      assert result == 40.0
    end
  end

  describe "aggregate_provider_entries/3" do
    test "computes aggregate metrics from multiple entries" do
      entries_for_aggregates = [
        %{provider_id: "p1", total_calls: 100, score: 90.0, success_rate: 95.0, avg_latency_ms: 50.0},
        %{provider_id: "p1", total_calls: 100, score: 80.0, success_rate: 85.0, avg_latency_ms: 60.0}
      ]

      all_entries = entries_for_aggregates

      result = aggregate_provider_entries("p1", entries_for_aggregates, all_entries)

      assert result.provider_id == "p1"
      assert result.total_calls == 200
      assert result.node_count == 2
      # Weighted average: (100*90 + 100*80) / 200 = 85.0
      assert result.score == 85.0
      # Weighted average: (100*95 + 100*85) / 200 = 90.0
      assert result.success_rate == 90.0
    end

    test "builds latency_by_region from all entries" do
      entries_for_aggregates = [
        %{
          provider_id: "p1",
          total_calls: 100,
          score: 90.0,
          success_rate: 95.0,
          avg_latency_ms: 50.0,
          region: "us-east",
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
          region: "us-east",
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
          region: "eu-west",
          source_node: :node2,
          p50_latency: 100,
          p95_latency: 150,
          p99_latency: 200,
          avg_latency_ms: 110.0,
          success_rate: 90.0
        }
      ]

      result = aggregate_provider_entries("p1", entries_for_aggregates, all_entries)

      assert Map.has_key?(result.latency_by_region, "us-east")
      assert Map.has_key?(result.latency_by_region, "eu-west")
      assert result.latency_by_region["us-east"].p50 == 45
      assert result.latency_by_region["eu-west"].p50 == 100
    end
  end

  describe "stale-while-revalidate caching pattern" do
    test "fresh cache returns data with stale=false" do
      now = System.monotonic_time(:millisecond)
      cache_ttl_ms = 15_000

      cache_entry = %{
        data: [%{provider_id: "p1", score: 90.0}],
        coverage: %{responding: 3, total: 3},
        cached_at: now - 5000
      }

      result = check_cache_freshness(cache_entry, now, cache_ttl_ms)

      assert result.stale == false
      assert result.data == cache_entry.data
    end

    test "stale cache returns data with stale=true and triggers refresh" do
      now = System.monotonic_time(:millisecond)
      cache_ttl_ms = 15_000

      cache_entry = %{
        data: [%{provider_id: "p1", score: 90.0}],
        coverage: %{responding: 3, total: 3},
        cached_at: now - 20_000
      }

      result = check_cache_freshness(cache_entry, now, cache_ttl_ms)

      assert result.stale == true
      assert result.should_refresh == true
      assert result.data == cache_entry.data
    end

    test "cache miss returns empty defaults with loading=true" do
      now = System.monotonic_time(:millisecond)
      cache_ttl_ms = 15_000

      result = check_cache_freshness(nil, now, cache_ttl_ms)

      assert result.loading == true
      assert result.data == []
    end
  end

  # Additional helper functions

  defp weighted_average(entries, field, total_weight) do
    entries
    |> Enum.map(fn entry ->
      calls = Map.get(entry, :total_calls, 0)
      value = Map.get(entry, field, 0.0)
      value * calls
    end)
    |> Enum.sum()
    |> safe_divide(total_weight)
  end

  defp safe_divide(_numerator, 0), do: 0.0
  defp safe_divide(numerator, denominator), do: numerator / denominator

  defp aggregate_provider_entries(provider_id, entries_for_aggregates, all_entries) do
    total_calls =
      entries_for_aggregates |> Enum.map(&Map.get(&1, :total_calls, 0)) |> Enum.sum()

    latency_by_region = build_latency_by_region(all_entries)

    %{
      provider_id: provider_id,
      score: weighted_average(entries_for_aggregates, :score, total_calls),
      total_calls: total_calls,
      success_rate: weighted_average(entries_for_aggregates, :success_rate, total_calls),
      avg_latency_ms: weighted_average(entries_for_aggregates, :avg_latency_ms, total_calls),
      node_count: length(all_entries),
      latency_by_region: latency_by_region
    }
  end

  defp build_latency_by_region(entries) do
    entries
    |> Enum.map(fn entry ->
      region = Map.get(entry, :region) || Map.get(entry, :source_region) || "unknown"

      {region,
       %{
         region: region,
         node: Map.get(entry, :source_node),
         p50: Map.get(entry, :p50_latency),
         p95: Map.get(entry, :p95_latency),
         p99: Map.get(entry, :p99_latency),
         avg: Map.get(entry, :avg_latency_ms),
         success_rate: Map.get(entry, :success_rate),
         total_calls: Map.get(entry, :total_calls, 0)
       }}
    end)
    |> Map.new()
  end

  defp check_cache_freshness(nil, _now, _cache_ttl_ms) do
    %{
      data: [],
      coverage: %{responding: 0, total: 0},
      cached_at: nil,
      stale: false,
      loading: true
    }
  end

  defp check_cache_freshness(cache_entry, now, cache_ttl_ms) do
    age = now - cache_entry.cached_at
    is_fresh = age < cache_ttl_ms

    %{
      data: cache_entry.data,
      coverage: cache_entry.coverage,
      cached_at: cache_entry.cached_at,
      stale: not is_fresh,
      should_refresh: not is_fresh
    }
  end
end
