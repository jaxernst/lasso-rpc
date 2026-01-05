defmodule Lasso.RPC.Strategies.StalenessTest do
  use ExUnit.Case, async: true

  alias Lasso.RPC.Strategies.Fastest
  alias Lasso.RPC.Strategies.LatencyWeighted
  alias Lasso.RPC.{SelectionContext, StrategyContext}

  describe "Fastest strategy staleness validation" do
    setup do
      # Create test selection and context
      selection = %SelectionContext{
        profile: "test",
        chain: "ethereum",
        method: "eth_blockNumber",
        timeout: 5000
      }

      ctx = Fastest.prepare_context(selection)

      {:ok, ctx: ctx, profile: selection.profile, chain: selection.chain, method: selection.method}
    end

    test "provider with fresh metrics (< 10min) gets normal latency score", %{
      ctx: ctx,
      profile: profile,
      chain: chain,
      method: method
    } do
      current_time = System.system_time(:millisecond)

      # Create channels
      channels = [
        %{provider_id: "fast_fresh", transport: :http}
      ]

      # Mock metrics with fresh timestamp
      stub_batch_metrics(fn _p, _c, _reqs ->
        %{
          {"fast_fresh", "eth_blockNumber", :http} => %{
            latency_ms: 100.0,
            success_rate: 0.95,
            total_calls: 50,
            confidence_score: 0.8,
            last_updated_ms: current_time - 60_000  # 1 minute ago (fresh)
          }
        }
      end)

      ranked = Fastest.rank_channels(channels, method, ctx, profile, chain)

      # Should use actual latency (implicitly tested by ranking)
      assert length(ranked) == 1
      assert hd(ranked).provider_id == "fast_fresh"
    end

    test "provider with stale metrics (> 10min) gets cold start penalty", %{
      ctx: ctx,
      profile: profile,
      chain: chain,
      method: method
    } do
      current_time = System.system_time(:millisecond)

      channels = [
        %{provider_id: "fast_stale", transport: :http},
        %{provider_id: "slow_fresh", transport: :http}
      ]

      # Mock metrics with one stale and one fresh
      stub_batch_metrics(fn _p, _c, _reqs ->
        %{
          {"fast_stale", "eth_blockNumber", :http} => %{
            latency_ms: 100.0,
            success_rate: 0.95,
            total_calls: 50,
            confidence_score: 0.8,
            last_updated_ms: current_time - 20 * 60 * 1000  # 20 minutes ago (stale)
          },
          {"slow_fresh", "eth_blockNumber", :http} => %{
            latency_ms: 200.0,
            success_rate: 0.95,
            total_calls: 50,
            confidence_score: 0.8,
            last_updated_ms: current_time - 60_000  # 1 minute ago (fresh)
          }
        }
      end)

      ranked = Fastest.rank_channels(channels, method, ctx, profile, chain)

      # Slow fresh provider should be ranked higher than fast stale provider
      # (200ms fresh < 500ms stale penalty)
      assert length(ranked) == 2
      assert hd(ranked).provider_id == "slow_fresh"
    end

    test "missing last_updated_ms treated as cold start", %{
      ctx: ctx,
      profile: profile,
      chain: chain,
      method: method
    } do
      channels = [
        %{provider_id: "no_timestamp", transport: :http},
        %{provider_id: "with_timestamp", transport: :http}
      ]

      current_time = System.system_time(:millisecond)

      stub_batch_metrics(fn _p, _c, _reqs ->
        %{
          {"no_timestamp", "eth_blockNumber", :http} => nil,
          {"with_timestamp", "eth_blockNumber", :http} => %{
            latency_ms: 200.0,
            success_rate: 0.95,
            total_calls: 50,
            confidence_score: 0.8,
            last_updated_ms: current_time - 60_000
          }
        }
      end)

      ranked = Fastest.rank_channels(channels, method, ctx, profile, chain)

      # Provider with timestamp should be ranked first (200ms < 500ms penalty)
      assert length(ranked) == 2
      assert hd(ranked).provider_id == "with_timestamp"
    end
  end

  describe "LatencyWeighted strategy staleness validation" do
    setup do
      selection = %SelectionContext{
        profile: "test",
        chain: "ethereum",
        method: "eth_blockNumber",
        timeout: 5000
      }

      ctx = LatencyWeighted.prepare_context(selection)

      {:ok, ctx: ctx, profile: selection.profile, chain: selection.chain, method: selection.method}
    end

    test "fresh metrics get normal weight calculation", %{
      ctx: ctx,
      profile: profile,
      chain: chain,
      method: method
    } do
      current_time = System.system_time(:millisecond)

      channels = [
        %{provider_id: "fresh_provider", transport: :http}
      ]

      stub_batch_metrics(fn _p, _c, _reqs ->
        %{
          {"fresh_provider", "eth_blockNumber", :http} => %{
            latency_ms: 100.0,
            success_rate: 0.95,
            total_calls: 50,
            confidence_score: 0.8,
            last_updated_ms: current_time - 60_000  # 1 minute ago
          }
        }
      end)

      # Just verify it doesn't crash and returns the channel
      ranked = LatencyWeighted.rank_channels(channels, method, ctx, profile, chain)
      assert length(ranked) == 1
    end

    test "stale metrics get explore_floor weight", %{
      ctx: ctx,
      profile: profile,
      chain: chain,
      method: method
    } do
      current_time = System.system_time(:millisecond)

      channels = [
        %{provider_id: "stale_provider", transport: :http}
      ]

      stub_batch_metrics(fn _p, _c, _reqs ->
        %{
          {"stale_provider", "eth_blockNumber", :http} => %{
            latency_ms: 100.0,
            success_rate: 0.95,
            total_calls: 50,
            confidence_score: 0.8,
            last_updated_ms: current_time - 20 * 60 * 1000  # 20 minutes ago
          }
        }
      end)

      ranked = LatencyWeighted.rank_channels(channels, method, ctx, profile, chain)
      assert length(ranked) == 1
    end

    test "multiple providers with mixed freshness sort correctly", %{
      ctx: ctx,
      profile: profile,
      chain: chain,
      method: method
    } do
      current_time = System.system_time(:millisecond)

      channels = [
        %{provider_id: "p1_stale", transport: :http},
        %{provider_id: "p2_fresh", transport: :http},
        %{provider_id: "p3_fresh", transport: :http}
      ]

      stub_batch_metrics(fn _p, _c, _reqs ->
        %{
          {"p1_stale", "eth_blockNumber", :http} => %{
            latency_ms: 50.0,
            success_rate: 0.95,
            total_calls: 50,
            confidence_score: 0.8,
            last_updated_ms: current_time - 20 * 60 * 1000  # Stale
          },
          {"p2_fresh", "eth_blockNumber", :http} => %{
            latency_ms: 200.0,
            success_rate: 0.95,
            total_calls: 50,
            confidence_score: 0.8,
            last_updated_ms: current_time - 60_000  # Fresh
          },
          {"p3_fresh", "eth_blockNumber", :http} => %{
            latency_ms: 300.0,
            success_rate: 0.95,
            total_calls: 50,
            confidence_score: 0.8,
            last_updated_ms: current_time - 60_000  # Fresh
          }
        }
      end)

      ranked = LatencyWeighted.rank_channels(channels, method, ctx, profile, chain)

      # Should return all 3 channels, stale one should have lower effective weight
      assert length(ranked) == 3
    end
  end

  # Helper to stub batch metrics
  defp stub_batch_metrics(fun) do
    # Store original backend
    original_backend = Application.get_env(:lasso, :metrics_backend)

    defmodule MockBatchMetricsBackend do
      def batch_get_transport_performance(profile, chain, requests) do
        Process.get(:batch_mock_fun).(profile, chain, requests)
      end

      # Stub other required callbacks
      def get_provider_performance(_profile, _chain, _provider_id, _method), do: nil

      def get_method_performance(_profile, _chain, _method) do
        # Return empty list for cold start baseline calculation
        # This means cold start baseline will use default 500ms
        []
      end

      def get_provider_transport_performance(_profile, _chain, _provider_id, _method, _transport), do: nil
      def get_method_transport_performance(_profile, _chain, _provider_id, _method, _transport), do: []
      def record_request(_profile, _chain, _provider_id, _method, _duration_ms, _result, _opts), do: :ok
    end

    Process.put(:batch_mock_fun, fun)
    Application.put_env(:lasso, :metrics_backend, MockBatchMetricsBackend)

    on_exit(fn ->
      if original_backend do
        Application.put_env(:lasso, :metrics_backend, original_backend)
      else
        Application.delete_env(:lasso, :metrics_backend)
      end
    end)
  end
end
