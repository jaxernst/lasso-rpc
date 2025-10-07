# Test Suite Sync, Audit, and Quality Improvement Pass

## Overview

Perform a targeted, high-impact review and enhancement of the Lasso RPC test suite. This prompt is designed to be run repeatedly as the codebase evolves—each session performs a fresh assessment, identifies the most critical issues, and focuses on 2-3 high-priority improvements.

**Philosophy:**

This is an exercise in **staff-level engineering judgment**. Apply first principles thinking to evaluate test value, not coverage metrics. A test suite should provide confidence and catch regressions—not create maintenance burden. Be skeptical. Question whether tests are worth their cost. Favor deleting worthless tests over achieving coverage targets.

**Principles:**

- **Quality over coverage** - 10 excellent tests that catch real bugs > 100 tests that pass trivially
- **Lean is good** - Tests are code. Code is liability. Less is more.
- **Skepticism is healthy** - Many tests provide false confidence or test implementation details that will change
- **Simple is good** - Complex test setup, brittle mocks, and clever abstractions rot quickly
- **ROI thinking** - Every test has maintenance cost. Does it pay for itself by catching bugs?
- **Pragmatism over dogma** - Sometimes low coverage is fine. Sometimes integration tests are better than unit tests.

---

## Workflow

This audit follows a **assess → prioritize → focus → execute** workflow:

1. **High-Level Assessment**: Understand the current test landscape through exploration and observation
2. **Problem Identification**: Apply engineering judgment to categorize issues by impact and severity
3. **Focus Area Selection**: Pick 2-3 critical areas where improvements will provide outsized value
4. **Focused Execution**: Deep dive and fix the selected areas with ruthless prioritization
5. **Document & Recommend**: Report what was done and what remains for next iteration

---

## Step 1: High-Level Assessment

**Goal:** Build a mental model of the test suite's health through exploration and observation.

### Understand the Landscape

Explore the test suite to understand:

- **Coverage vs Quality**: Which critical modules lack tests? Which have tests but poor quality?
- **Test Organization**: Is it clear what's being tested? Can you find tests for a given module?
- **Test Velocity**: How long does the default suite take? Are there obvious bottlenecks?
- **Test Reliability**: Do tests pass consistently? Are there flaky or perpetually skipped tests?
- **Test Infrastructure**: Are mocks clear and maintainable? Is the Battle framework actually useful?

**Methods are up to you.** You might:

- Run the test suite and observe what happens
- Check coverage reports (if available)
- Explore test files and compare to source structure
- Look for patterns (empty stubs, skipped tests, timeout issues)
- Read a few test files to assess quality
- Check architectural documentation to understand what should be tested

### Think Like a Staff Engineer

Ask yourself:

**Coverage Questions:**

- Are the critical paths tested? (Request pipeline, selection, failover, circuit breaker)
- Do untested modules represent real risk or just coverage anxiety?

**Quality Questions:**

- Do tests validate behavior or just implementation details?
- Are there tests that would never catch a real bug?
- Are integration tests actually testing integration or just slow unit tests?
- Do battle tests validate SLOs or just generate logs?
- Do we have sufficient observability into the system?
- How can we gain more assurances that Lasso will work well in real-world scenarios?
- For telemetry-driven features (smart routing, provider scoring), are we validating the feedback loops work correctly?
- Are there system properties that need continuous validation rather than one-time assertions?

**Infrastructure Questions:**

- Is the mock strategy coherent or confusing?
- Do we need to improve/expand test infrastructure to support more critical integration tests?
- How can we test against real-world providers to discover faults that may occur in production environments?
- How can we simulate real world faults such as node sync errors, infrastructure issues, rate limiting, etc.

**Organization Questions:**

- Can I find tests for a given module intuitively?
- Are tags used consistently or are they a mess?
- Is it clear which tests run in CI vs manually?
- Are there obvious "categories" of tests (unit, integration, battle)?
- Are we focussing too much on a particular test type? Are the categories of tests that we're missing or under-developed?

**Pragmatic Questions:**

- If I were joining this project, would tests give me confidence?
- What would break if we deleted tests with zero assertions?
- Are there tests that exist only to hit coverage targets?
- Where would time investment provide the most value?

---

## Step 2: Problem Identification & Prioritization

**Goal:** Apply engineering judgment to categorize issues by impact.

### Severity Framework

Use this framework as a guide, not a checklist:

**Critical Priority (Address Immediately)**

These issues block development or represent unacceptable risk:

- Critical path modules have zero tests (e.g., request routing, provider selection)
- CI is broken or flaky enough to block PRs
- Test suite takes so long developers skip running it locally

