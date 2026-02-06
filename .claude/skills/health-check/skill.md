---
name: health-check
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

**Expected:** All tests pass.

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

```
LASSO RPC HEALTH CHECK
========================

Compilation: PASS/FAIL (N warnings)
Tests: PASS/FAIL (N/N passed in Xs)
Credo: PASS/FAIL (N issues)
Dialyzer: PASS/FAIL (N warnings)

DETAILS:
--------
[details for any failures]
```
