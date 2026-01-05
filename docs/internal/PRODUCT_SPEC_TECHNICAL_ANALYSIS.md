# Lasso RPC Product Specification: Technical Correctness Analysis

**Prepared**: 2025-12-14
**Status**: Critical Issues Identified
**Scope**: Architecture, correctness, security, and edge case analysis

---

## Executive Summary

This analysis identifies **11 critical correctness issues** and **8 architectural risks** in the Lasso RPC product specification. The most severe concerns are:

1. **Race condition in credit system** - allows overdraw in concurrent scenarios
2. **Profile isolation gaps** - hybrid BYOI can access premium providers without payment
3. **WebSocket metering complexity** - no clear model for long-lived subscriptions
4. **API key security weaknesses** - timing attacks and logging exposure
5. **BYOI SSRF attack vector** - unrestricted endpoint configuration

**Recommendation**: Address critical issues (Priority 1-2) before implementation begins. Several decisions require fundamental rework rather than incremental fixes.

---

## Detailed Analysis by Decision

### Decision 1: API Key Validation via ETS Lookup (&lt;0.15ms)

**Decision**: Placed before JSON parsing in plug chain, invalid keys rejected early

#### Critical Issues Identified

**1.1 Timing Attack Vulnerability** (Priority 1)

```elixir
# Current approach (vulnerable):
case :ets.lookup(@api_keys_table, key) do
  [{^key, key_data}] -> {:ok, key_data}  # Fast path
  [] -> {:error, :invalid_key}            # Slightly faster (no data copy)
end
```

**Problem**: Key lookup timing varies based on key validity and data size. Attacker can:
- Distinguish valid from invalid keys by timing
- Extract key prefix information through statistical analysis
- Mount online brute-force with timing side-channel

**Attack scenario**:
```
Valid key:     150μs (ETS lookup + data copy + validation)
Invalid key:   140μs (ETS lookup + early return)
Difference:    10μs detectable over 100 requests
```

**Mitigation**:
```elixir
# Constant-time key validation
def validate_key(provided_key) do
  # Always perform full lookup
  result = :ets.lookup(@api_keys_table, provided_key)

  # Constant-time comparison using crypto primitives
  case result do
    [{^provided_key, key_data}] ->
      # Add artificial delay to match invalid path
      :timer.sleep(0)  # Ensures consistent timing
      {:ok, key_data}
    [] ->
      # Perform dummy crypto operation to match valid path timing
      :crypto.hash(:sha256, provided_key)
      {:error, :invalid_key}
  end
end
```

**Impact**: HIGH - Allows key enumeration attacks

---

**1.2 Key Rotation Strategy Missing** (Priority 2)

**Problem**: Spec mentions "key rotation" in question but provides no mechanism:

- How to rotate compromised keys?
- How to migrate traffic from old to new key?
- What happens to in-flight requests during rotation?

**Scenario**: User's key is leaked in GitHub commit:
1. User generates new key → old key still active
2. Attacker continues using old key → user is billed
3. User must manually disable old key → requires dashboard access
4. Old key disabled → all services using it fail immediately (no grace period)

**Missing features**:
- Key versioning (primary vs backup keys)
- Graceful key deprecation (warning period before disable)
- Key usage audit trail (detect unauthorized use)
- Automatic key expiration (force rotation every N months)

**Mitigation**:
```elixir
# Enhanced key schema
APIKey {
  key_id: string
  secret: string
  profile_id: string
  status: :active | :deprecated | :disabled | :compromised
  expires_at: datetime | nil
  superseded_by: key_id | nil  # For key rotation
  deprecation_started_at: datetime | nil
  created_at: datetime
}

# Deprecation workflow
1. User creates new key (key_v2)
2. Old key marked :deprecated, superseded_by: key_v2
3. 30-day warning period: requests log "key deprecated, migrate to X"
4. After 30 days: old key auto-disabled
```

**Impact**: MEDIUM - Compromised keys cannot be safely rotated

---

**1.3 Cache Invalidation Race Condition** (Priority 2)

**Spec states**: "ETS cache with TTL, invalidate on update"

**Problem**: Cache invalidation is not atomic with database updates:

```elixir
# Race condition:
Process A: UPDATE api_keys SET credits=1000 WHERE id='key1'
Process B: ETS lookup returns cached credits=0
Process A: Invalidate ETS cache for 'key1'
Process C: Request with key1 → ETS miss → DB lookup → fresh data

# Window of inconsistency: B sees stale data between A's DB update and cache invalidation
```

**Attack scenario**:
1. User has 100 credits
2. User purchases 10,000 credits
3. Payment processed → DB updated to 10,100 credits
4. Attacker makes request in 1-2ms window before cache invalidation
5. Request sees cached 100 credits → rejected
6. Legitimate user experiences intermittent failures

**Worse scenario** (credit decrement):
1. User has 100 credits, makes request
2. Request succeeds, DB updated to 99 credits
3. Before cache invalidation, duplicate request (retry) checks cache
4. Cache still shows 100 credits → request allowed
5. Both requests succeed, only 1 credit deducted

**Mitigation**:
```elixir
# Write-through cache with optimistic locking
def decrement_credits(key_id, cost) do
  # Version-based optimistic lock
  current_version = get_credit_version(key_id)

  case Repo.transaction(fn ->
    # Update with version check
    query = from c in CreditBalance,
      where: c.api_key_id == ^key_id and c.version == ^current_version,
      update: [inc: [credits: -cost], inc: [version: 1]]

    case Repo.update_all(query, []) do
      {1, _} ->
        # Update succeeded, invalidate cache
        :ets.delete(@cache_table, {:credits, key_id})
        :ok
      {0, _} ->
        # Version mismatch, retry
        {:error, :version_conflict}
    end
  end) do
    {:ok, :ok} -> :ok
    {:error, reason} -> {:error, reason}
  end
end
```

**Impact**: MEDIUM - Credit theft via race condition, intermittent failures after balance updates

---

### Decision 2: Profile Storage with Composite Keys (~7ns overhead)

**Decision**: Single ETS table with `{:chains, profile_id}` keys, threading profile_id through ~25-35 call sites

