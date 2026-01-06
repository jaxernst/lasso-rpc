# Lasso RPC Open Source Release Checklist

Comprehensive checklist tracking all work required to prepare Lasso RPC for public open source release.

**Last Updated**: 2026-01-04

---

## ✅ Completed Work

### Security

- [x] Removed hardcoded API keys from `config/profiles/default.yml`
- [x] Removed hardcoded API keys from `config/profiles/testnet.yml`
- [x] Added `.env` to `.gitignore` (line 41)
- [x] Created `LICENSE.md` with AGPL-3.0

### Documentation

- [x] Migrated valuable docs from `project/` to `docs/`
- [x] Deleted `project/` directory entirely
- [x] Rewrote `ARCHITECTURE.md` (1,425 → 576 lines)
  - Added Profile System section
  - Added BlockSync section
  - Fixed all namespace inconsistencies
  - Updated supervision tree to profile-scoped reality
- [x] Updated `README.md` to be OSS-focused
- [x] Created `config/profiles/default.yml.example` with env var examples

### Code Quality

- [x] Namespace refactoring complete (all Core.\* modules)
- [x] Deleted crash dumps and backup files
- [x] Fixed ProfileSelector to use profile-aware ConfigStore calls

---

## 🔴 CRITICAL - Must Complete Before Public Release

### 1. Git History Cleanup ⚠️ BLOCKING

**Issue**: Git history contains 5+ exposed API keys that MUST be scrubbed.

**Exposed Keys** (must rotate after cleanup):

- Alchemy API key: `REDACTED_ALCHEMY_KEY_1`
- DRPC API key: `REDACTED_DRPC_KEY`
- Lava API key: `REDACTED_LAVA_KEY`
- 1RPC API key: `REDACTED_1RPC_KEY`
- Chainstack API key: `REDACTED_CHAINSTACK_KEY`

**Process**:

```bash
# 1. Create secrets file
cat > secrets.txt <<'EOF'
REDACTED_ALCHEMY_KEY_1==[REDACTED_ALCHEMY_KEY]
REDACTED_DRPC_KEY==[REDACTED_DRPC_KEY]
REDACTED_LAVA_KEY==[REDACTED_LAVA_KEY]
REDACTED_1RPC_KEY==[REDACTED_1RPC_KEY]
REDACTED_CHAINSTACK_KEY==[REDACTED_CHAINSTACK_KEY]
EOF

# 2. Clone fresh backup
git clone --mirror <repo> lasso-backup.git

# 3. Run BFG Repo-Cleaner
brew install bfg
bfg --replace-text secrets.txt

# 4. Clean up git metadata
git reflog expire --expire=now --all
git gc --prune=now --aggressive

# 5. Verify secrets removed
git log --all --full-history -p | grep -i "alchemy\|drpc\|lava"

# 6. Force push (COORDINATE WITH TEAM FIRST!)
git push --force --all
git push --force --tags
```

**After cleanup**:

- [ ] Rotate Alchemy API key in dashboard
- [ ] Rotate DRPC API key in dashboard
- [ ] Rotate Lava API key in dashboard
- [ ] Rotate 1RPC API key in dashboard
- [ ] Rotate Chainstack API key in dashboard

---

### 2. Delete Current `.env` File ⚠️ BLOCKING

**Issue**: `.env` file contains live CDP and Privy credentials (not tracked by git, but exists on disk).

```bash
# Delete from working directory
rm .env

# Verify not in git
git log --all --full-history -- .env
```

**Credentials to rotate**:

- [ ] CDP API Key ID and Secret
- [ ] Privy App ID and Secret

---

### 3. Secure Admin Endpoints ⚠️ BLOCKING

**Issue**: `/api/admin/*` routes provide full CRUD on chain configs with ZERO authentication.

**Affected files**:

- `lib/lasso_web/router.ex` (lines 45-52)
- `lib/lasso_web/controllers/admin/chain_controller.ex`

**Options**:

**Option A: Document auth requirement** (Recommended for initial release)

