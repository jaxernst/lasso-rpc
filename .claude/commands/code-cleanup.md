---
description: Systematic codebase cleanup to eliminate dead code, fix warnings, and improve code quality
---

# Codebase Structural Cleanup & Code Quality

Perform systematic cleanup of the Lasso RPC codebase to eliminate:
- Dead code (unused functions, stale comments)
- Code smells (duplicative patterns, inconsistencies)
- Static analysis issues (Credo warnings, Dialyzer type issues)
- Documentation drift (stale comments, outdated TODOs)

## Execution Strategy

Work incrementally through automated analysis and layer-by-layer review.

### Phase 1: Automated Analysis (10 min)

**Run Credo for style/consistency issues:**
```bash
mix credo --strict
```

Group issues by severity and prioritize design-level issues.

**Run Dialyzer for type issues:**
```bash
mix dialyzer
```

Focus on contract violations and type mismatches.

**Identify dead code patterns:**
```bash
# Stale comment markers
grep -rn "Legacy\|no longer\|removed" lib/

# TODOs and FIXMEs
grep -rn "TODO\|FIXME\|HACK" lib/

# Unused aliases (from compilation warnings)
mix compile 2>&1 | grep "unused alias"
```

**Document findings** with counts and examples.

### Phase 2: Quick Wins (15-20 min)

Focus on low-risk, high-impact fixes:

**1. Fix unused aliases and functions:**
- Remove unused `alias` statements
- Delete truly unused private functions (grep first!)
- Fix unused variables (prefix with `_`)

**2. Remove stale comments:**
```elixir
# Example: Delete comments like this
# Legacy: This used to handle MessageAggregator (removed)

# Update misleading comments about renamed components
```

**3. Fix obvious code smells:**
- Remove duplicated error handling
- Consolidate similar pattern matches
- Extract duplicative code to shared functions

**4. Update deprecations:**
- Phoenix LiveView `assign/3` → current API
- Any other deprecated function calls

### Phase 3: Layer-by-Layer Review (if time permits)

**Only do this if Phase 1 & 2 are complete and time allows.**

Review modules in order:

**Layer 1: Transport & Connection**
- `lib/lasso/core/transport/`

**Layer 2: Provider & Selection**
- `lib/lasso/core/providers/`
- `lib/lasso/core/selection/`

**Layer 3: Request & Streaming**
- `lib/lasso/core/request/`
- `lib/lasso/core/streaming/`

For each layer:
- Look for unused message handlers
- Check for duplicative error handling
- Remove unused state fields
- Clean up stale PubSub broadcasts

### Phase 4: Documentation Hygiene

**1. Remove stale comments:**
- References to removed features
- Commented-out code blocks
- Outdated architectural notes

**2. Resolve TODOs:**
- Categorize as: actionable now, defer, or obsolete
- Create GitHub issues for deferred work
- Remove obsolete TODOs

**3. Add missing docs (selectively):**
- Document non-obvious design decisions
- Add `@moduledoc` to public modules without docs
- Don't over-document - focus on "why" not "what"

## Safety Guidelines

**Before making changes:**
- Always read files before editing
- Grep for references before deleting anything
- Check tests for usage of "dead" code
- Understand context before removing code

**After changes:**
```bash
# Verify compilation
mix compile

# Run tests
mix test --exclude battle --exclude slow

# Verify no new issues
mix credo --strict
```

**Commit strategy:**
- Small, atomic commits per cleanup type
- Good commit messages explaining what and why
- Easy to review and revert if needed

## Output Format

Provide structured report:

```
CODE CLEANUP REPORT
===================

PHASE 1: AUTOMATED ANALYSIS
----------------------------
Credo Issues: 12 total
  - Design: 2
  - Readability: 5
  - Refactor: 3
  - Warning: 2

Dialyzer Warnings: 4
  - Unused aliases: 3
  - Contract violations: 1

Dead Code Markers:
  - "no longer": 2 occurrences
  - "TODO": 8 occurrences
  - Commented code: 3 blocks

PHASE 2: QUICK WINS COMPLETED
------------------------------
✅ Fixed 3 unused aliases
   - lib/lasso/core/transport/transport.ex:10 (HTTP, WebSocket)
   - lib/lasso/jsonrpc/error.ex:9 (JError)

✅ Removed 1 unused function
   - lib/lasso/core/transport/websocket/websocket.ex:169 (generate_request_id/0)

✅ Cleaned 2 stale comments
   - lib/lasso/core/streaming/stream_coordinator.ex:42
   - lib/lasso/core/providers/pool.ex:156

✅ Fixed 5 Credo warnings
   - Removed unused variables
   - Improved pattern matching clarity

VERIFICATION:
-------------
✅ Compilation: PASS (0 warnings)
✅ Tests: PASS (142/142)
✅ Credo: 7 issues remaining (down from 12)
✅ Dialyzer: 1 warning remaining

REMAINING WORK:
---------------
- 7 Credo issues (design-level, need careful review)
- 1 Dialyzer warning (known false positive, consider suppressing)
- 6 TODOs (need triage - defer vs obsolete)

RECOMMENDATIONS:
----------------
- Add dialyzer ignore for known false positive
- Schedule separate session for design-level Credo issues
- Triage TODOs in next planning session
```

## When to Use

- Monthly code quality check
- After major feature development
- Before release preparation
- When compilation warnings accumulate
- As part of tech debt sprints

## Success Criteria

- Zero compilation warnings
- Credo strict level pass (or documented exceptions)
- Dialyzer clean (or documented suppressions)
- No stale comment markers
- All TODOs resolved or tracked in issues
- Tests pass 100%
