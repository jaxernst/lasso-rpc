# Documentation Migration Working Document

Working notes for open source documentation. Old docs live in `project/`, new docs will live in `docs/`.

---

## Profile Configuration System

### Overview
Lasso uses a profile-based configuration system where each profile contains chain and provider configurations. Profiles enable multi-tenant setups and different routing configurations.

### Key Concepts

**Profile Structure:**
- `slug` - URL identifier (must match filename, e.g., `default.yml` has `slug: default`)
- `name` - Display name shown in UI (e.g., "Lasso Free")
- `type` - Profile type: `free`, `standard`, `premium`, `byok`
- `default_rps_limit` / `default_burst_limit` - Rate limiting defaults
- `chains` - Map of chain configurations with providers

**Default Profile Convention:**
- Routes without a profile slug use `config/profiles/default.yml`
- Convention over configuration - no extra setup needed
- Display name can differ from slug (e.g., slug "default", name "Lasso Free")

**Profile File Format:**
```yaml
---
name: Lasso Free        # Display name for UI
slug: default           # URL identifier (matches filename)
type: standard
default_rps_limit: 100
default_burst_limit: 500
---
chains:
  ethereum:
    chain_id: 1
    providers:
      - id: "provider_id"
        url: "https://..."
```

### URL Routing

**Legacy routes (use default profile):**
- `/rpc/:chain_id` - Base endpoint
- `/rpc/fastest/:chain_id` - Fastest provider strategy
- `/rpc/round-robin/:chain_id` - Round-robin strategy
- `/rpc/latency-weighted/:chain_id` - Latency-weighted strategy

**Profile-aware routes:**
- `/rpc/:profile/:chain_id` - Base endpoint with profile
- `/rpc/:profile/fastest/:chain_id` - Strategy with profile
- etc.

---

## Documentation Topics to Cover

### Getting Started
- [ ] Installation
- [ ] Quick start with default profile
- [ ] Adding your first chain/provider

### Configuration
- [ ] Profile configuration format (YAML)
- [ ] Chain configuration options
- [ ] Provider configuration options
- [ ] Environment variable substitution in URLs

### Routing & Strategies
- [ ] Available routing strategies
- [ ] Provider selection algorithms
- [ ] Health monitoring and failover

### Architecture
- [ ] Multi-profile architecture
- [ ] ETS-based configuration store
- [ ] Request pipeline flow

### Deployment
- [ ] Production configuration
- [ ] Docker deployment
- [ ] Fly.io deployment

---

## Migration Tasks

- [ ] Audit `project/` docs for content to migrate
- [ ] Create structured docs in `docs/`
- [ ] Add README with quick start
- [ ] Create CONFIGURATION.md for profile/chain/provider setup
- [ ] Create DEPLOYMENT.md for production deployment
- [ ] Create ARCHITECTURE.md for system overview

---

## Notes

- Profile selector UI shows `name` field, not `slug`
- Backend.File auto-migrates `chains.yml` to `default.yml` if profiles dir is empty
- ProfileResolverPlug is minimal - just looks up profile, returns error if not found