```markdown
## Admin API Security

The `/api/admin/*` endpoints provide administrative access to chain configuration.
These endpoints MUST be secured before deployment:

1. **Reverse proxy with OAuth2** (recommended)
2. **mTLS** for machine-to-machine auth
3. **Network isolation** (internal-only access)
4. **API key validation middleware**

Self-hosting users are responsible for implementing authentication.
```

**Option B: Add basic auth middleware** (blocks until implemented)

```elixir
# In router.ex, update admin scope:
scope "/api/admin", LassoWeb.Admin do
  pipe_through [:api, :require_admin_auth]  # Add this
  resources "/chains", ChainController, except: [:new, :edit]
end
```

**Decision needed**: [ ] Option A (document) or [ ] Option B (implement)

---

### 4. Deployment Configuration Templates ⚠️ BLOCKING

**Issue**: `fly.prod.toml` and `fly.staging.toml` hardcode your production app names.

**Current**:

```toml
# fly.prod.toml
app = 'lasso-rpc'  # Your production app!
PHX_HOST = 'lasso-rpc.fly.dev'
```

**Action**:

```bash
# Rename to templates
mv fly.prod.toml fly.prod.toml.example
mv fly.staging.toml fly.staging.toml.example

# Update with placeholders
sed -i '' 's/app = "lasso-rpc"/app = "YOUR_APP_NAME"/' fly.prod.toml.example
sed -i '' 's/PHX_HOST = "lasso-rpc.fly.dev"/PHX_HOST = "YOUR_DOMAIN"/' fly.prod.toml.example
```

- [ ] Create `fly.prod.toml.example`
- [ ] Create `fly.staging.toml.example`
- [ ] Update `deployment/DEPLOYMENT.md` with customization instructions
- [ ] Update `.gitignore` to ignore `fly.*.toml` (non-example versions)

---

### 5. Internal Documentation Cleanup ⚠️ BLOCKING

**Issue**: `docs/internal/` contains internal product specs and security analysis.

**Files to delete**:

```bash
rm -rf docs/internal/
```

**Contents**:

- `PRODUCT_SPEC_V3.md` (29 KB) - Internal product roadmap
- `PRODUCT_SPEC_TECHNICAL_ANALYSIS.md` (48 KB) - Security attack scenarios
- `ROUTING_PROFILES_DESIGN.md` (79 KB) - Internal design spec
- `OSS_RELEASE_CHECKLIST.md` (this file - move elsewhere before deletion)

**Action**:

- [ ] Move this checklist to private location
- [ ] Delete `docs/internal/` directory

---

## 🟡 High Priority (Should Complete)

### 6. Create CONTRIBUTING.md

Template structure:

```markdown
# Contributing to Lasso RPC

## Development Setup

- Prerequisites: Elixir 1.17+, OTP 26+, Node.js 18+
- Quick start: `mix deps.get && mix phx.server`
- Running tests: `mix test`

## Code Style

- Run Credo: `mix credo --strict`
- Run Dialyzer: `mix dialyzer`
- Format code: `mix format`

## Pull Request Process

1. Fork the repository
2. Create a feature branch
3. Write tests for new functionality
4. Ensure all tests pass
5. Submit PR with clear description

## Testing Requirements

- Unit tests for new modules
- Integration tests for request pipeline changes
- No placeholder `assert true` tests

## Code of Conduct

Be respectful and collaborative.
```

- [ ] Create `CONTRIBUTING.md`
- [ ] Update README.md to link to it

---

### 7. README.md URL Updates

**Issue**: README hardcodes your production URLs.

**Changes needed**:

- Line ~19: `https://lasso-rpc.fly.dev/dashboard` → Note as "example deployment"
- Line ~96: Add disclaimer about using your own deployment

```markdown
> **Note**: The dashboard URL above is an example. When self-hosting,
> access your dashboard at `http://localhost:4000/dashboard` or your
> configured domain.
```

- [ ] Update README with deployment disclaimers

---

### 8. GitHub Actions CI Workflow

**Current**: Only has `fly-deploy.yml` (deployment only)

**Needed**: Add `ci.yml` for PR validation:

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with:
          elixir-version: "1.17"
          otp-version: "26"
      - run: mix deps.get
      - run: mix compile --warnings-as-errors
      - run: mix test
      - run: mix credo --strict
      - run: mix dialyzer
```

- [ ] Create `.github/workflows/ci.yml`

---

## 🟢 Medium Priority (Nice to Have)

### 9. Additional Documentation Files

- [ ] `SECURITY.md` - Vulnerability reporting process
- [ ] `CHANGELOG.md` - Version history (start with v0.1.0)
- [ ] `.tool-versions` - asdf/mise version management (not currently using these so lets revisit)

---

### 10. Configuration Improvements

- [ ] Add explicit OTP version to `mix.exs`
- [ ] Update tailwind dependency `~> 0.2.0` → `~> 0.3.0`
- [ ] Create `docker-compose.yml` for local development

---

### 11. Test Coverage Improvements

**Known gaps** (from audit):

- [ ] Replace `assert true` placeholder tests in `request_pipeline_test.exs` (15+ tests)
- [ ] Fix or remove skipped tests in `connection_telemetry_test.exs`
- [ ] Add profile system test coverage (currently zero tests)

---

## 📋 Known Limitations (Document but Don't Block)

### ChainConfigManager Legacy Code

**Issue**: Dynamic config management via dashboard still uses `chains.yml` format, not profile-aware.

**Affected**:

- `lib/lasso/config/chain_config_manager.ex` (hardcodes `@config_file` to `chains.yml`)
- `lib/lasso_web/controllers/admin/chain_controller.ex` (uses ChainConfigManager)
- `lib/lasso_web/components/chain_configuration_window.ex` (uses ChainConfigManager)

**Decision**: Keep as-is for initial release, document as "legacy admin UI"

**Documentation needed**:

```markdown
## Admin UI Limitations

The dashboard configuration UI currently uses a legacy single-file config format.
For multi-profile setups, edit YAML files directly in `config/profiles/`.

Profile-aware admin UI planned for future release.
```

- [ ] Document in README or ARCHITECTURE.md

---

### chains.yml References

**Status**: Intentional migration support, not a bug

- 18 references to `chains.yml` remain in codebase
- Most are in `Backend.File` migration logic (intentional feature)
- Test files use `test_chains.yml`
- Comments explain legacy format

**Decision**: Keep migration support, it helps users transition

---

## 🎯 Release Readiness Checklist

Before making repository public:

**Phase 1: Security** (ALL BLOCKING)

- [ ] Git history cleaned (BFG)
- [ ] All exposed API keys rotated
- [ ] `.env` deleted from disk
- [ ] CDP/Privy credentials rotated
- [ ] Admin endpoints secured or documented
- [ ] Deployment configs converted to templates
- [ ] Internal docs deleted

**Phase 2: Documentation** (HIGH PRIORITY)

- [ ] CONTRIBUTING.md created
- [ ] README URLs updated
- [ ] Admin auth documented
- [ ] Deployment guide updated

**Phase 3: Automation** (NICE TO HAVE)

- [ ] GitHub Actions CI workflow added
- [ ] SECURITY.md created
- [ ] CHANGELOG.md started

**Phase 4: Final Verification**

- [ ] Test `mix deps.get && mix phx.server` on clean checkout
- [ ] Verify dashboard loads at localhost:4000
- [ ] Verify all tests pass
- [ ] Run `mix credo --strict` and `mix dialyzer`
- [ ] Check git history for any remaining secrets: `git log -p | grep -i "key\|secret\|password"`

---

## 🚀 Release Process

Once all blocking items complete:

1. Create `v0.1.0` tag
2. Make repository public
3. Announce on:
   - Elixir Forum
   - /r/elixir, /r/ethereum
   - Twitter/X
   - Farcaster
4. Monitor GitHub issues for questions
5. Respond to community feedback

---

## Questions & Decisions Needed

1. **Admin endpoint security**: Document requirements or implement auth middleware?
2. **Deployment examples**: Focus on Fly.io only or add Docker/K8s examples?
3. **Dashboard auth**: Should dashboard also require auth, or remain public read-only?
4. **ChainConfigManager**: Keep for v0.1.0 or remove entirely?

---

**Status Summary**:

- ✅ Completed: 10 items
- 🔴 Blocking: 5 items
- 🟡 High Priority: 3 items
- 🟢 Nice to Have: 6 items

**Total Progress**: 10/24 (42% complete)