#### Critical Issues Identified

**2.1 Profile Memory Leak Risk** (Priority 1)

**Problem**: Spec does not address profile deletion cleanup. Current architecture stores:

```elixir
# ETS storage per profile:
{:chains, profile_id} → %{chain1 => ChainConfig, chain2 => ChainConfig, ...}

# Memory per profile:
- 10 chains × ~50KB config each = 500KB per profile
- 10K BYOI users = 5GB memory (manageable)
- 100K BYOI users = 50GB memory (problematic)
```

**But where else is profile_id referenced?**

Current codebase analysis shows profile_id is NOT yet implemented, but spec calls for threading through:
- Selection module (provider selection per profile)
- RequestPipeline (request tracking per profile)
- ProviderPool state (per-profile health tracking)
- Dashboard subscriptions (PubSub topics per profile)
- Metrics/telemetry (per-profile aggregation)

**Missing cleanup operations**:
1. When profile deleted → remove from ETS
2. When profile deleted → unsubscribe all PubSub topics
3. When profile deleted → clean up ProviderPool state
4. When profile deleted → clear metrics/telemetry
5. When profile deleted → disconnect active WebSocket subscriptions

**Scenario**: User creates BYOI profile, generates traffic for 1 week, cancels subscription:
- Profile deleted from database → ETS entry remains (memory leak)
- PubSub topics still subscribed → events continue processing (CPU waste)
- ProviderPool health tracking continues → background probes run forever
- Metrics accumulate → unbounded growth in telemetry store

**Mitigation**:
```elixir
defmodule ProfileLifecycle do
  @doc "Atomically remove all traces of a profile from the system"
  def delete_profile(profile_id) do
    # 1. Remove from ConfigStore ETS
    ConfigStore.delete_profile(profile_id)

    # 2. Unsubscribe all dashboard topics
    Phoenix.PubSub.unsubscribe_all("routing:decisions:#{profile_id}")
    Phoenix.PubSub.unsubscribe_all("metrics:#{profile_id}")

    # 3. Clean ProviderPool state
    ProviderPool.cleanup_profile(profile_id)

    # 4. Disconnect active WebSocket subscriptions
    StreamCoordinator.terminate_profile_subscriptions(profile_id)

    # 5. Archive and clear metrics (for billing records)
    TelemetryStore.archive_profile_metrics(profile_id)

    # 6. Remove from database (last step)
    Repo.delete_all(from p in Profile, where: p.id == ^profile_id)
  end
end
```

**Impact**: HIGH - Memory leak and resource exhaustion with profile churn

---

**2.2 Hot-Loading Profile Changes** (Priority 2)

**Spec does not address**: What happens when user updates BYOI profile config while requests are in-flight?

**Scenario**:
1. User's profile has providers [A, B, C]
2. 100 requests/sec in-flight using this profile
3. User updates config to remove provider B
4. ConfigStore ETS updated → provider B gone
5. In-flight requests still hold reference to provider B
6. Provider B selection fails → cascade to failover logic

**Race conditions**:
```elixir
# Request thread 1: Start selection
providers = get_providers(profile_id)  # Returns [A, B, C]

# Admin thread: Update config
update_profile(profile_id, new_providers: [A, C])  # B removed

# Request thread 1: Try to use provider B
channel = get_channel(chain, "provider_B", :http)  # Returns {:error, :not_found}
# Failover logic kicks in, but this could be confusing
```

**Additional complexity**: Provider config changes mid-flight:
- Provider URL changes → existing connections become invalid
- Provider priority changes → selection strategy behavior changes
- Provider removed → circuit breaker state orphaned

**Mitigation**:
```elixir
# Copy-on-write profile versioning
defmodule ProfileVersioning do
  # Store profile versions in ETS
  def update_profile(profile_id, new_config) do
    current_version = get_current_version(profile_id)
    next_version = current_version + 1

    # Store new version alongside old
    :ets.insert(@profiles_table, {{profile_id, next_version}, new_config})

    # Update "current version" pointer atomically
    :ets.insert(@profiles_table, {{profile_id, :current}, next_version})

    # Schedule cleanup of old version after grace period (30s)
    Process.send_after(self(), {:cleanup_version, profile_id, current_version}, 30_000)
  end

  # Requests snapshot version at start
  def start_request(profile_id) do
    version = get_current_version(profile_id)
    %RequestContext{profile_id: profile_id, profile_version: version}
  end
end
```

**Impact**: MEDIUM - Config updates cause in-flight request failures

---

**2.3 Threading profile_id Through 25-35 Call Sites** (Priority 3)

**Spec states**: "Requires threading `profile_id` through ~30 call sites, all backward-compatible with optional parameter"

**Problem**: Optional parameters create implicit default behavior that may be incorrect:

```elixir
# Current code (no profile support):
def select_provider(chain, method, opts \\ []) do
  # Uses default config from ConfigStore
end

# After adding profile support:
def select_provider(chain, method, opts \\ []) do
  profile_id = Keyword.get(opts, :profile_id, :default)  # What is :default?
  # ...
end
```

**Issues with optional profile_id**:
1. **Silent failures**: Forgetting to pass profile_id → uses wrong config → incorrect provider selection
2. **Type confusion**: profile_id can be nil, :default, or string → error handling complex
3. **Testing gaps**: Tests without profile_id may pass but production code breaks
4. **Audit trail holes**: Request logging without profile_id → can't trace to user

**Example bug**:
```elixir
# User makes request with BYOI profile (should use their providers)
RequestPipeline.execute(chain, method, profile_id: "user_profile_123")

# Deep in the call stack, developer forgets profile_id:
def failover_to_backup(chain, method) do
  # BUG: No profile_id passed, uses default public providers
  Selection.select_provider(chain, method)  # Should be: ...select_provider(chain, method, profile_id: ctx.profile_id)
end

# Result: BYOI user's traffic fails over to Lasso public providers
# User is charged for Lasso provider usage they didn't configure
```

