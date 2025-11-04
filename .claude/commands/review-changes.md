---
description: Pre-commit review workflow to catch issues before they're committed
---

# Pre-Commit Review

Comprehensive pre-commit review to ensure code quality, test coverage, and no regressions.

## When to Use

- Before creating a commit
- After implementing a feature
- Before creating a PR
- After fixing a bug

## Review Workflow

### 1. Git Status Check

```bash
git status
git diff --stat
```

**Review:**
- What files changed?
- Are all changes intentional?
- Any unexpected modifications?
- Any generated files that shouldn't be committed?

### 2. Compilation & Warnings

```bash
mix compile --warnings-as-errors
```

**Verify:**
- Zero compilation errors
- Zero warnings (unused functions, aliases, variables)
- If warnings exist, fix them before committing

### 3. Test Suite

```bash
mix test --exclude battle --exclude slow
```

**Verify:**
- All tests pass
- No new test failures
- Test runtime reasonable (<1 minute for fast suite)
- If tests fail, fix before committing

### 4. Static Analysis

```bash
mix credo --strict
```

**Review:**
- Any new Credo issues introduced?
- Are issues legitimate or false positives?
- Fix design and readability issues at minimum

**Optional (if time permits):**
```bash
mix dialyzer
```

### 5. Code Review

**Review the actual code changes:**

```bash
git diff
```

**Check for:**

**Code Quality:**
- Clear, self-documenting code
- Appropriate error handling
- No commented-out code
- No debug print statements (`IO.inspect`, `IO.puts`)
- Consistent with Elixir conventions

**Testing:**
- New code has corresponding tests
- Tests are meaningful, not just coverage
- Tests follow existing patterns
- No empty test stubs

**Documentation:**
- Public functions have `@doc`
- Complex logic has explanatory comments
- README updated if needed
- Architecture docs updated if significant changes

**Security:**
- No hardcoded credentials or secrets
- Input validation where appropriate
- No obvious vulnerabilities

**Performance:**
- No obvious performance issues
- Appropriate use of concurrency
- Database queries optimized (if applicable)

### 6. Contextual Checks (Based on Changes)

**If modifying providers:**
- Adapter properly implements behaviour
- Tests cover capability validation
- Configuration examples updated

**If modifying request pipeline:**
- Failover logic intact
- Circuit breaker integration correct
- Observability/telemetry maintained

**If modifying WebSocket code:**
- Connection lifecycle handled
- Subscriptions properly multiplexed
- Gap-filling logic preserved

**If modifying configuration:**
- Changes backward compatible
- Documented in README or architecture docs
- Config validation updated

### 7. Integration Check (Optional)

**For significant changes, test manually:**

```bash
# Start server
mix phx.server

# Test relevant endpoints
curl -X POST http://localhost:4000/rpc/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# Check logs for errors
```

## Output Format

Provide clear pass/fail report:

```
PRE-COMMIT REVIEW
=================

FILES CHANGED:
  lib/lasso/core/selection/selection.ex (+45, -12)
  lib/lasso/core/providers/pool.ex (+23, -8)
  test/lasso/core/selection_test.exs (+67, -0)

✅ COMPILATION: PASS (0 warnings)

✅ TESTS: PASS
   142/142 tests passed (28.3s)

✅ CREDO: PASS
   0 new issues

⚠️  CODE REVIEW NOTES:
   - Added new selection strategy: :latency_weighted
   - Tests cover happy path and edge cases
   - Documentation updated in selection.ex
   - No performance concerns

✅ CONTEXTUAL CHECKS:
   - Selection strategy follows existing pattern
   - ProviderPool integration verified
   - Telemetry events added for new strategy

OVERALL: ✅ READY TO COMMIT

SUGGESTED COMMIT MESSAGE:
-------------------------
Add latency-weighted provider selection strategy

Implements new selection strategy that distributes requests
based on inverse latency scores, giving better-performing
providers proportionally more traffic.

- Add latency_weighted strategy to Selection module
- Update ProviderPool to track latency scores
- Add comprehensive test coverage (10 new tests)
- Update documentation with strategy details
```

## If Issues Found

**Report issues clearly:**

```
PRE-COMMIT REVIEW
=================

❌ COMPILATION: FAIL
   3 warnings found:
   - lib/lasso/core/selection.ex:45 - unused alias Strategy
   - lib/lasso/core/providers/pool.ex:89 - unused function calculate_score/1

RECOMMENDATION: Fix compilation warnings before committing.

❌ TESTS: FAIL
   2/142 tests failed:
   - test/lasso/core/selection_test.exs:67 - assertion failed
   - test/lasso/core/selection_test.exs:89 - timeout

RECOMMENDATION: Fix failing tests before committing.

⚠️  CODE REVIEW:
   - Found debug IO.inspect statement in selection.ex:123
   - TODO comment without issue reference in pool.ex:45
   - New public function lacks @doc annotation

OVERALL: ❌ NOT READY TO COMMIT

Fix these issues first, then run /review-changes again.
```

## Auto-fix Common Issues (If Requested)

If user says "fix it" or "auto-fix", can automatically:

1. **Remove unused aliases:**
   - Remove unused `alias` statements flagged in warnings

2. **Remove debug statements:**
   - Remove `IO.inspect`, `IO.puts` in non-test code

3. **Add missing @doc:**
   - Add basic `@doc` placeholders for undocumented public functions

4. **Format code:**
   ```bash
   mix format
   ```

**Always confirm before auto-fixing:**
```
Found 3 auto-fixable issues:
1. Remove unused alias in selection.ex
2. Remove IO.inspect in pool.ex
3. Add @doc to new public function

Auto-fix these issues? (y/n)
```

## Success Criteria

All checks pass:
- ✅ Compilation clean
- ✅ All tests pass
- ✅ Credo clean
- ✅ Code review passed
- ✅ Contextual checks passed

## Integration with Git Hooks

This command can be used as a pre-commit hook:

```bash
# .git/hooks/pre-commit
#!/bin/bash
mix compile --warnings-as-errors || exit 1
mix test --exclude battle --exclude slow || exit 1
mix credo --strict || exit 1
```

Make executable: `chmod +x .git/hooks/pre-commit`
