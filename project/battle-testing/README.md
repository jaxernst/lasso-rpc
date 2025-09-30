# Battle Testing Framework Documentation

**Prove your system is bulletproof with data-driven chaos testing.**

---

## Overview

This directory contains the complete specification for Lasso RPC's battle testing framework - a pragmatic system for validating reliability under controlled chaos.

**What is Battle Testing?**

Battle testing validates system behavior under realistic failure conditions by:

1. Generating production-like load (HTTP/WS requests)
2. Injecting controlled failures (provider crashes, network issues)
3. Measuring system behavior (latency, failover, circuit breakers)
4. Verifying SLOs with data-driven proof

**Why Battle Testing?**

Unit tests validate isolated behaviors. Battle tests validate **system resilience** - the thing end users actually care about.

---

## Documentation Structure

### 📖 [QUICK_START.md](./QUICK_START.md) - **Start Here**

Get your first battle test running in 30 minutes.

**For:** Developers who want to write their first test immediately.

**Contents:**

- Step-by-step tutorial
- Simple examples
- Common patterns
- Troubleshooting

### 🏗️ [TECHNICAL_SPEC.md](./TECHNICAL_SPEC.md) - **Architecture & API**

Complete technical specification of the framework.

**For:** Engineers implementing the framework or writing advanced tests.

**Contents:**

- Architecture (5 core layers)
- API reference with examples
- Integration points (Telemetry, BenchmarkStore)
- Mock provider design
- Data flow diagrams
- Design decisions

### 📋 [IMPLEMENTATION_PLAN.md](./IMPLEMENTATION_PLAN.md) - **Phased Rollout**

Clear handoff document with 4-week implementation plan.

**For:** Project managers, implementation teams, code reviewers.

**Contents:**

- 4 weekly phases with deliverables
- Acceptance criteria per phase
- Time estimates (30-40 hours per phase)
- Risk mitigation
- Success metrics
- Handoff checklist

### 📝 [BATTLE_TESTING.md](./BATTLE_TESTING.md) - **Original Analysis**

The strategic analysis that led to this framework.

**For:** Understanding why battle testing is the right approach.

**Contents:**

- Comparison: unit tests vs integration tests vs battle tests
- Value proposition for Lasso RPC
- Alignment with product vision
- Initial recommendations

---

## Quick Navigation

**I want to...**

| Goal                        | Start Here                                         |
| --------------------------- | -------------------------------------------------- |
| Write my first battle test  | [QUICK_START.md](./QUICK_START.md)                 |
| Understand the architecture | [TECHNICAL_SPEC.md](./TECHNICAL_SPEC.md)           |
| Implement the framework     | [IMPLEMENTATION_PLAN.md](./IMPLEMENTATION_PLAN.md) |
| Understand the strategy     | [BATTLE_TESTING.md](./BATTLE_TESTING.md)           |

---

## Key Concepts

### Composable Primitives

Battle tests are built from simple, reusable components:

```elixir
Scenario.new("Test Name")
|> Scenario.setup(setup_fn)         # Configure providers
|> Scenario.workload(workload_fn)   # Generate load
|> Scenario.chaos(chaos_spec)       # Inject failures
|> Scenario.collect(collectors)     # Capture metrics
|> Scenario.slo(slo_specs)          # Define success criteria
|> Scenario.run()                   # Execute test
```

### Observable by Default

Every test captures:

- **Request metrics:** Latency, success rate, failovers
- **Circuit breaker events:** State changes, recovery time
- **System metrics:** Memory, processes, CPU
- **Telemetry events:** Production instrumentation

### Data-Driven Proof

Tests generate actionable reports:

- **JSON:** Machine-readable for CI/CD
- **Markdown:** Human-readable summaries
- **HTML:** Rich interactive reports with charts
- **Baseline comparison:** Regression detection

---

## Example: Complete Test

