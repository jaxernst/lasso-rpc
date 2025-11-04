---
name: elixir-quality
description: Maintain zero-warning, high-quality Elixir codebase with automatic detection and fixes
---

# Elixir Code Quality Agent

Automatically maintain Lasso RPC codebase quality by detecting and fixing compilation warnings, static analysis issues, and code smells.

## When to Auto-Invoke

This skill should be **automatically triggered** when:

1. **Compilation warnings are detected**
   - Unused functions, aliases, or variables
   - Deprecation warnings (especially Phoenix LiveView)
   - Type warnings

2. **User requests cleanup**
   - User says: "clean up code", "fix warnings", "check quality"
   - Before commits or PRs

3. **After significant changes**
   - After adding new modules
   - After refactoring

## Core Responsibilities

### 1. Detect Quality Issues

Run comprehensive checks:

```bash
# Compilation warnings
mix compile --warnings-as-errors

# Static analysis
mix credo --strict

# Type checking
mix dialyzer

# Test suite health
mix test --exclude battle --exclude slow
```

### 2. Automatic Fixes (Safe, Common Issues)

**Fix without asking:**
- Remove unused `alias` statements
- Remove unused variables (prefix with `_`)
- Fix simple deprecations (e.g., Phoenix LiveView API updates)
- Format code with `mix format`
- Remove trailing whitespace

**Examples of auto-fixes:**

```elixir
# BEFORE: Unused alias
alias Lasso.RPC.Transport.{HTTP, WebSocket}
# ... only HTTP used

# AFTER: Clean
alias Lasso.RPC.Transport.HTTP

---

# BEFORE: Unused function
defp generate_request_id do
  UUID.uuid4()
end

# AFTER: Deleted (if no references found)

---

# BEFORE: Unused variable
def handle_call({:process, request}, from, state) do
  # ... from not used

# AFTER: Fixed
def handle_call({:process, request}, _from, state) do

---

# BEFORE: Deprecated LiveView assign
assign(socket, :foo, value)

# AFTER: Current API
assign(socket, foo: value)
```

### 3. Report Complex Issues

**Ask before fixing:**
- Removing entire functions (if grep shows possible references)
- Structural refactoring
- Changing function signatures
- Dialyzer type issues (often false positives)

### 4. Verify Changes

After making fixes:

```bash
# Ensure compilation clean
mix compile

# Ensure tests still pass
mix test --exclude battle --exclude slow

# Verify no new issues
mix credo --strict
```

## Workflow

### Step 1: Detect (Automatic)

Detect quality issues by running all checks.

### Step 2: Categorize

**Safe to auto-fix:**
- Unused aliases (verified with grep)
- Unused variables in function signatures
- Simple deprecations with clear replacements
- Formatting issues

**Needs confirmation:**
- Unused functions (might be called dynamically)
- Complex deprecations
- Structural changes

**Report only:**
- Dialyzer warnings (often need suppression, not fixes)
- Credo design issues (need architectural decisions)

### Step 3: Fix

For safe issues:
1. Make the fix
2. Run tests
3. If tests pass, report change
4. If tests fail, revert and report

For complex issues:
1. Report the issue
2. Suggest fix options
3. Wait for user confirmation

### Step 4: Report

Provide clear summary:

```
🔧 ELIXIR QUALITY AUTO-FIX
=========================

ISSUES DETECTED:
  3 unused aliases
  1 unused function
  2 unused variables
  5 formatting issues

AUTO-FIXED (Safe):
  ✅ Removed 3 unused aliases
     - lib/lasso/core/transport/transport.ex:10
     - lib/lasso/jsonrpc/error.ex:9
     - lib/lasso/core/selection.ex:15

  ✅ Fixed 2 unused variables
     - lib/lasso/core/request/pipeline.ex:45 (_from)
     - lib/lasso/core/providers/pool.ex:89 (_opts)

  ✅ Formatted 12 files

NEEDS REVIEW:
  ⚠️  Unused function: generate_request_id/0
      Location: lib/lasso/core/transport/websocket/websocket.ex:169
      No direct references found, but might be called dynamically.
      Delete this function? (y/n)

VERIFICATION:
  ✅ Compilation: PASS (0 warnings)
  ✅ Tests: PASS (142/142)
  ✅ Credo: 2 issues remaining (design-level)

REMAINING ISSUES (Manual):
  - Credo: Function handle_info/2 has cyclomatic complexity of 12
    Location: lib/lasso/core/streaming/coordinator.ex:234
    Recommendation: Consider extracting helper functions

SUMMARY: Fixed 10 issues automatically, 3 issues need manual review.
```

## Resources

Use these resources for guidance:

- `resources/common-patterns.md` - Common warning patterns and fixes
- `resources/api-updates.md` - Phoenix/LiveView API migration guide
- `/health-check` slash command - Run full quality check
- `/code-cleanup` slash command - Manual cleanup workflow

## Integration with Other Features

**Compose with:**
- `/health-check` - Use for initial detection
- `/code-cleanup` - Use for complex manual cleanup
- `elixir-phoenix-expert` subagent - Delegate complex issues

**Before invoking subagent:**
- Try automatic fixes first
- Only delegate if issue requires architectural decisions
- Provide context about what was already attempted

## Safety Guardrails

**Never auto-fix:**
- Public API changes (breaking changes)
- Database migrations
- Configuration changes
- Test files (unless obviously safe like formatting)
- Production code that changes behavior

**Always verify:**
- Grep for references before deleting functions
- Run tests after every change
- Confirm compilation passes
- Check git diff makes sense

**Fail gracefully:**
- If auto-fix causes test failure, revert immediately
- Report what failed and why
- Ask user how to proceed

## Example Invocations

**User:** "I'm getting compilation warnings, can you clean them up?"

**Agent:** *Invokes elixir-quality skill*
- Detects 5 unused aliases
- Auto-fixes them
- Runs tests (pass)
- Reports changes
- Asks about 1 unused function

**User:** "Fix the code quality issues"

**Agent:** *Invokes elixir-quality skill*
- Runs health-check internally
- Fixes safe issues automatically
- Reports complex issues for review

**Automatic trigger:** After running `mix compile`, Claude sees warnings

**Agent:** *Auto-invokes elixir-quality skill*
- "I noticed 3 compilation warnings. Let me fix those automatically..."
- Fixes issues
- Reports results

## Success Criteria

- Zero compilation warnings
- Credo strict passes (or only design-level issues remain)
- All tests pass
- Code formatted consistently
- User didn't have to manually fix trivial issues

## Notes

- This skill should feel invisible - just clean up mess automatically
- Only surface issues that genuinely need human judgment
- Speed matters - don't spend time on perfect solutions, just get to clean
- Safety first - if unsure, ask rather than break things
