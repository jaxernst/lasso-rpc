---
name: review-changes
description: Pre-commit review workflow to catch issues before they're committed
---

# Pre-Commit Review

Comprehensive pre-commit review to ensure code quality, test coverage, and no regressions.

## Workflow

### 1. Git Status Check

```bash
git status
git diff --stat
```

- What files changed?
- Are all changes intentional?
- Any unexpected modifications or generated files?

### 2. Compilation & Warnings

```bash
mix compile --warnings-as-errors
```

Zero compilation errors and zero warnings. Fix before committing.

### 3. Test Suite

```bash
mix test --exclude battle --exclude slow
```

All tests pass. No new failures.

### 4. Static Analysis

```bash
mix credo --strict
```

Any new Credo issues? Fix design and readability issues at minimum.

### 5. Code Review

```bash
git diff
```

Check for:
- Clear, self-documenting code
- Appropriate error handling
- No commented-out code or debug statements (`IO.inspect`, `IO.puts`)
- New code has corresponding tests
- No hardcoded credentials or secrets

### 6. Contextual Checks

**If modifying providers:** Adapter implements behaviour, tests cover validation, config updated.

**If modifying request pipeline:** Failover logic intact, circuit breaker correct, telemetry maintained.

**If modifying WebSocket:** Connection lifecycle handled, subscriptions multiplexed, gap-filling preserved.

**If modifying configuration:** Backward compatible, documented, validation updated.

## Output Format

```
PRE-COMMIT REVIEW
=================

FILES CHANGED:
  [file list with +/- lines]

COMPILATION: PASS/FAIL
TESTS: PASS/FAIL (N/N in Xs)
CREDO: PASS/FAIL (N new issues)
CODE REVIEW: [notes]
CONTEXTUAL CHECKS: [if applicable]

OVERALL: READY TO COMMIT / NOT READY

SUGGESTED COMMIT MESSAGE:
-------------------------
[message]
```

## Auto-fix

If user says "fix it", can automatically:
1. Remove unused aliases
2. Remove debug statements (`IO.inspect`, `IO.puts` in non-test code)
3. Format code (`mix format`)

Confirm before auto-fixing.