**High Priority (Address Soon)**

These issues create friction or technical debt:

- Important features lack meaningful tests
- Many empty test stubs creating false sense of coverage
- Tests exist but are low quality (test implementation details, brittle, never catch bugs)
- Test organization is chaotic (can't find tests, unclear what runs when)
- Battle/integration tests are all broken or provide no value

**Medium Priority (Nice to Have)**

These are improvements but not urgent:

- Minor coverage gaps in non-critical areas
- Opportunities to simplify test infrastructure
- Documentation could be clearer
- Some tests are slow but not critically so

### Be Ruthlessly Pragmatic

**Don't fall into coverage traps:**

- 80% coverage with poor tests is worse than 40% with excellent tests
- Critical paths at 90% > everything at 60%
- Untested utility functions might be fine if they're simple

**Question test value:**

- Does this test catch real bugs or just break when refactoring?
- Would I notice if this test disappeared?
- Is this testing framework code or business logic?
- Is this an integration test that should be a unit test (or vice versa)?

**Recognize sunk cost:**

- Empty test stubs are not "progress toward coverage" - they're debt
- Half-finished battle tests that never run are waste
- Complex mock infrastructure nobody understands is liability

---

## Step 3: Focus Area Selection

**Based on your assessment, select 2-3 focus areas for this session.**

Prioritize by **impact × feasibility**:

- Will this meaningfully improve confidence or reduce risk?
- Can I make real progress in 30-45 minutes?
- Are there dependencies blocking this work?

### Focus Area Types

**Type A: Critical Coverage Gaps**

Add tests for critical paths that lack coverage. Be selective—only test what matters.

**Good candidates:**

- Request routing/pipeline (core business logic)
- Provider selection strategies (failover depends on this)
- Circuit breaker state machine (safety critical)
- Gap detection in streaming (data consistency critical)

**Poor candidates:**

- Config loading (low risk, simple code)
- Logging modules (hard to test meaningfully)
- Adapter boilerplate (better tested via integration)

**IMPORTANT:** For this focus area type, you MUST follow the test specification and tech-lead review workflow (see Step 4). Never write tests directly. Always spec first, get approval, then implement.

**Type B: Test Quality & Cleanup**

Remove noise and improve signal-to-noise ratio.

**Good targets:**

- Empty test stubs (delete or implement, don't leave half-done)
- Tests that never run (skipped for >1 month)
- Tests with no assertions (just logs/prints)
- Battle tests that don't validate SLOs
- Flaky tests causing CI pain

**Poor targets:**

- Tests that are "ugly" but work fine
- Coverage gaps that don't represent real risk
- Trying to achieve coverage targets for their own sake

**Type C: Test Framework Improvements**

Improve infrastructure when it's blocking productivity.

**Good investments:**

- Simplifying confusing mock setup
- Making it easier to test new modules
- Fixing real flakiness issues
- Clarifying what mocks to use when

**Poor investments:**

- Building elaborate test frameworks nobody asked for
- Over-abstracting test helpers
- Trying to DRY test code at expense of clarity

**Type D: Test Environment & Organization**

Fix organization when it's creating real confusion.

**Good wins:**

- Clear tag taxonomy so developers know what runs when
- Fast default suite for quick feedback
- Integration tests actually test integration
- Documentation exists and matches reality

**Poor uses of time:**

- Perfect directory structure
- Comprehensive test documentation nobody will read
- Enforcing style rules in test code

---

## Step 4: Focused Execution

### Work with Intent

For each focus area:

1. **Be clear on the goal** - What specific outcome are you targeting?
2. **Work incrementally** - Small changes, run tests, repeat
3. **Measure impact** - Did coverage increase? Did tests become clearer?
4. **Know when to stop** - Diminishing returns are real

### Staff-Level Practices

**When adding tests:**

**IMPORTANT:** Never write tests without a clear plan. Low-quality, unfocused tests are worse than no tests.

**Required workflow for adding new test coverage:**

1. **Read and understand the module deeply**

   - What are the public functions and their contracts?
   - What are the critical paths and edge cases?
   - What dependencies exist and where are the boundaries?
   - What behavior actually matters vs implementation details?

2. **Create a test specification document**

   Write a focused test plan that includes:

   **Test Case Specification:**

   - Which specific behaviors/functions are being tested
   - What are the critical test cases (happy path, error cases, edge cases)
   - Which test cases provide the most value (be selective)
   - Which test cases can be skipped (don't test everything)

   **Test Setup Specification:**

   - What mocks are required and why
   - What test data/fixtures are needed
   - What process setup is required (GenServers, registries, etc.)
   - What isolation/cleanup is needed between tests
   - Expected test execution time (<100ms unit, <2s integration)

   **Test Strategy:**

   - Unit vs integration approach and rationale
   - Mock boundaries (what gets mocked, what stays real)
   - How will this catch real bugs (not just achieve coverage)

3. **Use the tech-lead-problem-solver agent for review**

   **Before implementing any tests**, hand off your specification to the tech-lead-problem-solver agent:

   ```
   Task: Review test specification for [ModuleName]

   Prompt: "I'm planning to add test coverage for [module]. Here's my specification:

   [paste your test case spec and setup spec]

   Please review this specification and provide feedback on:
   - Are these the right test cases? Am I missing critical scenarios?
   - Is the mock strategy sound? Am I mocking at the right boundaries?
   - Will these tests catch real bugs or just test implementation details?
   - Is this focused enough or am I over-testing?
   - Any concerns about test complexity or brittleness?

   Be critical. Push back if this isn't focused or won't provide value."
   ```

4. **Only implement after review and approval**

   After receiving feedback:

   - Adjust specification based on tech-lead feedback
   - Implement the approved test cases (not more, not less)
   - Keep tests simple and focused on the agreed scope
   - Run tests to verify they work and provide value

**Principles for test implementation:**

- Start with happy path, add edge cases only if they matter
- Mock at boundaries, not internal details
- Test behavior, not implementation
- Write tests you'd want to debug at 3am
- If a test feels complex, question whether it's the right test

**When deleting tests:**

- Run the test first to confirm it's not catching anything
- Check git blame to understand intent
- Delete confidently—tests are code, not sacred

**When improving infrastructure:**

- Make it simpler, not more clever
- Optimize for debugging failed tests, not elegant abstraction
- Document the 80% case, not every edge case

**When organizing:**

- Follow conventions that make tests easy to find
- Don't reorganize for aesthetics
- Tags are for filtering, not taxonomy for its own sake

### Know When to Stop

**Stop working on a focus area if:**

- You've spent 30-45 minutes (diminishing returns)
- You hit a blocker (needs refactoring, unclear requirements)
- You've achieved the goal (critical path is tested, noise is removed)

**Don't:**

- Try to achieve 100% coverage
- Implement every empty stub
- Build the perfect test framework
- Document everything exhaustively

**Do:**

- Fix the most important 2-3 things
- Document remaining work
- Ship incremental improvements

---

## Step 5: Document & Recommend

### Report Structure

**Assessment Summary:**

- What's the current state? (coverage, quality, organization, velocity)
- What are the critical gaps or issues?
- What's working well?

**Focus Areas Selected:**

- Why these 2-3 areas? (impact × feasibility)
- What's the specific goal for each?

**Work Completed:**

- What did you add/fix/delete?
- What's the measurable impact? (coverage delta, tests added/removed, runtime change)
- Specific file:line references

**Test Results:**

- Before/after metrics (runtime, test count, coverage)
- Any regressions or surprises

**Remaining Work:**

- What are the next priority areas?
- What blockers exist?
- What would you tackle next session?

### Staff-Level Communication

**Be direct:**

- "These 19 empty stubs provide no value—I deleted them"
- "CircuitBreaker has zero tests and is critical—I added 8 tests covering the state machine"
- "Battle tests don't assert anything—they just log. Deleted 6, kept 2 that validate SLOs"

**Share judgment:**

- "RequestPipeline is critical path but untested. This is high risk."
- "BenchmarkStore has low coverage but it's mostly data structure code. Acceptable risk."
- "The mock strategy is confusing. I simplified it but there's more work here."

**Recommend pragmatically:**

- "Next session: AdapterRegistry and StreamCoordinator (critical, untested)"
- "Consider: Can we test adapters via integration instead of unit tests?"
- "FYI: Battle framework is over-engineered. Most tests could be simpler integration tests."

---

## Reference Information

### Test Taxonomy (Suggested)

**Execution Speed:**

- **(default)** - Fast unit tests with mocks (<100ms)
- `:integration` - Multi-module tests, real HTTP client, mock providers (<2s)
- `:slow` - Real provider tests or long-running scenarios (>5s)

**Test Type:**

- `:battle` - Chaos engineering validating SLOs under failure
- `:real_providers` - Hits actual RPC providers (expensive, manual only)

**Stability:**

- `:skip` - Temporarily disabled (must have issue reference or delete)
- `:flaky` - Under investigation (must have issue reference)

**Consider removing:**

- `:fast`, `:quick` (default tests are fast)
- Domain tags like `:websocket`, `:failover` (use describe blocks)

### Architectural Layers (for Context)

**Critical Path (must test):**

- Request pipeline and routing
- Provider selection and failover
- Circuit breaker state machine
- Streaming gap detection and backfill

**High Value (should test):**

- Provider adapters
- Transport abstraction
- Subscription multiplexing
- Health monitoring

**Lower Priority (test if simple):**

- Benchmarking/metrics
- Config loading
- Utility modules
- Observability/logging

### Battle Test Decision Framework

For `test/battle/` tests, apply this framework:

**Delete if:**

- No assertions (just logs/prints)
- Perpetually skipped (>1 month)
- Could be a simple integration test
- Framework validation (move to test/support)

**Keep if:**

- Validates specific SLO under chaos
- Asserts on measurable outcomes
- Actually runs and catches issues
- Can't be tested any other way

**Fix if:**

- Good intent but needs stability work
- Missing assertions but scenario is valuable
- Tagged wrong (not really a battle test)

### Beyond Traditional Tests: Telemetry & Data-Driven Validation

Lasso uses telemetry and observability for smart routing, fault detection, and continuous improvement. Some system behaviors—particularly those involving active feedback loops—may not be well-suited to traditional unit tests.

**If priority warrants, consider:**

- **Health checks**: Validate telemetry is flowing and metrics are being collected correctly
- **Data collection tests**: Capture metrics during workloads for offline analysis (not pass/fail)
- **Statistical assertions**: Test properties over time ("routing should improve", "scores should converge")
- **Feedback loop validation**: Verify that observed behavior (latency, errors) affects routing decisions

The battle framework could potentially expand to support these patterns. Don't over-engineer for current state—only explore if there's a clear gap that traditional tests can't address and the priority justifies the investment.

### Test Patterns (Examples)

**Good unit test:**

```elixir
test "selects highest scoring provider" do
  # Setup is clear and minimal
  providers = [
    %{id: "fast", score: 100},
    %{id: "slow", score: 50}
  ]

  # Test behavior, not implementation
  assert {:ok, "fast"} = Selection.pick_provider(providers, strategy: :fastest)
end
```

**Good integration test:**

```elixir
@tag :integration
test "failover to backup provider on timeout" do
  # Real HTTP client, mock provider responses
  setup_providers(["primary", "backup"])

  # Simulate primary timeout
  set_timeout("primary", :infinity)

  # Verify failover behavior
  assert {:ok, result} = make_request("eth_blockNumber")
  assert_used_provider("backup")
end
```

**Good battle test:**

```elixir
@tag :battle
@tag :slow
test "maintains 99% success during provider chaos" do
  result = Scenario.new("failover test")
    |> Scenario.run_workload(duration: 60_000)
    |> Scenario.kill_random_providers(interval: 10_000)
    |> Scenario.analyze()

  # Assert on SLO
  assert result.success_rate >= 0.99
end
```

---

## Success Criteria

**Per session:**

- Made meaningful progress on 2-3 focus areas
- Improved confidence or reduced risk
- No regressions (tests still pass)
- Clear handoff for next iteration

**Overall (measured over time):**

- Critical paths have good tests that catch real bugs
- Test suite is fast enough for regular use
- Developers can add tests easily
- Low noise (few skipped/flaky/empty tests)
- Reasonable coverage where it matters (not everywhere)

---

## Notes

- **This is iterative** - Don't try to fix everything at once
- **Judgment over metrics** - Coverage numbers lie; bug-catching matters
- **Quality over quantity** - Deleting tests is often the right move
- **Simple over clever** - Test code rots faster than production code
- **Pragmatic over perfect** - Ship incremental improvements
- **Skeptical over dogmatic** - Question whether tests add value
- **Staff-level thinking** - What would you want if this was your production system?

### Critical: No AI Slop Tests

**Never write unfocused, low-quality tests that just hit coverage targets.**

Characteristics of "AI slop" tests to avoid:

- Test trivial getters/setters or data structure access
- Test framework/library code instead of business logic
- Brittle tests that break on any refactoring
- Tests with complex setup that obscure what's being tested
- Tests that would never catch a real bug
- Tests written to hit a coverage percentage

**Mandatory workflow:**

- **Always** create a test specification before implementing tests
- **Always** get tech-lead-problem-solver agent review on the spec
- **Only** implement tests after approval and feedback incorporation
- Be prepared to defend why each test case provides value

**Remember:** Tests are a means to an end (confidence, bug-catching), not an end themselves. Focused, high-quality tests that catch real bugs are the only tests worth writing.
