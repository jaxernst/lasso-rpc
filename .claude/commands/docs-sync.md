---
description: Quick check for docs that are out of sync with code
---

# Documentation Sync Check

Quick audit to catch common documentation drift issues.

## What It Checks

**3 quick checks:**
1. **Provider list sync** - README vs adapter registry
2. **Broken references** - File paths that don't exist
3. **Stale TODOs** - Documentation markers to clean up

## Execution

### Check 1: Provider List (30 sec)

```bash
# What providers are registered?
grep -A 1 '@provider_type_mapping' lib/lasso/core/providers/adapter_registry.ex

# What does README list?
grep -A 10 'Supported.*[Pp]roviders' README.md
```

**Report if mismatch.**

### Check 2: Broken File References (1 min)

```bash
# Find file paths mentioned in docs
grep -roh 'lib/[^`"]*\.ex' project/ README.md | sort -u

# Check each exists
for file in $(grep -roh 'lib/[^`"]*\.ex' project/ README.md | sort -u); do
  [ -f "$file" ] || echo "Missing: $file"
done
```

**Report broken paths.**

### Check 3: Documentation TODOs (30 sec)

```bash
# Find TODO markers in docs
grep -rn "TODO\|FIXME\|WIP" project/ README.md
```

**Report count and locations.**

## Output Format

```
📚 DOCS SYNC CHECK
==================

Provider List:
  README: Alchemy, Cloudflare, LlamaRPC, PublicNode, Merkle
  Registry: Alchemy, Cloudflare, LlamaRPC, PublicNode, Merkle, DRPC, 1RPC
  ⚠️  Missing in README: DRPC, 1RPC

Broken References:
  ✅ No broken file paths found

Documentation TODOs:
  3 found:
  - project/ARCHITECTURE.md:145 - "TODO: Document adapter override"
  - project/FUTURE_FEATURES.md:23 - "TODO: Spec out caching"
  - README.md:273 - "TODO: Add websocket limitation"

QUICK FIXES:
- Add DRPC and 1RPC to README provider list
- Review 3 TODOs (resolve or create issues)
```

## When to Run

- Before releases
- Monthly maintenance
- After adding providers
- When docs feel stale

## Notes

Keep it simple - just catch the obvious drift. Perfect docs aren't the goal; accurate-enough docs are.
