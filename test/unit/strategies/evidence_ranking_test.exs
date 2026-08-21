defmodule Lasso.RPC.Strategies.EvidenceRankingTest do
  use ExUnit.Case, async: false

  alias Lasso.Config.ConfigStore
  alias Lasso.Providers.Catalog
  alias Lasso.RPC.AttemptProjection
  alias Lasso.RPC.RoutingEvidence.Summary
  alias Lasso.RPC.Strategies.{Fastest, LatencyWeighted}

  setup do
    clear_test_control()

    on_exit(fn ->
      clear_test_control()

      AttemptProjection.reconcile_routes(
        ConfigStore.route_generation(),
        Catalog.routing_control_routes()
      )
    end)

    :ok
  end

  test "fastest ranks only qualified recent evidence ahead of stale lifetime-like data" do
    channels = channels(["stale", "slow", "fast", "unknown"])

    put_summaries(%{
      {"stale-instance", :http} => summary("stale", :stale, 1.0, 2.0),
      {"slow-instance", :http} => summary("slow", :qualified, 120.0, 180.0),
      {"fast-instance", :http} => summary("fast", :qualified, 40.0, 90.0)
    })

    ctx = Fastest.prepare_context("public", 1, "eth_getBalance", 5_000)

    assert ["fast", "slow", "stale", "unknown"] ==
             channels
             |> Fastest.rank_channels("eth_getBalance", ctx, "public", 1)
             |> Enum.map(& &1.provider_id)
  end

  test "fastest falls back to mean and identity when p95 is unavailable" do
    channels = channels(["b", "a", "c"])

    put_summaries(%{
      {"a-instance", :http} => summary("a", :qualified, 50.0, nil),
      {"b-instance", :http} => summary("b", :qualified, 50.0, nil),
      {"c-instance", :http} => summary("c", :qualified, 40.0, nil)
    })

    ctx = Fastest.prepare_context("public", 1, "eth_getBalance", 5_000)

    assert ["c", "a", "b"] ==
             channels
             |> Fastest.rank_channels("eth_getBalance", ctx, "public", 1)
             |> Enum.map(& &1.provider_id)
  end

  test "fastest preserves availability and counts degradation when nothing qualifies" do
    channels = channels(["b", "a"])
    put_summaries(%{{"b-instance", :http} => summary("b", :stale, 1.0, 1.0)})
    ctx = Fastest.prepare_context("public", 1, "eth_getBalance", 5_000)
    before_count = degradation_count(:fastest)

    ranked = Fastest.rank_channels(channels, "eth_getBalance", ctx, "public", 1)

    assert Enum.map(ranked, & &1.provider_id) == ["a", "b"]
    assert degradation_count(:fastest) == before_count + 1
  end

  test "system priors order cold routes but never outrank client-qualified evidence" do
    channels = channels(["slow-client", "fast-prior"])

    prior =
      summary("fast-prior", :unqualified, 10.0, nil)
      |> Map.merge(%{comparable_attempts: 0, usable_successes: 0, support_source: :system_prior})

    put_summaries(%{
      {"slow-client-instance", :http} => summary("slow-client", :qualified, 100.0, nil),
      {"fast-prior-instance", :http} => prior
    })

    ctx = Fastest.prepare_context("public", 1, "eth_getBalance", 5_000)

    assert ["slow-client", "fast-prior"] ==
             channels
             |> Fastest.rank_channels("eth_getBalance", ctx, "public", 1)
             |> Enum.map(& &1.provider_id)

    cold_ctx = %{
      ctx
      | routing_summaries: %{
          {"slow-client-instance", :http} => %{
            summary("slow-client", :unqualified, 80.0, nil)
            | comparable_attempts: 0
          },
          {"fast-prior-instance", :http} => prior
        }
    }

    assert ["fast-prior", "slow-client"] ==
             channels
             |> Fastest.rank_channels("eth_getBalance", cold_ctx, "public", 1)
             |> Enum.map(& &1.provider_id)
  end

  test "missing direct control rows preserve live candidates through degradation" do
    channels = channels(["b", "a"])
    ctx = Fastest.prepare_context("public", 1, "eth_getBalance", 5_000)
    before_count = degradation_count(:fastest)

    assert ["a", "b"] ==
             channels
             |> Fastest.rank_channels("eth_getBalance", ctx, "public", 1)
             |> Enum.map(& &1.provider_id)

    assert degradation_count(:fastest) == before_count

    assert [] =
             :ets.lookup(
               :lasso_instance_state,
               {:routing_control_scope, "public", 1}
             )
  end

  test "relative latency weights are scale invariant and have no absolute floor" do
    weights_ms = LatencyWeighted.relative_weights([10.0, 20.0, 40.0], 2.0)
    weights_scaled = LatencyWeighted.relative_weights([100.0, 200.0, 400.0], 2.0)

    Enum.zip(weights_ms, weights_scaled)
    |> Enum.each(fn {left, right} -> assert_in_delta left, right, 1.0e-12 end)

    assert weights_ms == [1.0, 0.25, 0.0625]
  end

  test "exponential-race permutation follows the requested relative weights" do
    :rand.seed(:exsss, {41, 42, 43})

    first_counts =
      Enum.reduce(1..30_000, %{fast: 0, slow: 0}, fn _, counts ->
        first =
          LatencyWeighted.weighted_permutation(fast: 1.0, slow: 0.5)
          |> hd()

        Map.update!(counts, first, &(&1 + 1))
      end)

    fast_share = first_counts.fast / 30_000
    assert fast_share > 0.65
    assert fast_share < 0.685
  end

  test "latency weighted excludes unqualified evidence from weighted preference" do
    channels = channels(["unqualified", "qualified"])

    put_summaries(%{
      {"unqualified-instance", :http} => summary("unqualified", :unqualified, 1.0, 1.0),
      {"qualified-instance", :http} => summary("qualified", :qualified, 100.0, 120.0)
    })

    ctx = LatencyWeighted.prepare_context("public", 1, "eth_getBalance", 5_000)

    for _ <- 1..100 do
      assert [first | _] =
               LatencyWeighted.rank_channels(
                 channels,
                 "eth_getBalance",
                 ctx,
                 "public",
                 1
               )

      assert first.provider_id == "qualified"
    end
  end

  defp channels(provider_ids) do
    Enum.map(provider_ids, fn provider_id ->
      %{
        profile: "public",
        provider_id: provider_id,
        instance_id: "#{provider_id}-instance",
        transport: :http
      }
    end)
  end

  defp summary(provider_id, state, mean, p95) do
    %Summary{
      upstream_instance_id: "#{provider_id}-instance",
      chain_id: 1,
      transport: :http,
      workload_key: :client,
      state: state,
      successful_mean_latency_ms: mean,
      successful_p95_latency_ms: p95,
      comparable_attempts: 100,
      usable_successes: 99,
      support_source: :direct_local,
      generation: ConfigStore.route_generation()
    }
  end

  defp put_summaries(summaries) do
    generation = ConfigStore.route_generation()

    routes =
      Enum.map(summaries, fn {{instance_id, transport}, _summary} ->
        %{profile: "public", chain_id: 1, instance_id: instance_id, transport: transport}
      end)

    AttemptProjection.reconcile_routes(generation, routes)

    Enum.each(summaries, fn
      {_key, %Summary{state: :stale}} ->
        :ok

      {{instance_id, transport}, %Summary{} = summary} ->
        key = {:routing_control, "public", 1, instance_id, transport, "client"}
        [{^key, row}] = :ets.lookup(:lasso_instance_state, key)
        observed_at_us = System.monotonic_time(:microsecond)

        counts =
          if summary.state == :qualified,
            do: %{
              comparable_attempts: 100,
              usable_successes: 99,
              recent_success_probability: 1.0
            },
            else: %{
              comparable_attempts: 0,
              usable_successes: 0,
              recent_success_probability: nil
            }

        :ets.insert(
          :lasso_instance_state,
          {key,
           Map.merge(row, counts)
           |> Map.merge(%{
             observed_at_us: observed_at_us,
             oldest_observed_at_us: observed_at_us,
             successful_mean_latency_ms: summary.successful_mean_latency_ms,
             successful_p95_latency_ms: summary.successful_p95_latency_ms
           })}
        )
    end)
  end

  defp degradation_count(strategy),
    do: AttemptProjection.availability_degradation_count("public", 1, strategy, :client)

  defp clear_test_control do
    :ets.match_delete(:lasso_instance_state, {{:routing_control_scope, "public", 1}, :_})
    :ets.match_delete(:lasso_instance_state, {{:routing_control, "public", 1, :_, :_, :_}, :_})
  rescue
    ArgumentError -> :ok
  end
end
