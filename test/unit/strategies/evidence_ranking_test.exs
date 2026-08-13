defmodule Lasso.RPC.Strategies.EvidenceRankingTest do
  use ExUnit.Case, async: false

  alias Lasso.RPC.RoutingEvidence.Summary
  alias Lasso.RPC.Strategies.{Fastest, LatencyWeighted}

  defmodule EvidenceReader do
    @behaviour Lasso.RPC.RoutingEvidence.Reader

    @impl true
    def batch_get_summaries(_chain_id, _workload_key, upstream_keys) do
      summaries = Process.get(:routing_evidence_summaries, %{})
      Map.new(upstream_keys, &{&1, Map.get(summaries, &1)})
    end
  end

  defmodule RaisingReader do
    @behaviour Lasso.RPC.RoutingEvidence.Reader

    @impl true
    def batch_get_summaries(_chain_id, _workload_key, _upstream_keys) do
      raise "reader unavailable"
    end
  end

  setup do
    previous = Application.get_env(:lasso, :routing_evidence_reader)
    Application.put_env(:lasso, :routing_evidence_reader, EvidenceReader)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lasso, :routing_evidence_reader, previous),
        else: Application.delete_env(:lasso, :routing_evidence_reader)
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

  test "fastest uses p95 and identity as deterministic ties" do
    channels = channels(["b", "a", "c"])

    put_summaries(%{
      {"a-instance", :http} => summary("a", :qualified, 50.0, 90.0),
      {"b-instance", :http} => summary("b", :qualified, 50.0, 90.0),
      {"c-instance", :http} => summary("c", :qualified, 50.0, 70.0)
    })

    ctx = Fastest.prepare_context("public", 1, "eth_getBalance", 5_000)

    assert ["c", "a", "b"] ==
             channels
             |> Fastest.rank_channels("eth_getBalance", ctx, "public", 1)
             |> Enum.map(& &1.provider_id)
  end

  test "fastest preserves availability and emits degradation when nothing qualifies" do
    ref =
      :telemetry_test.attach_event_handlers(
        self(),
        [[:lasso, :routing_evidence, :availability_degradation]]
      )

    on_exit(fn -> :telemetry.detach(ref) end)

    channels = channels(["b", "a"])
    put_summaries(%{{"b-instance", :http} => summary("b", :stale, 1.0, 1.0)})
    ctx = Fastest.prepare_context("public", 1, "eth_getBalance", 5_000)

    ranked = Fastest.rank_channels(channels, "eth_getBalance", ctx, "public", 1)

    assert Enum.map(ranked, & &1.provider_id) == ["a", "b"]

    assert_receive {[:lasso, :routing_evidence, :availability_degradation], ^ref,
                    %{candidate_count: 2}, %{strategy: :fastest}}
  end

  test "reader failures preserve live candidates through availability degradation" do
    Application.put_env(:lasso, :routing_evidence_reader, RaisingReader)

    ref =
      :telemetry_test.attach_event_handlers(
        self(),
        [[:lasso, :routing_evidence, :availability_degradation]]
      )

    on_exit(fn -> :telemetry.detach(ref) end)

    channels = channels(["b", "a"])
    ctx = Fastest.prepare_context("public", 1, "eth_getBalance", 5_000)

    assert ["a", "b"] ==
             channels
             |> Fastest.rank_channels("eth_getBalance", ctx, "public", 1)
             |> Enum.map(& &1.provider_id)

    assert_receive {[:lasso, :routing_evidence, :availability_degradation], ^ref,
                    %{candidate_count: 2}, %{strategy: :fastest}}
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
      workload_key: :default,
      state: state,
      successful_mean_latency_ms: mean,
      successful_p95_latency_ms: p95,
      comparable_attempts: 100,
      usable_successes: 99,
      support_source: :direct_local,
      generation: 1
    }
  end

  defp put_summaries(summaries), do: Process.put(:routing_evidence_summaries, summaries)
end
