# Codebase Structural Cleanup & Code Quality Review

## Overview
Perform a systematic, multi-phase review and cleanup of the Lasso RPC codebase to identify and eliminate:
- Dead code (unused functions, stale comments, obsolete patterns)
- Code smells (duplicative handlers, inconsistent patterns)
- Static analysis issues (Credo warnings, Dialyzer type issues)
- Documentation drift (stale comments, outdated TODOs)

## Approach

This is a **large codebase** that requires incremental, focused cleanup. Break the work into digestible chunks organized by architectural layer.

### Phase 1: Automated Analysis & Baseline

**Goal:** Establish current code quality metrics and identify low-hanging fruit.

1. **Run Credo** for style and consistency issues:
   ```bash
   mix credo --strict
   ```
   - Group issues by severity (design, readability, refactor, warning)
   - Prioritize design-level issues and consistency problems
   - Skip trivial formatting issues if they're auto-fixable

2. **Run Dialyzer** for type issues:
   ```bash
   mix dialyzer
   ```
   - Focus on contract violations and type mismatches
   - Document any intentional violations that should be suppressed

3. **Identify dead code patterns:**
   - Search for stale comment markers: `grep -rn "Legacy\|no longer\|removed\|TODO\|FIXME\|HACK" lib/`
   - Find unused functions: Look for private functions with no references
   - Locate obsolete backwards-compatibility code

4. **Document findings** in a structured report with counts and examples.

### Phase 2: Layer-by-Layer Deep Dive

**Goal:** Systematically review each architectural layer for code smells and cleanup opportunities.

Review modules in this order (from transport layer up):

#### Layer 1: Transport & Connection Management
- `lib/lasso/core/transport/websocket/` (handler, connection, websocket)
- `lib/lasso/core/transport/http/`
- `lib/lasso/core/transport/registry.ex`
- `lib/lasso/core/transport/channel.ex`

**Focus areas:**
- Unused message handlers or backwards-compatibility code
- Duplicative error handling patterns
- Stale PubSub broadcasts that aren't consumed
- Unused fields in state structs

#### Layer 2: Provider & Selection Logic
- `lib/lasso/core/providers/`
- `lib/lasso/core/selection/`
- `lib/lasso/circuit_breaker/`

**Focus areas:**
- Unused provider capabilities tracking
- Stale selection strategy code
- Circuit breaker state cleanup

#### Layer 3: Request & Streaming Pipeline
- `lib/lasso/core/request/`
- `lib/lasso/core/streaming/`
- `lib/lasso/rpc/` (subscription management)

**Focus areas:**
- Dead subscription confirmation handlers
- Unused dedupe/marker fields
- Obsolete failover logic

#### Layer 4: Application & Configuration
- `lib/lasso/application.ex`
- `lib/lasso/config/`
- `lib/lasso_web/`

**Focus areas:**
- Unused configuration options
- Stale supervisor children
- Dead endpoints or controllers

### Phase 3: Pattern Consolidation

**Goal:** Identify and consolidate duplicative patterns discovered during deep dive.

1. **Duplicative message handlers:**
   - Example: Multiple `handle_websocket_message` clauses that differ only in telemetry tags
   - Consolidate into parameterized functions

2. **Inconsistent error normalization:**
   - Ensure all error paths use `ErrorNormalizer.normalize/2`
   - Standardize error context metadata

3. **PubSub event structure:**
   - Audit all PubSub topics and ensure events follow consistent tuple structure
   - Document expected event schemas

4. **Telemetry emission:**
   - Standardize telemetry event naming and metadata
   - Remove redundant or unused telemetry points

### Phase 4: Documentation & Comment Hygiene

**Goal:** Ensure comments and documentation are accurate and useful.

1. **Remove stale comments:**
   - Comments referring to removed features ("no longer", "legacy", "removed")
   - Outdated architectural notes
   - Commented-out code blocks

2. **Update misleading comments:**
   - References to components that were renamed or removed (e.g., "MessageAggregator")
   - Incorrect behavioral descriptions

3. **Resolve TODOs:**
   - Categorize TODOs as: actionable now, defer, or obsolete
   - Create issues for deferred work
   - Remove obsolete TODOs

4. **Add missing documentation:**
   - Document public API functions lacking `@doc`
   - Add module-level `@moduledoc` where missing
   - Document non-obvious design decisions

## Execution Strategy

### For Each Phase:

1. **Create a focused task list** using TodoWrite tool
2. **Work incrementally** - complete one module/layer at a time
3. **Test after changes** - run `mix test` after each module cleanup
4. **Commit frequently** - small, atomic commits per cleanup type
5. **Document decisions** - if choosing not to remove something, add a comment explaining why

### Safety Guidelines:

- **Always read files before editing** - understand context before removing code
- **Grep for references** before deleting functions/fields
- **Check tests** for usage of seemingly dead code
- **Preserve backwards compatibility** unless explicitly removing deprecated features
- **Ask for confirmation** on ambiguous cases

## Output Format

For each phase, provide:

1. **Summary of issues found** (counts by category)
2. **Specific changes made** with file:line references
3. **Decisions deferred** and why
4. **Test results** confirming no regressions
5. **Recommendations** for follow-up work

## Example Workflow

```
# Phase 1
User: "Run codebase cleanup - Phase 1"
Agent:
  1. Runs credo, dialyzer, grep for markers
  2. Creates structured report with counts
  3. Asks: "I found 47 issues. Should I proceed with cleanup?"

# Phase 2 - Layer 1
User: "Proceed with Layer 1 cleanup"
Agent:
  1. Creates todo list for Layer 1 modules
  2. Reviews each module sequentially
  3. Makes changes, runs tests
  4. Provides summary with file:line references

# Continue through layers...
```

## Success Criteria

- Zero Credo warnings at `--strict` level (or documented suppressions)
- Zero Dialyzer warnings (or documented suppressions)
- No stale comment markers (`no longer`, `removed`, `legacy`)
- All TODOs resolved or converted to tracked issues
- Test suite passes with 100% success rate
- Documented architectural decisions for any intentional "smells"

## Notes

- This cleanup is **not about adding features** - it's about removing cruft
- Prioritize **safety over speed** - when in doubt, ask
- Focus on **high-value cleanup** - don't bikeshed trivial issues
- Keep the user informed - surface interesting findings and decisions