```elixir
defmodule Livechain.Battle.HTTPFailoverTest do
  use ExUnit.Case, async: false

  alias Livechain.Battle.{Scenario, Workload, Chaos, Reporter}

  @moduletag :battle
  @moduletag timeout: :infinity

  test "HTTP requests succeed despite provider failures" do
    result =
      Scenario.new("HTTP Failover Under Load")
      |> Scenario.setup(fn ->
        # Start 3 mock providers
        MockProvider.start_providers([
          {:provider_a, latency: 50, reliability: 1.0},
          {:provider_b, latency: 100, reliability: 1.0},
          {:provider_c, latency: 150, reliability: 1.0}
        ])

        # Seed metrics for routing
        BenchmarkStore.record_rpc_call("testchain", "provider_a", "eth_blockNumber", 50, :success)
        BenchmarkStore.record_rpc_call("testchain", "provider_b", "eth_blockNumber", 100, :success)
        BenchmarkStore.record_rpc_call("testchain", "provider_c", "eth_blockNumber", 150, :success)

        {:ok, %{chain: "testchain"}}
      end)
      |> Scenario.workload(fn ->
        # 9000 requests over 3 minutes (50 req/s)
        Workload.http_constant(
          chain: "testchain",
          method: "eth_blockNumber",
          rate: 50,
          duration: 180_000,
          strategy: :fastest
        )
      end)
      |> Scenario.chaos(
        # Provider A flaps (down 10s, up 60s)
        Chaos.flap_provider("provider_a", down: 10_000, up: 60_000)
      )
      |> Scenario.collect([:requests, :circuit_breaker, :system])
      |> Scenario.slo(
        success_rate: 0.99,
        p95_latency_ms: 300,
        max_failover_latency_ms: 2000
      )
      |> Scenario.run()

    # Generate reports
    Reporter.save_json(result, "priv/battle_results/")
    Reporter.save_markdown(result, "priv/battle_results/")

    # Assertions
    assert result.passed?, result.summary
    assert result.analysis.failover_count > 0
  end
end
```

**Output:** Data-driven proof that your system handles provider failures with 99% success rate.

---

## Implementation Timeline

| Phase       | Duration | Goal                 | Key Deliverable            |
| ----------- | -------- | -------------------- | -------------------------- |
| **Phase 1** | Week 1   | Core primitives      | First working test         |
| **Phase 2** | Week 2   | Chaos & integration  | Failover test with chaos   |
| **Phase 3** | Week 3   | Analysis & reporting | Production-quality reports |
| **Phase 4** | Week 4   | CI/CD automation     | Automated pipeline         |

**Total:** 4 weeks, 80-100 hours, 1-2 engineers

---

## Design Philosophy

### 1. Pragmatism Over Perfection

- **Mock providers by default** (fast, deterministic)
- **Real providers optional** (for occasional validation)
- **No time acceleration** (simpler, more realistic)
- **Streaming data collection** (handles long tests)

### 2. Deep Integration

- **Uses production telemetry** (validates instrumentation)
- **Leverages BenchmarkStore** (realistic routing)
- **Tests real code paths** (no mocks of Lasso internals)

### 3. Composable Primitives

- **Simple functions** (not complex DSL)
- **Clear control flow** (no magic)
- **Reusable components** (write tests in 15 minutes)

### 4. Observable by Default

- **Every test generates reports** (JSON + Markdown + HTML)
- **SLO verification automatic** (clear pass/fail)
- **Regression detection built-in** (baseline comparison)

---

## What Gets Tested

### Critical Failure Modes

✅ **Provider Failover**

- Primary provider crashes
- Requests fail over to backup
- Circuit breaker behavior
- Recovery time

✅ **WebSocket Continuity**

- Subscription survives disconnection
- No duplicate events
- Gap filling works
- Reconnection successful

✅ **Concurrent Load**

- System handles high RPS
- No memory leaks
- Latency remains stable
- Load balances correctly

✅ **Provider Degradation**

- Slow responses handled
- Timeouts work correctly
- Failover triggered appropriately
- System recovers

✅ **Long-Running Stability**

- No memory leaks over time
- Metrics remain accurate
- Circuit breakers recover
- Subscriptions stay alive

---

## Success Criteria

After implementation, you'll be able to answer:

### Reliability Questions