**Mitigation**:
```elixir
# Enforce profile_id in RequestContext struct
defmodule RequestContext do
  @enforce_keys [:chain, :method, :profile_id]
  defstruct [:chain, :method, :profile_id, ...]

  def new(chain, method, profile_id) when is_binary(profile_id) do
    %__MODULE__{chain: chain, method: method, profile_id: profile_id}
  end
end

# All internal functions require RequestContext
def select_provider(%RequestContext{} = ctx) do
  # profile_id is guaranteed to be present
  get_providers(ctx.profile_id)
end
```

**Static analysis tool**:
```elixir
# Compile-time check: profile_id threading
defmacro require_profile_context do
  quote do
    @spec select_provider(RequestContext.t()) :: {:ok, String.t()} | {:error, term()}
  end
end
```

**Impact**: MEDIUM - Silent bugs from missing profile_id, hard to detect

---

### Decision 3: No User Accounts (API keys as identity)

**Decision**: API keys are bearer tokens, no recovery, no login/password system

#### Critical Issues Identified

**3.1 Key Farming Attack** (Priority 1)

**Spec mentions**: "Per-key rate limiting prevents abuse"

**Problem**: Nothing prevents single actor from generating unlimited free keys:

```
Attacker strategy:
1. Create 100 free API keys (automated signup)
2. Each key gets 250K requests/month at 25 RPS
3. Total capacity: 25M requests/month at 2,500 RPS
4. Cost to attacker: $0
5. Cost to Lasso: Public provider rate limit exhaustion
```

**Why per-key rate limiting fails**:
- Rate limit is per-key, not per-user/IP/payment-method
- No identity linking between keys
- No CAPTCHA or email verification mentioned
- No cost to create keys (no credit card required)

**Real-world attack**:
```bash
# Automated key farming
for i in {1..1000}; do
  curl -X POST https://lasso.rpc/api/keys/generate \
    -H "Content-Type: application/json" \
    -d "{\"email\": \"attacker+$i@temp-mail.org\"}"
done

# Now attacker has 1000 keys = 2.5M RPS capacity
# Rotate through keys to bypass rate limits
```

**Mitigation options**:

**Option A: Proof-of-work key generation**
```elixir
def generate_key(pow_solution) do
  # Require solving a hashcash-like puzzle (30 seconds of compute)
  unless verify_pow(pow_solution, difficulty: 20) do
    {:error, :invalid_pow}
  end
  # Makes key farming expensive in compute time
end
```

**Option B: Progressive rate limiting**
```elixir
# New keys start with lower limits, increase with good behavior
APIKey {
  created_at: datetime
  request_count: integer
  abuse_score: float
  tier: :trial | :trusted | :verified
}

# Trial tier (first 7 days): 10K requests/month, 5 RPS
# Trusted tier (good behavior): 250K requests/month, 25 RPS
# Verified tier (payment method on file): Unlimited
```

**Option C: IP-based rate limiting (global)**
```elixir
# Aggregate rate limiting across all keys from same IP
def check_rate_limit(api_key, client_ip) do
  # Per-key limit: 25 RPS
  key_ok? = check_key_limit(api_key)

  # IP limit: 100 RPS across all keys
  ip_ok? = check_ip_limit(client_ip)

  key_ok? and ip_ok?
end
```

**Impact**: CRITICAL - Free tier abuse, public provider exhaustion

---

**3.2 Billing Dispute Resolution Impossible** (Priority 2)

**Problem**: No user accounts → no dispute resolution mechanism

**Scenario**: User claims "my key was stolen and used by attacker":
1. User: "Someone used my key to rack up 10M requests"
2. Lasso: "We have logs showing your key was used"
3. User: "But it wasn't me, my key was leaked"
4. Lasso: "Keys are bearer tokens, your responsibility"
5. User: "I want a refund"
6. Lasso: **No mechanism to verify user's claim**

