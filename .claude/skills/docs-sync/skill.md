---
name: docs-sync
description: Quick check for docs that are out of sync with code
---

# Documentation Sync Check

Quick audit to catch common documentation drift issues.

## Checks

### 1. Provider List Sync

```bash
# What providers are registered?
grep -A 1 '@provider_type_mapping' lib/lasso/core/providers/adapter_registry.ex

# What does README list?
grep -A 10 'Supported.*[Pp]roviders' README.md
```

Report if mismatch.

### 2. Broken File References

```bash
# Find file paths mentioned in docs
grep -roh 'lib/[^`"]*\.ex' project/ README.md | sort -u

# Check each exists
for file in $(grep -roh 'lib/[^`"]*\.ex' project/ README.md | sort -u); do
  [ -f "$file" ] || echo "Missing: $file"
done
```

Report broken paths.

### 3. Documentation TODOs

```bash
grep -rn "TODO\|FIXME\|WIP" project/ README.md
```

Report count and locations.

## Output Format

```
DOCS SYNC CHECK
==================

Provider List:
  README: [list]
  Registry: [list]
  [match status]

Broken References:
  [results]

Documentation TODOs:
  [count] found:
  [locations]

QUICK FIXES:
- [actionable items]
```