- ✅ What's our success rate under load? (99.8%)
- ✅ How long does failover take? (P95: 150ms)
- ✅ Do circuit breakers recover? (Yes, within 60s)
- ✅ Can we handle provider flapping? (Yes, <0.01% loss)

### Performance Questions

- ✅ What's our P95 latency? (120ms)
- ✅ How much overhead does Lasso add? (15ms)
- ✅ What's our max throughput? (500 RPS/node)
- ✅ Do we have memory leaks? (No, stable over 48h)

### Operational Questions

- ✅ Are we ready for production? (Yes, SLOs pass)
- ✅ What are our known limits? (Documented)
- ✅ How do we detect regressions? (Automatic baseline comparison)

---

## Getting Started

### For Developers

1. Read [QUICK_START.md](./QUICK_START.md)
2. Write your first test (30 minutes)
3. Review [TECHNICAL_SPEC.md](./TECHNICAL_SPEC.md) for advanced usage
4. Add tests for your critical failure modes

### For Implementation Team

1. Review [IMPLEMENTATION_PLAN.md](./IMPLEMENTATION_PLAN.md)
2. Set up dev environment (`mix deps.get`)
3. Start with Phase 1, Week 1
4. Demo progress weekly

### For Project Managers

1. Allocate 1-2 engineers for 4 weeks
2. Schedule weekly demos (end of each phase)
3. Prepare for CI runs (~$10/month)
4. Plan customer demo (Week 4)

---

## File Structure (After Implementation)

```
project/battle-testing/         # Documentation (this directory)
├── README.md                   # You are here
├── QUICK_START.md              # 30-minute tutorial
├── TECHNICAL_SPEC.md           # Architecture & API
├── IMPLEMENTATION_PLAN.md      # 4-week rollout
└── BATTLE_TESTING.md           # Strategic analysis

lib/livechain/battle/           # Framework source (to be created)
├── scenario.ex
├── workload.ex
├── chaos.ex
├── collector.ex
├── analyzer.ex
├── reporter.ex
└── mock_provider.ex

test/battle/                    # Battle tests (to be created)
├── http_failover_test.exs
├── ws_subscription_test.exs
├── concurrent_load_test.exs
└── ...

priv/battle_results/            # Reports (gitignored)
├── 2025-09-30-http-failover.json
├── 2025-09-30-http-failover.md
└── baseline.json
```

---

## FAQ

### Q: How is this different from unit tests?

**A:** Unit tests validate isolated behaviors. Battle tests validate **system resilience** under realistic failure conditions. Both are needed.

### Q: How long do battle tests take?

**A:** Fast tests (CI): 1-5 minutes. Full tests (nightly): 30-60 minutes.

### Q: Do we test against real providers?

**A:** Mock providers by default (fast, deterministic). Real providers optional for occasional validation.

### Q: What if tests are flaky?

**A:** Mock providers are deterministic. If flaky, increase timeouts or loosen SLOs initially.

### Q: How do we know if performance regresses?

**A:** Baseline comparison automatically detects regressions (±10% threshold).

### Q: Can we use this for load testing?

**A:** Yes, but focus is on **reliability under chaos**, not peak throughput. For pure load testing, use dedicated tools.

---

## Support

**Questions about:**

- **Writing tests:** See [QUICK_START.md](./QUICK_START.md)
- **Architecture:** See [TECHNICAL_SPEC.md](./TECHNICAL_SPEC.md)
- **Implementation:** See [IMPLEMENTATION_PLAN.md](./IMPLEMENTATION_PLAN.md)
- **Strategy:** See [BATTLE_TESTING.md](./BATTLE_TESTING.md)

**Blockers:**

- Review troubleshooting section in QUICK_START.md
- Check example tests in TECHNICAL_SPEC.md
- Ask in team chat with specific error

---

## Next Steps

1. **Read QUICK_START.md** - Get hands-on immediately
2. **Write first test** - Prove it works
3. **Review IMPLEMENTATION_PLAN.md** - Understand the roadmap
4. **Start Phase 1** - Build the foundation

**Ready to build bulletproof infrastructure?** Start with QUICK_START.md. 🚀
