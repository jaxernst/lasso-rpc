defmodule StrategyEvidenceBenchmark.Reader do
  @behaviour Lasso.RPC.RoutingEvidence.Reader

  @impl true
  def batch_get_summaries(_chain_id, _workload_key, upstream_keys) do
    summaries = Process.get(:strategy_evidence_benchmark_summaries, %{})
    Map.new(upstream_keys, &{&1, Map.fetch!(summaries, &1)})
  end
end

alias Lasso.RPC.{Channel, RequestContext, RequestOptions}
alias Lasso.RPC.RequestPipeline.Observability
alias Lasso.RPC.RoutingEvidence.Summary
alias Lasso.RPC.Strategies.LatencyWeighted
alias Lasso.Core.Support.CircuitBreaker

Application.put_env(:lasso, :routing_evidence_reader, StrategyEvidenceBenchmark.Reader)

channels =
  for index <- 1..32 do
    %Channel{
      profile: "bench",
      chain_id: 1,
      provider_id: "p#{index}",
      instance_id: "instance-#{index}",
      transport: :http
    }
  end

summaries =
  Map.new(channels, fn channel ->
    key = {channel.instance_id, channel.transport}
    index = channel.provider_id |> String.trim_leading("p") |> String.to_integer()

    summary = %Summary{
      upstream_instance_id: channel.instance_id,
      chain_id: 1,
      transport: :http,
      workload_key: :default,
      state: :qualified,
      comparable_attempts: 100,
      usable_successes: 99,
      successful_mean_latency_ms: 20.0 + index,
      successful_p95_latency_ms: 30.0 + index,
      support_source: :direct_local,
      generation: 1
    }

    {key, summary}
  end)

Process.put(:strategy_evidence_benchmark_summaries, summaries)
ctx = LatencyWeighted.prepare_context("bench", 1, "eth_getBalance", 5_000)

for _ <- 1..500 do
  LatencyWeighted.rank_channels(channels, "eth_getBalance", ctx, "bench", 1)
end

rank_runs =
  for _ <- 1..5 do
    {microseconds, _result} =
      :timer.tc(fn ->
        for _ <- 1..2_000 do
          LatencyWeighted.rank_channels(channels, "eth_getBalance", ctx, "bench", 1)
        end
      end)

    microseconds / 2_000
  end

record_ctx =
  RequestContext.new(1, "eth_getBalance", [], request_id: "benchmark-request")
  |> Map.put(:opts, %RequestOptions{
    profile: "bench",
    strategy: :latency_weighted,
    timeout_ms: 5_000
  })

record_channel = hd(channels)

record_runs =
  for _ <- 1..5 do
    Lasso.Benchmarking.BenchmarkStore.clear_chain_metrics("bench", 1)
    :ets.delete(:lasso_instance_state, {:health_routing, record_channel.instance_id})

    {microseconds, _result} =
      :timer.tc(fn ->
        for _ <- 1..20_000 do
          Observability.record_attempt(
            record_ctx,
            record_channel,
            record_channel.instance_id,
            {:ok, :result, 25}
          )
        end

        :sys.get_state(Lasso.Benchmarking.BenchmarkStore)
      end)

    microseconds / 20_000
  end

breaker_id = {"strategy-evidence-breaker-benchmark", :http}

{:ok, _breaker_pid} =
  CircuitBreaker.start_link(
    {breaker_id, %{failure_threshold: 5, recovery_timeout: 60_000, success_threshold: 1}}
  )

for _ <- 1..500 do
  CircuitBreaker.call(breaker_id, fn -> {:ok, :result, 25} end, 5_000)
end

:sys.get_state(CircuitBreaker.via_name(breaker_id))

breaker_runs =
  for _ <- 1..5 do
    {microseconds, _result} =
      :timer.tc(fn ->
        for _ <- 1..10_000 do
          CircuitBreaker.call(breaker_id, fn -> {:ok, :result, 25} end, 5_000)
        end

        :sys.get_state(CircuitBreaker.via_name(breaker_id))
      end)

    microseconds / 10_000
  end

IO.inspect(
  %{
    revision: System.get_env("LASSO_BENCHMARK_REVISION") || "working-tree",
    otp: System.otp_release(),
    elixir: System.version(),
    cardinality: %{ranking_channels: 32, evidence_keys: 1},
    rank_32_us_per_call: rank_runs,
    record_us_per_event: record_runs,
    breaker_us_per_call: breaker_runs
  },
  label: "STRATEGY_EVIDENCE"
)
