# Lasso RPC Open Source Release Checklist

This document tracks the work required to prepare Lasso RPC for open source release.

## Completed Work

### Security Fixes

- [x] Removed hardcoded API keys from `config/profiles/default.yml`
- [x] Removed hardcoded API keys from `config/profiles/testnet.yml`
- [x] Removed legacy `config/chains.yml` (superseded by profiles system)
- [x] Updated runtime.exs to not default to chains.yml path

### Bug Fixes

- [x] Fixed `ProfileSelector.get_profile_data/1` to pass profile context to `ConfigStore.get_chain/2`

### Code Cleanup

- [x] Deleted `erl_crash.dump` (5.8MB crash dump)
- [x] Deleted `test/lasso/core/request/request_pipeline_test.exs.bak` (backup file)
- [x] Deleted `lib/lasso/core/providers/adapters/flashbots.ex` (notes-only file, not an adapter)
- [x] Renamed `lib/lasso_web/components/app_header.ex` to `dashboard_header.ex` (matches module name)

---

## Required Before Public Release

### Critical: Git History Cleanup

Before making the repository public, you MUST clean the git history to remove committed secrets.

```bash
# Check if chains.yml was ever committed with secrets
git log --all --full-history -- config/chains.yml

# If secrets exist in history, use BFG Repo-Cleaner:
# 1. Install BFG: brew install bfg
# 2. Create a file with secrets to remove (one per line)
# 3. Run: bfg --replace-text secrets.txt
# 4. Run: git reflog expire --expire=now --all && git gc --prune=now --aggressive
# 5. Force push to remote (coordinate with team first!)
```

**Secrets to check for in history:**

- Alchemy API key: `fNX8dFL_on49XdPAq4WmGJjxeQscfs0k`
- DRPC API key: `AsX7SwWUH0vGkFOHPHzUyaGtM9G3rgMR8LnWQrxF2MGT`
- Lava API key: `c8ce92e7c11c66d297bddc4c7315d677`
- 1RPC API key: `3obFgyJdJdY9t6Stq`
- Chainstack API key: `23176815cc2d60f44ef134679c79ab8f`
- CDP API credentials (from .env if ever committed)
- Privy credentials (from .env if ever committed)

### Critical: Rotate All Exposed Credentials

After cleaning git history, rotate these API keys in their respective dashboards:

- [ ] Alchemy API key
- [ ] DRPC API key
- [ ] Lava Network API key
- [ ] 1RPC API key
- [ ] Chainstack API key (if used)
- [ ] CDP API credentials
- [ ] Privy credentials

### Required: OSS Essential Files

- [ ] **LICENSE** - Create with AGPL-3.0 text (as specified in PRODUCT_SPEC_V2.md)
- [ ] **CONTRIBUTING.md** - Contribution guidelines including:
  - Development setup instructions
  - Code style guidelines
  - PR process
  - Testing requirements
  - Code of conduct reference
- [ ] **CHANGELOG.md** - Version history

### Required: Documentation Updates

- [ ] Update README.md with:
  - Clear installation instructions
  - Configuration guide (profiles system)
  - Quick start for self-hosting
  - Remove/update fly.dev URLs to use placeholders

---

## Recommended Improvements

### Documentation Sync & Cleanup

**Many existing docs are outdated and need review/rewriting.** The codebase has evolved significantly (profiles system, transport-agnostic architecture, etc.) but documentation hasn't kept pace.

#### Outdated Documentation Requiring Review

- [ ] `project/ARCHITECTURE.md` - Review for accuracy with current implementation
- [ ] `project/OBSERVABILITY.md` - May reference old patterns
- [ ] `project/RPC_STANDARDS_AND_SUPPORT.md` - Verify method support is current
- [ ] `project/EVENT_FLOW_ARCHITECTURE_ANALYSIS.md` - Check against current event system
- [ ] `project/STATE_CONSISTENCY_MONITORING.md` - Verify monitoring approach is current
- [ ] `docs/PRODUCT_SPEC_V2.md` - Large doc (72KB) - review for accuracy
- [ ] `docs/PRODUCT_SPEC_TECHNICAL_ANALYSIS.md` - May contain stale analysis
- [ ] `docs/specs/ROUTING_PROFILES_DESIGN_V4.3.md` - Verify implementation matches spec

#### Inline Documentation (moduledocs)

While coverage is good (~97%), some modules may have outdated descriptions:

- [ ] Audit key modules for accuracy: `ConfigStore`, `RequestPipeline`, `Selection`
- [ ] Update any docs referencing `chains.yml` to reference profiles system

### Documentation Consolidation

Move valuable docs from `project/` to `docs/` (after sync/cleanup):

- [ ] `project/ARCHITECTURE.md` → `docs/ARCHITECTURE.md`
- [ ] `project/OBSERVABILITY.md` → `docs/OBSERVABILITY.md`
- [ ] `project/RPC_STANDARDS_AND_SUPPORT.md` → `docs/RPC_STANDARDS.md`
- [ ] `project/TEST_GUIDE.md` → `docs/TESTING.md`

Delete internal/stale docs:

- [ ] `docs/specs/ROUTING_PROFILES_DESIGN.md` (superseded by V4.3)
- [ ] `docs/DOCUMENTATION_MIGRATION.md` (internal working doc)
- [ ] `project/prompts/` directory (internal AI prompts)
- [ ] `project/working/` directory (work-in-progress docs)
- [ ] Empty directories: `project/plans/`, `project/specifications/`

After migration, consider deleting the entire `project/` directory.

### Code Quality

- [ ] Replace `assert true` placeholder tests in `request_pipeline_test.exs` (15+ tests)
- [ ] Fix or remove skipped tests in `connection_telemetry_test.exs`
- [ ] Add test coverage for profiles feature (currently zero tests)

### Known Limitations

- **BenchmarkStoreAdapter profile hardcoding**: Functions `get_provider_performance/3`, `get_method_performance/2`, and `get_provider_transport_performance/4` hardcode `profile = "default"`. Fixing requires changing the `Metrics` behaviour interface.

---

## Optional Polish

### Additional Files

- [ ] `SECURITY.md` - Security policy and vulnerability reporting
- [ ] `CODE_OF_CONDUCT.md` - Community standards
- [ ] `.tool-versions` - Version management for asdf/mise
- [ ] `config/profiles/default.yml.example` - Template with placeholder values

### Build Configuration

- [ ] Add explicit OTP version requirement to `mix.exs`
- [ ] Update `tailwind` dependency from `~> 0.2.0` to `~> 0.3.0`

### CI/CD

- [ ] Add GitHub Actions workflow for automated testing
- [ ] Add pre-commit hooks for secret scanning

---

## Release Process

1. Complete all "Required Before Public Release" items
2. Complete recommended documentation consolidation
3. Create a clean branch from cleaned history
4. Tag version (e.g., v0.1.0)
5. Make repository public
6. Announce release