**Evidence that's unavailable**:
- No IP address linking (bearer token from anywhere)
- No device fingerprinting (no user login)
- No usage pattern baseline (key could be used from 100 IPs legitimately)
- No notification system (can't alert user of unusual activity)

**Comparison to credit card fraud**:
- Credit cards: Bank can reverse charges, has fraud detection, user can dispute
- API keys: No issuer to reverse charges, no fraud detection, user has no recourse

**Mitigation**:
```elixir
# Minimal identity system WITHOUT full accounts
defmodule KeyOwnership do
  # At key generation, collect minimal identity
  def generate_key(params) do
    # Require one of:
    # 1. GitHub OAuth (proves human identity)
    # 2. Email verification (rate limit by email)
    # 3. Payment method (credit card verification)

    ownership_proof = verify_ownership(params)

    %APIKey{
      ownership_proof: ownership_proof,  # For dispute resolution
      notification_email: params.email,  # For usage alerts
      created_by_ip: client_ip          # For forensics
    }
  end

  # Usage monitoring
  def detect_anomalies(api_key) do
    # Alert user if:
    # - RPS spikes 10x above baseline
    # - Geographic location changes (US → Russia)
    # - Request pattern changes (newHeads → getLogs)
  end
end
```

**Impact**: MEDIUM - No fraud protection, unhappy customers

---

**3.3 Multiple Keys for Same "User"** (Priority 3)

**Problem**: No concept of user → no way to manage multiple keys per person

**Scenario**: Developer has 3 keys:
- Key A: Production frontend
- Key B: Production backend
- Key C: Development environment

**Missing features**:
1. **Unified billing**: Each key is separate subscription → 3x cost
2. **Shared credits**: Can't pool credits across keys
3. **Centralized management**: Must manage 3 keys separately in dashboard
4. **Usage aggregation**: Can't see total usage across all keys
5. **Key organization**: Can't label keys (prod-frontend vs dev)

**User experience problem**:
```
User: "I want to add a new service, should I use my existing key or generate new one?"
Lasso: "Generate new key for isolation"
User: "But then I have to buy credits twice?"
Lasso: "Yes, each key is separate"
User: "That's annoying, other providers have organizations/teams"
```

**Mitigation**:
```elixir
# Lightweight "organization" concept without full accounts
defmodule Organization do
  schema "organizations" do
    field :id, :string
    field :name, :string
    field :shared_credit_pool, :integer
    has_many :api_keys, APIKey
  end
end

# Key generation links to organization
def generate_key(org_id, label) do
  %APIKey{
    organization_id: org_id,
    label: label,  # "prod-frontend"
    # Draws from shared credit pool
    credits_source: {:organization, org_id}
  }
end
```

**Impact**: LOW - Inconvenient for multi-key users, but workable

---

### Decision 4: BYOI Format-Only Validation

**Decision**: Validate YAML syntax, not endpoint connectivity

#### Critical Issues Identified

**4.1 SSRF Attack Vector via BYOI Endpoints** (Priority 1)

**Problem**: Users can configure arbitrary URLs in BYOI profiles:

```yaml
# Attacker's BYOI profile
providers:
  - id: attack
    url: http://169.254.169.254/latest/meta-data/  # AWS metadata service
    ws_url: http://localhost:6379/  # Redis on Lasso server
```

**Attack scenarios**:

**1. Cloud metadata service access**:
```yaml
url: http://169.254.169.254/latest/meta-data/iam/security-credentials/
# Lasso makes request to this URL
# Response contains AWS credentials for Lasso's IAM role
# Attacker extracts credentials from error messages or timing
```

**2. Internal service scanning**:
```yaml
url: http://10.0.0.1:22/  # SSH service
url: http://10.0.0.1:5432/  # PostgreSQL
url: http://10.0.0.1:6379/  # Redis
# Attacker uses Lasso as port scanner to map internal network
```

**3. DDoS amplification**:
```yaml
url: https://victim-site.com/expensive-endpoint
# Attacker configures victim's site as "provider"
# Makes 1000 RPS to Lasso
# Lasso proxies 1000 RPS to victim
# Victim sees Lasso IPs as source, not attacker
```

**4. Bypassing IP allowlists**:
```yaml
url: https://internal-api.company.com/admin
# If internal API trusts Lasso's IP (as legitimate RPC provider)
# Attacker uses Lasso to access restricted endpoints
```

**Current validation is insufficient**:
```elixir
# Spec says: "Validate YAML syntax, not endpoint connectivity"
def validate_config(yaml_string) do
  case YamlElixir.read_from_string(yaml_string) do
    {:ok, _config} -> :ok  # Only checks YAML parses
    {:error, reason} -> {:error, :invalid_yaml}
  end
end
```

**Mitigation**:
```elixir
defmodule BYOIValidator do
  # Blocklist dangerous URL patterns
  @blocked_cidrs [
    # AWS metadata
    "169.254.0.0/16",
    # GCP metadata
    "metadata.google.internal",
    # RFC1918 private networks
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
    # Localhost
    "127.0.0.0/8",
    "localhost",
    # Link-local
    "169.254.0.0/16",
  ]

  def validate_provider_url(url) do
    uri = URI.parse(url)

    # 1. Must use HTTPS (prevent credential sniffing)
    unless uri.scheme == "https" do
      return {:error, :https_required}
    end

    # 2. Resolve hostname to IP
    case resolve_hostname(uri.host) do
      {:ok, ip_addresses} ->
        # 3. Check all resolved IPs against blocklist
        if Enum.any?(ip_addresses, &ip_blocked?/1) do
          {:error, :blocked_ip_range}
        else
          :ok
        end
      {:error, reason} ->
        {:error, {:dns_resolution_failed, reason}}
    end
  end

  defp ip_blocked?(ip) do
    Enum.any?(@blocked_cidrs, fn cidr ->
      ip_in_cidr?(ip, cidr)
    end)
  end
end
```

**Defense-in-depth**:
```elixir
# Network-level controls
# 1. Egress firewall rules on Lasso servers
iptables -A OUTPUT -d 169.254.0.0/16 -j REJECT
iptables -A OUTPUT -d 10.0.0.0/8 -j REJECT

# 2. Request timeout hardening
finch_request(url, timeout: 5_000, max_redirects: 0)

# 3. Response size limits
max_response_size = 10_MB  # Prevent memory exhaustion

# 4. Rate limiting on BYOI endpoint usage
# If endpoint returns errors, temporarily disable it
```

**Impact**: CRITICAL - Complete server-side request forgery, cloud credential theft

---

**4.2 DDoS via Malicious BYOI Endpoints** (Priority 2)

**Problem**: Attacker configures endpoint that responds slowly or with huge payloads:

```yaml
providers:
  - id: slowloris
    url: https://attacker.com/slowloris  # Takes 60s to respond
```

**Attack flow**:
1. Attacker generates free API key
2. Creates BYOI profile with malicious endpoint
3. Makes requests to Lasso using this key
4. Each request ties up Lasso connection pool for 60s
5. With 1000 concurrent connections, Lasso becomes unresponsive

**Resource exhaustion vectors**:
- **Slow reads**: Endpoint sends 1 byte every 10 seconds
- **Large responses**: Endpoint sends 10GB response
- **Infinite redirects**: Endpoint returns 301 → 301 → 301 loop
- **Zip bomb**: Compressed response that expands to 10GB

**Mitigation**:
```elixir
# Strict resource limits for BYOI endpoints
def request_with_limits(url, body, opts) do
  defaults = [
    timeout: 10_000,              # Hard timeout
    max_response_size: 10_MB,     # Body size limit
    max_redirects: 0,             # No redirects
    receive_timeout: 5_000,       # Socket read timeout
    connection_timeout: 3_000,    # Connection establishment timeout
  ]

  # Dedicated connection pool for BYOI (isolate from Lasso providers)
  pool = :byoi_pool

  Finch.request(url, body, Keyword.merge(defaults, opts), pool: pool)
end
```

**Impact**: HIGH - Denial of service via resource exhaustion

---

**4.3 Cost Optimization Bypass** (Priority 3)

**Problem**: BYOI user can configure Lasso premium providers in their profile without paying:

```yaml
# Attacker's "BYOI" profile
providers:
  - id: my_fake_provider
    url: https://eth-mainnet.g.alchemy.com/v2/LASSO_PREMIUM_KEY
    type: "user"  # Claims to be user-owned
```

**Why this works**:
- Spec says: "Format validation only, no connectivity testing"
- No way to distinguish user's Alchemy key from Lasso's Alchemy key
- Metering based on `ownership: :user` flag in config
- User sets `ownership: :user` → no credits charged

**Mitigation requires authentication**:
```elixir
# Option 1: Endpoint verification (contradicts spec decision)
def validate_byoi_provider(provider_config) do
  # Make test request to verify user owns endpoint
  case test_request(provider_config.url) do
    {:ok, _response} -> :ok
    {:error, :unauthorized} -> {:error, :invalid_credentials}
  end
end

# Option 2: Provider catalog with authentication
# Don't allow users to configure raw URLs
# Instead, reference provider from catalog with their own API key
providers:
  - provider_ref: "alchemy"
    api_key: "user's own alchemy key"
    ownership: "user"
```

**Impact**: MEDIUM - Free tier users accessing premium providers

---

### Decision 5: Separate Repositories (AGPL core fork)

**Decision**: `lasso-rpc` (OSS) and `lasso-cloud` (proprietary) in separate repos

#### Issues Identified

**5.1 Divergent Feature Development** (Priority 2)

**Problem**: How to handle features that belong in core but are discovered during cloud development?

**Scenario**:
1. Cloud team builds "provider health scoring" for managed service
2. Feature is generic, would benefit OSS users
3. Should it be contributed back to core?
4. If yes, how to handle proprietary tweaks (ML model weights, tuning)?

**Merge conflicts**:
```
Week 1: Core releases v2.0 with new routing algorithm
Week 2: Cloud merges upstream → conflicts in routing code
Week 3: Cloud adds proprietary A/B testing framework → modifies routing
Week 4: Core releases v2.1 with routing bugfix → Cloud must merge
Week 5: Cloud's proprietary A/B code conflicts with core bugfix
```

**Technical debt accumulation**:
- Cloud falls behind on core versions → security patches delayed
- Cloud reimplements core features differently → duplicate code
- Cloud makes breaking changes → can't merge upstream improvements

**Mitigation**:
```elixir
# Plugin architecture for cloud-specific features
defmodule Lasso.Core.Routing do
  @callback enhance_selection(providers, context) :: providers

  def select_provider(chain, method) do
    providers = get_providers(chain)

    # Allow cloud to inject custom logic via plugin
    providers = apply_plugins(:enhance_selection, [providers, context])

    # Core continues with standard logic
    select_best(providers, method)
  end
end

# In lasso-cloud:
defmodule LassoCloud.SelectionEnhancer do
  @behaviour Lasso.Core.RoutingPlugin

  def enhance_selection(providers, context) do
    # Proprietary ML-based ranking
    ml_score_providers(providers, context)
  end
end
```

**Impact**: MEDIUM - Maintenance burden, slower security patches

---

**5.2 Security Patch Coordination** (Priority 1)

**Problem**: Security vulnerability found in core → must patch both repos

**Timeline vulnerability**:
```
Day 0: Security researcher reports SSRF in core
Day 1: Core team patches lasso-rpc, releases v2.0.1
Day 1: lasso-rpc is public → patch details visible to attackers
Day 2: Cloud team starts merge process
Day 3: Cloud team resolves conflicts
Day 4: Cloud team tests in staging
Day 5: Cloud team deploys to production

Exposure window: 4 days where cloud is vulnerable but patch is public
```

**Mitigation**:
```bash
# Coordinated disclosure process
1. Report received → both teams notified simultaneously
2. Both repos patched in private branches
3. Both patches tested independently
4. Coordinated release on same day:
   - Core: Publish patch to lasso-rpc
   - Cloud: Deploy patched version to production
5. Public disclosure 7 days later (after cloud deployment verified)
```

**Impact**: HIGH - Extended vulnerability window in production

---

### Decision 6: Generous Free Tier (250K/mo, 25 RPS)

**Decision**: Public providers, per-key rate limiting prevents abuse

#### Issues Identified

**6.1 Public Provider Exhaustion** (Priority 2)

**Problem**: Free tier aggregates traffic from all users onto shared public providers

**Math**:
```
Free tier limits: 250K requests/month, 25 RPS per key
Public providers (estimated):
- LlamaRPC: ~500 RPS capacity (shared across all users)
- PublicNode: ~1000 RPS
- DRPC free tier: ~200 RPS

If 100 free users make max RPS simultaneously:
100 users × 25 RPS = 2,500 RPS demand
Public provider capacity: ~1,700 RPS
Shortfall: -800 RPS (47% of requests fail)
```

**Circuit breaker cascade**:
1. LlamaRPC hits rate limit → circuit breaker opens
2. Traffic shifts to PublicNode → overloads
3. PublicNode circuit breaker opens → shifts to DRPC
4. DRPC exhausted → all providers down
5. All free tier users see 100% error rate

**Mitigation**:
```elixir
# Global rate limiting across all free tier keys
defmodule FreeTierGovernor do
  # Aggregate capacity limits
  @max_free_tier_rps 1_000  # Total across all free keys

  def check_request(api_key) do
    # Per-key check (existing)
    with :ok <- RateLimit.check_key(api_key, limit: 25) do
      # Global free tier check (new)
      RateLimit.check_global(:free_tier, limit: @max_free_tier_rps)
    end
  end

  # Prioritize within free tier
  def priority_queue(api_key) do
    # Longer-lived keys get priority
    account_age = get_account_age(api_key)
    priority = min(account_age_days, 30)  # Max 30 priority points

    # Enqueue with priority
    Queue.add(api_key, priority: priority)
  end
end
```

**Impact**: MEDIUM - Free tier unreliable during peak usage

---

**6.2 Cost Sustainability** (Priority 2)

**Problem**: Spec does not model costs or revenue

**Rough cost estimate**:
```
Assumptions:
- 10,000 free tier users
- Average 100K requests/month per user (40% of limit)
- Public providers are free but Lasso pays egress/compute

Costs:
- Egress bandwidth: 1M requests/month × 10KB avg = 10GB/month/user
- 10,000 users × 10GB = 100TB/month egress
- AWS egress: $0.09/GB = $9,000/month
- Compute for routing: 1B requests × $0.0000002 = $200/month
- Total: ~$9,200/month for free tier

Revenue from premium tier:
- Need 920 paying users at $10/month to break even
- Or 92 users at $100/month
- Free → Paid conversion rate: typically 2-5%
- Need 18,400-46,000 free users to get 920 paid users
```

**Free tier is underwater until 20K+ users**

**Mitigation**:
1. **Lower free tier**: 100K requests/month (not 250K)
2. **Throttle, don't block**: Reduce RPS to 5 after hitting soft limit
3. **Usage-based graduation**: Auto-upgrade to paid after 3 months of heavy use
4. **Require credit card**: Even for free tier (prevents abuse, eases conversion)

**Impact**: LOW - Financial planning issue, not technical

---

### Decision 7: Hybrid BYOI with Mixed Provider Ownership

**Decision**: BYOI profiles can include both user-owned and Lasso-managed providers

#### Critical Issues Identified

**7.1 Unexpected Credit Burn** (Priority 1)

**Problem**: User configures BYOI with Lasso premium as failover, doesn't realize cost implications

**User configuration**:
```yaml
providers:
  - id: my_node
    url: https://my-dedicated-node.com
    priority: 1
    ownership: user
  - id: lasso_premium_backup
    url: <lasso premium provider>
    priority: 2
    ownership: lasso
    metering: premium
```

**Failure scenario**:
1. User's node goes down (maintenance window)
2. All traffic fails over to Lasso premium (priority 2)
3. User makes 1M requests/hour during outage
4. Lasso premium costs: 1M requests × $0.0001 = $100/hour
5. User's maintenance window lasts 8 hours = $800 unexpected cost
6. User's credit balance: $50 → exhausted in 30 minutes
7. Remaining 7.5 hours: requests rejected (503 errors)

**User expectation mismatch**:
```
User: "I configured my node as primary, why did I get charged?"
Lasso: "Your node was down, we failed over to premium"
User: "I didn't authorize $800 in charges"
Lasso: "It's in the Terms of Service"
User: *cancels subscription, posts angry tweet*
```

**Mitigation**:
```elixir
# Credit budget enforcement
defmodule CreditBudget do
  schema "credit_budgets" do
    belongs_to :api_key, APIKey
    field :daily_limit, :integer
    field :hourly_limit, :integer
    field :per_request_limit, :integer
  end
end

# Check budget before using Lasso provider
def check_lasso_provider_usage(api_key, provider_id) do
  case provider_ownership(provider_id) do
    :user -> :ok  # No budget check needed
    :lasso ->
      budget = get_budget(api_key)

      with :ok <- check_hourly_budget(budget),
           :ok <- check_daily_budget(budget) do
        :ok
      else
        {:error, :budget_exceeded} ->
          # Fail request instead of burning credits
          {:error, :credit_budget_exceeded}
      end
  end
end

# Dashboard warning
def warn_user_about_failover(profile_id) do
  hybrid? = profile_has_mixed_ownership?(profile_id)

  if hybrid? do
    send_email(user, """
    Warning: Your profile includes Lasso premium providers as failover.
    If your primary providers go down, you will be charged for Lasso usage.

    Estimated cost if all traffic fails over: $X/hour

    To prevent unexpected charges, set a credit budget in Settings.
    """)
  end
end
```

**Impact**: HIGH - Angry users, billing disputes, churn

---

**7.2 Profile Isolation Breach** (Priority 1)

**Problem**: Can BYOI user add Lasso premium providers to their profile?

**Spec states**: "If ownership == :lasso and metering == :premium → decrement credits"

**But who sets the ownership flag?**

**Scenario A: User controls ownership flag**:
```yaml
# User's BYOI profile
providers:
  - id: alchemy_premium
    url: https://eth-mainnet.g.alchemy.com/v2/LASSO_SECRET_KEY
    ownership: user  # User lies, claims it's their endpoint
    metering: none
```
User gets access to Lasso's premium provider without paying.

**Scenario B: Lasso controls ownership flag (via provider catalog)**:
```elixir
# User references provider from catalog
providers:
  - provider_ref: "lasso_premium_alchemy"
    priority: 2

# Lasso Cloud resolves reference:
provider = ProviderCatalog.get("lasso_premium_alchemy")
# %{ownership: :lasso, metering: :premium, url: <lasso key>}
```
User can add Lasso premium providers, but can they?

**Open question from spec**: "Are there Lasso providers they shouldn't be able to add?"

**Answer should be**: YES
- Lasso Public providers: Should be available to BYOI (free tier)
- Lasso Premium providers: Should require payment (NOT in BYOI subscription)

**But hybrid model allows**:
```yaml
BYOI subscription: $20/month
Add lasso_premium_alchemy: pay-per-use
Total cost: $20/month + usage charges
```

**Is this intended?** Spec is ambiguous.

**Mitigation**:
```elixir
# Explicit provider tiers with access control
defmodule ProviderCatalog do
  def list_available_providers(api_key) do
    tier = get_tier(api_key)

    case tier do
      :free ->
        # Only public providers
        list_providers(ownership: :lasso, metering: :public)

      :byoi ->
        # Public providers + user-defined
        list_providers(ownership: [:lasso, :user], metering: [:public, :none])

      :premium ->
        # All providers including premium
        list_providers(ownership: [:lasso, :user], metering: [:public, :premium, :none])
    end
  end
end
```

**Impact**: CRITICAL - Access control bypass, metering evasion

---

### Decision 8: Priority Strategy for Hybrid Routing

**Decision**: Use existing priority strategy (user=1, lasso=2+) instead of cost-aware routing

#### Issues Identified

**8.1 Missed Cost Optimization** (Priority 3)

**Problem**: Priority strategy doesn't consider per-request cost differences

**Scenario**:
```yaml
User's profile:
- my_cheap_node: $0.0001/request, priority: 1
- lasso_premium: $0.001/request, priority: 2

Method: eth_getLogs (expensive, requires archive node)
- my_cheap_node: Doesn't support archive queries → fails
- lasso_premium: Supports archive → succeeds, costs 10x more
```

**Better approach**: Cost-aware routing for expensive methods
```elixir
def select_provider(method, providers) do
  if expensive_method?(method) do
    # Prefer user's archive node for expensive queries
    providers
    |> Enum.filter(&supports_method?(&1, method))
    |> Enum.sort_by(&provider_cost(&1, method))
  else
    # Use priority for cheap queries
    Enum.sort_by(providers, & &1.priority)
  end
end
```

**Impact**: LOW - Missed optimization opportunity, not a correctness issue

---

## Additional Technical Concerns

### Credit System Correctness

**Issue**: Async credit decrement allows overdraw in concurrent scenarios

**Race condition**:
```elixir
# Two requests arrive simultaneously with 1 credit left:

Request A:                          Request B:
check_credits() → 1 available       check_credits() → 1 available
proceed with request                proceed with request
decrement_credits() → 0             decrement_credits() → -1 (overdraw!)
```

**Current spec says**: "Async increment of counters (non-blocking to request path)"

**Problem**: Check and decrement are not atomic

**Mitigation**:
```elixir
# Atomic decrement-and-check using database-level locking
def try_use_credit(api_key_id) do
  # PostgreSQL: UPDATE ... RETURNING for atomic check-and-decrement
  query = """
    UPDATE credit_balances
    SET credits = credits - 1
    WHERE api_key_id = $1 AND credits > 0
    RETURNING credits
  """

  case Repo.query(query, [api_key_id]) do
    {:ok, %{rows: [[remaining]]}} ->
      # Decrement succeeded, had at least 1 credit
      {:ok, remaining}
    {:ok, %{rows: []}} ->
      # No rows updated → credits was already 0
      {:error, :insufficient_credits}
  end
end
```

**Alternative**: Optimistic locking with version field
```elixir
def try_use_credit(api_key_id) do
  # Read current version
  %{credits: credits, version: v} = get_balance(api_key_id)

  if credits > 0 do
    # Attempt update with version check
    query = from b in CreditBalance,
      where: b.api_key_id == ^api_key_id and b.version == ^v,
      update: [set: [credits: ^(credits - 1), version: ^(v + 1)]]

    case Repo.update_all(query) do
      {1, _} -> :ok  # Success
      {0, _} -> try_use_credit(api_key_id)  # Retry on version conflict
    end
  else
    {:error, :insufficient_credits}
  end
end
```

**Impact**: MEDIUM - Users can overdraw credits by ~1-10 credits (race window)

---

### Rate Limiting Accuracy

**Issue**: Sliding window vs fixed window behavior

**Current implementation**: Unknown from spec

**Fixed window problems**:
```
Window: 00:00:00 - 00:00:59
Limit: 25 requests

Burst attack:
00:00:58 → 25 requests (allowed)
00:01:01 → 25 requests (allowed, new window)
Effective rate: 50 requests in 3 seconds = 16.6 RPS average, but violates intent
```

**Sliding window advantages**:
```
Look back 1 second from now:
Current time: 00:01:00
Count requests from 00:00:59 to 00:01:00 → 25 requests
Reject new request (would exceed 25 RPS)
```

**Implementation**:
```elixir
defmodule SlidingWindowRateLimit do
  # Use sorted set in ETS to track request timestamps
  def check_rate_limit(key, limit_rps) do
    now = System.monotonic_time(:millisecond)
    window_start = now - 1_000  # 1 second ago

    # Get requests in sliding window
    recent = :ets.select(@rate_limit_table, [
      {{key, :"$1"}, [{:>, :"$1", window_start}], [:"$1"]}
    ])

    count = length(recent)

    if count < limit_rps do
      # Record this request
      :ets.insert(@rate_limit_table, {{key, now}})
      :ok
    else
      {:error, :rate_limit_exceeded}
    end
  end

  # Periodic cleanup of old timestamps
  def cleanup_old_entries do
    cutoff = System.monotonic_time(:millisecond) - 60_000  # 1 minute ago
    :ets.select_delete(@rate_limit_table, [{{:"$1", :"$2"}, [{:<, :"$2", cutoff}], [true]}])
  end
end
```

**Impact**: LOW - Minor rate limit accuracy issue

---

### WebSocket Handling

**Issue**: Long-lived connections vs per-request metering

**Problem**: eth_subscribe creates long-lived connection that emits events continuously

**Scenario**:
```javascript
// User subscribes to newHeads
ws.send({
  method: "eth_subscribe",
  params: ["newHeads"]
})

// Provider emits event every 12 seconds (Ethereum block time)
// Events per hour: 3600s / 12s = 300 events
// Events per day: 7,200 events
// Events per month: 216,000 events
```

**Metering questions**:
1. **Charge for subscription creation?** (1 request)
2. **Charge per event received?** (216K requests)
3. **Charge for connection time?** ($X/hour connected)
4. **Charge hybrid?** (1 request to subscribe + 1 per 100 events)

**Spec does not specify**

**Comparables**:
- Alchemy: Charges per "compute unit", newHeads = 1 CU per event
- Infura: Charges per request, subscription = 1 request, each event = 0 requests
- QuickNode: Charges per request, subscription = 1 request, events included

**Recommendation**:
```elixir
# Hybrid model: subscription + throttled event charges
defmodule WebSocketMetering do
  def meter_subscription(api_key, method: "eth_subscribe", params: params) do
    # Charge 1 credit for subscription creation
    use_credit(api_key, 1)

    # Track active subscription
    subscription_id = create_subscription(api_key, params)

    # Set event budget (e.g., 1000 events per subscription)
    set_event_budget(subscription_id, 1000)
  end

  def meter_event(subscription_id) do
    # Charge 1 credit per 10 events
    event_count = increment_event_count(subscription_id)

    if rem(event_count, 10) == 0 do
      use_credit(subscription_id.api_key, 1)
    end

    # Enforce event budget
    if event_count > get_event_budget(subscription_id) do
      terminate_subscription(subscription_id, reason: :budget_exceeded)
    end
  end
end
```

**Impact**: MEDIUM - Unclear pricing, potential for surprise bills

---

### Security: API Key Logging

**Issue**: API keys in headers vs query params - logging risks

**Problem**: API keys transmitted in HTTP headers or query strings

**Logging risks**:

**1. Query param logging**:
```bash
# Nginx access log
GET /v1/ethereum?api_key=lasso_sk_abc123 HTTP/1.1
# Key is logged in plain text forever
```

**2. Header logging** (better but not perfect):
```bash
# Nginx access log (usually doesn't log headers by default)
GET /v1/ethereum HTTP/1.1
# Key not in URL, but may be logged in debug mode
```

**3. Error message leakage**:
```elixir
# Developer logs error with full context
Logger.error("Request failed: #{inspect(conn)}")
# conn struct includes headers with API key
```

**4. Third-party monitoring**:
```
Sentry, DataDog, LogRocket capture request headers
API key sent to third-party logging service
Third-party logs are retained for 90 days → extended exposure
```

**Mitigation**:
```elixir
# 1. Use custom header (not query param)
Authorization: Bearer lasso_sk_abc123

# 2. Scrub keys from logs
defmodule ScrubLogger do
  def scrub_sensitive(conn) do
    update_in(conn.req_headers, fn headers ->
      Enum.map(headers, fn
        {"authorization", _} -> {"authorization", "[REDACTED]"}
        other -> other
      end)
    end)
  end
end

# 3. Hash keys in logs
Logger.info("Request from key: #{hash_key_for_logging(api_key)}")
# Logs: "Request from key: a3b5c7..." (first 6 chars of SHA256)

# 4. Separate key validation logs
# Don't log full key, log key_id only
Logger.info("Key #{key_id} validated")  # key_id = "lasso_pk_123"
```

**Impact**: MEDIUM - Key exposure via logs, third-party services

---

## Priority Summary

### Priority 1: Critical (Must Fix Before Launch)

1. **Credit race condition** - Allows overdraw via concurrent requests
2. **Key timing attack** - Enables key enumeration
3. **SSRF via BYOI** - Cloud metadata theft, internal network access
4. **Key farming attack** - Unlimited free tier abuse
5. **Profile isolation breach** - Access control bypass in hybrid model
6. **Unexpected credit burn** - Billing disputes from failover costs
7. **Profile memory leak** - Unbounded memory growth with profile churn
8. **Security patch coordination** - Extended vulnerability window

### Priority 2: Important (Fix During Development)

1. **Key rotation missing** - No mechanism to rotate compromised keys
2. **Cache invalidation race** - Credit/config updates see stale data
3. **Hot-loading profile changes** - In-flight requests broken by config updates
4. **DDoS via BYOI endpoints** - Resource exhaustion attacks
5. **Public provider exhaustion** - Free tier unreliable at scale
6. **Billing disputes impossible** - No fraud protection or dispute mechanism
7. **Divergent feature development** - Fork maintenance burden

### Priority 3: Nice to Have (Improve Over Time)

1. **Threading profile_id complexity** - Silent bugs from missing parameter
2. **Multiple keys per user** - Inconvenient but workable
3. **Cost optimization bypass** - Missed savings opportunity
4. **Rate limiting accuracy** - Minor burst behavior issue

---

## Recommendations

### Architectural Changes Required

**1. Credit System**: Synchronous atomic decrement
```elixir
# Replace async credit tracking with atomic DB operations
UPDATE credit_balances SET credits = credits - 1
WHERE api_key_id = ? AND credits > 0 RETURNING credits
```

**2. Profile Lifecycle**: Explicit cleanup hooks
```elixir
# Add profile deletion cascade
ProfileLifecycle.delete_profile(id) → cleanup ETS, PubSub, ProviderPool, metrics
```

**3. BYOI Validation**: IP allowlist enforcement
```elixir
# Block private IP ranges, metadata services
BYOIValidator.validate_url(url) → check against blocklist
```

**4. Access Control**: Provider catalog with tiers
```elixir
# User can only add providers from their tier
ProviderCatalog.list_available(tier: :byoi) → public + user-defined only
```

### Implementation Sequence

**Phase 0: Security Hardening (Before Public Launch)**
1. Fix timing attack vulnerability
2. Implement BYOI SSRF protection
3. Add key rotation mechanism
4. Atomic credit decrement

**Phase 1: Core Correctness**
1. Profile lifecycle management
2. Cache invalidation strategy
3. Hot-reload config versioning
4. WebSocket metering model

**Phase 2: Abuse Prevention**
1. Key farming mitigation (PoW or progressive limits)
2. Global rate limiting for free tier
3. Credit budget enforcement
4. Profile isolation validation

**Phase 3: Operational Excellence**
1. Security patch coordination process
2. Fork maintenance strategy
3. Billing dispute workflow
4. Cost monitoring and alerts

---

## Open Questions for Product Team

1. **WebSocket metering**: Per-subscription, per-event, or hybrid? What's the pricing model?
2. **BYOI premium mixing**: Should BYOI users be able to add Lasso premium providers? If yes, how is this priced?
3. **Free tier economics**: Is $9K/month free tier sustainable? When does it break even?
4. **Key farming**: What's the acceptable cost to generate a key? (CAPTCHA, PoW, email verification?)
5. **Billing disputes**: How to handle "my key was stolen" claims without user accounts?
6. **Profile deletion**: How long to retain profile data after cancellation? (GDPR compliance)
7. **Security patches**: Who coordinates releases between core and cloud repos?

---

## Conclusion

The Lasso RPC product specification is ambitious and well-structured, but contains **multiple critical correctness issues** that must be addressed before implementation. The most severe risks are:

- **Credit system race condition**: Allows financial loss via overdraw
- **SSRF attack vector**: Enables cloud credential theft
- **Key farming attack**: Makes free tier economically unsustainable
- **Profile isolation gaps**: Allows unauthorized access to premium providers

These issues are **not minor edge cases** - they represent fundamental architectural gaps that will cause production incidents, financial losses, and security breaches if deployed as specified.

**Recommendation**: Pause implementation until Priority 1 issues are resolved in the specification. The fixes require architectural decisions (not just implementation details) and should be documented before code is written.
