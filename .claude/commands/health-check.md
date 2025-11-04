---
description: Run comprehensive health check on Lasso RPC codebase (compile, warnings, tests, static analysis)
---

# Lasso RPC Health Check

Run a comprehensive health check to validate the codebase is in good shape.

## Execution Order

Run these checks in sequence and report results:

### 1. Compilation Check
```bash
mix compile --warnings-as-errors
```

**Expected:** Zero compilation errors or warnings.

**If warnings exist:** Report them grouped by type (unused functions, unused aliases, deprecations).

### 2. Fast Test Suite
```bash
mix test --exclude battle --exclude slow --max-failures 5
```

**Expected:** All tests pass. Max runtime ~30 seconds.

**If failures:** Report first 5 failures with file:line references.

### 3. Credo Analysis
```bash
mix credo --strict --format=flycheck
```

**Expected:** Zero issues at strict level.

**If issues:** Group by category (design, readability, refactor) and count.

### 4. Dialyzer Type Check
```bash
mix dialyzer
```

**Expected:** Zero type warnings.

**If warnings:** Report with context about whether they're known false positives.

## Output Format

Provide a clear, actionable summary:

```
🏥 LASSO RPC HEALTH CHECK
========================

✅ Compilation: PASS (0 warnings)
✅ Tests: PASS (142/142 passed in 28.3s)
✅ Credo: PASS (0 issues)
⚠️  Dialyzer: 3 warnings

DETAILS:
--------
Dialyzer warnings:
  1. lib/lasso/core/transport/transport.ex:10 - unused alias HTTP
  2. lib/lasso/core/transport/transport.ex:10 - unused alias WebSocket
  3. lib/lasso/core/transport/websocket/websocket.ex:169 - unused function generate_request_id/0

RECOMMENDATION: Run /code-cleanup to fix these issues automatically.
```

## When to Use

- Before committing changes
- After major refactoring
- When starting work for the day
- Before creating a PR
- As a pre-push git hook

## Success Criteria

All checks pass with zero warnings/errors. If any check fails, provide clear next steps for resolution.
