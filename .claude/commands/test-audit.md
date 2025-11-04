---
description: Audit test suite quality and identify high-impact improvements (staff-level testing philosophy)
---

# Test Suite Audit and Quality Improvement

Perform a targeted, high-impact review of the Lasso RPC test suite using staff-level engineering judgment.

**Philosophy:** Quality over coverage. 10 excellent tests that catch real bugs > 100 tests that pass trivially.

## Execution Workflow

Follow this assess → prioritize → focus → execute workflow:

### 1. High-Level Assessment (5-10 min)

Build a mental model of test suite health:

**Run test suite:**
```bash
mix test --exclude battle --exclude slow
```

**Check for issues:**
- How many tests? How long do they take?
- Are there compilation warnings?
- Any failing tests?
- Any skipped tests?

**Explore organization:**
```bash
find test/ -name "*.exs" | head -20
grep -r "@tag :skip" test/ | wc -l
grep -r "# TODO" test/ | wc -l
```

**Think like a staff engineer:**
- Are critical paths tested? (request pipeline, selection, failover, circuit breaker)
- Do tests validate behavior or just implementation details?
- Would these tests catch real bugs?
- Can I find tests for a given module intuitively?

### 2. Problem Identification (5 min)

Categorize issues by impact:

**Critical (Address Immediately):**
- Critical path modules with zero tests
- CI broken or blocking PRs
- Test suite so slow developers skip it

**High (Address Soon):**
- Important features lack meaningful tests
- Many empty test stubs creating false coverage
- Tests exist but are low quality
- Test organization chaotic

**Medium (Nice to Have):**
- Minor coverage gaps in non-critical areas
- Some tests are slow but not critical

### 3. Focus Area Selection (2-3 areas max)

Pick 2-3 areas based on **impact × feasibility**:

**Type A: Critical Coverage Gaps**
- Add tests for untested critical paths
- **IMPORTANT:** ALWAYS follow the test specification workflow:
  1. Read and understand the module deeply
  2. Create test specification document
  3. Get tech-lead-problem-solver agent review
  4. Only implement after approval

**Type B: Test Quality & Cleanup**
- Delete empty stubs or implement them
- Remove tests that never run (skipped >1 month)
- Fix tests with no assertions
- Remove flaky tests

**Type C: Test Framework Improvements**
- Simplify confusing mock setup
- Fix real flakiness issues
- Make it easier to test new modules

**Type D: Organization**
- Clear tag taxonomy
- Fast default suite
- Documentation matches reality

### 4. Focused Execution (30-45 min per area)

For each focus area:

**Adding tests (Type A):**
1. Read module deeply - understand contracts and critical paths
2. Create test specification:
   - Which behaviors to test
   - Critical test cases (happy path + key edge cases)
   - Mock strategy and boundaries
   - Expected test execution time
3. Get tech-lead-problem-solver review on spec
4. Implement only approved tests
5. Run tests to verify

**Cleaning tests (Type B):**
1. Identify low-value tests
2. Run each test to confirm it's not catching anything
3. Delete confidently
4. Run full suite to verify no regressions

**Improving infrastructure (Type C):**
1. Identify confusing or duplicative patterns
2. Simplify, don't over-engineer
3. Document the 80% case
4. Test the improvements

**Organizing (Type D):**
1. Follow conventions that make tests easy to find
2. Use consistent tags
3. Update documentation

### 5. Report Results

Provide structured output:

```
TEST SUITE AUDIT REPORT
=======================

CURRENT STATE:
- Tests: 142 total (135 passing, 7 skipped)
- Runtime: 28.3s (acceptable)
- Coverage: Unknown (no coverage tool configured)

ASSESSMENT:
✅ Working Well:
  - Integration tests are well-organized
  - Test runtime is fast
  - Core request pipeline has good coverage

⚠️  Issues Found:
  - 7 empty test stubs in test/lasso/providers/ (creating false confidence)
  - CircuitBreaker has only 2 tests, missing state transition coverage
  - StreamCoordinator gap-filling logic not tested
  - 12 tests tagged :skip with no issue references

FOCUS AREAS SELECTED:
1. Critical Coverage: Add CircuitBreaker state machine tests
2. Cleanup: Delete 7 empty test stubs
3. Organization: Audit :skip tags and create issues or delete

WORK COMPLETED:
1. ✅ Deleted 7 empty test stubs in test/lasso/providers/
   - adapter_registry_test.exs: removed 3 empty stubs
   - provider_pool_test.exs: removed 4 empty stubs

2. ✅ Added CircuitBreaker tests (12 new tests, 2m 15s)
   - State transitions (closed → open → half-open → closed)
   - Threshold behaviors
   - Timeout and recovery
   - All tests passing

3. ⚠️  Skip tag audit: In progress (4/12 reviewed)

NEXT SESSION:
- Complete skip tag audit
- Add StreamCoordinator gap-filling tests
- Review adapter test strategy (unit vs integration)

TEST RESULTS:
Before: 142 tests (135 passing, 7 skipped)
After:  147 tests (147 passing, 0 skipped)
Runtime: 28.3s → 32.1s (acceptable increase)
```

## Important Guidelines

**Critical: No AI Slop Tests**

Never write unfocused, low-quality tests just to hit coverage targets.

Characteristics of "AI slop" to avoid:
- Testing trivial getters/setters
- Testing framework/library code
- Brittle tests that break on any refactoring
- Complex setup that obscures what's being tested
- Tests that would never catch a real bug

**Mandatory workflow for new tests:**
1. Always create test specification first
2. Always get tech-lead-problem-solver review
3. Only implement after approval
4. Be prepared to defend why each test provides value

**Safety guidelines:**
- Always read files before editing
- Grep for references before deleting functions
- Check tests for usage of seemingly dead code
- Run tests after each change
- Commit frequently

## When to Use

- Weekly test suite health check
- Before major refactoring
- When test suite feels cluttered
- After adding significant features
- When CI is slow or flaky

## Success Criteria

**Per session:**
- Made meaningful progress on 2-3 focus areas
- Improved confidence or reduced risk
- No regressions (tests still pass)
- Clear handoff for next iteration

**Overall (over time):**
- Critical paths have tests that catch real bugs
- Test suite fast enough for regular use
- Low noise (few skipped/flaky/empty tests)
- Reasonable coverage where it matters
