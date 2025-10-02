### Aligning with README goals

- **Core promise**: “Intelligent proxy” that routes across many providers/chains using per-method performance, with graceful failover, circuit breakers, and a live dashboard.
- **Strategies**: fastest, cheapest, priority, round-robin.
- **Scope expansion**: Extend all of the above to be transport-agnostic so unary JSON-RPC calls can route across both HTTP and WebSocket upstreams, while keeping subscription semantics intact and reliable.

### North-star outcome

- A single request pipeline that can route any read-only JSON-RPC request to the best upstream path among HTTP and WebSocket channels, based on per-method latency/health/cost, with the same failover semantics you have for HTTP today.
- Subscriptions continue to be end-to-end WS, but are managed by the same health/circuit/metrics system, with live re-subscribe failover.
- Configuration and metrics unify transport into the routing decision; providers are described once with both HTTP and WS capabilities.

---

## Architecture overview

### Key ideas

- **Transport-agnostic pipeline**: One pipeline for unary requests and another for long-lived streams, both consuming a common provider selection/circuit/metrics stack.
- **Unified provider model**: Each provider exposes zero or more channels: `http` and/or `ws`, each with declared/discovered capabilities (supports unary, supports subscriptions, supported methods).
- **Method-aware capability matrix**: We learn and cache which methods each provider supports over each transport, fallback if not supported, and benchmark separately by method+transport.
- **Per-transport circuits and metrics**: Circuit breaker and latency histograms are keyed by `provider_id + transport + method`.

### Proposed modules and responsibilities

- `Lasso.RPC.Provider` (struct)
  - `id`, `chain_id`, `http_url?`, `ws_url?`, `cost_tier`, `priority`, `tags`.
  - `capabilities`: per-transport support (unary?, subscriptions?, supported_methods: set|wildcard|discover).
- `Lasso.RPC.Transport` (behaviour)
  - Implementations: `Transport.HTTP`, `Transport.WebSocket`.
  - Presents a single interface to the pipeline for unary and streaming operations.
- `Lasso.RPC.Channel` (runtime)
  - A realized connection or pool (HTTP pool or WS connection/pool).
  - Lifecycle: open, healthy?, request, subscribe, close.
- `Lasso.RPC.RequestPipeline` (unary)
  - Entry point for all single-shot JSON-RPC calls (from HTTP or inbound WS).
  - Selects channel via `Selection`, performs hedging/timeouts, records metrics, handles failover and circuits.
- `Lasso.RPC.StreamCoordinator` (streaming)
  - Manages inbound WS sessions, subscription lifecycles, upstream selection, and re-subscribe failover.
- `Lasso.RPC.Selection` (strategy engine)
  - Input: chain, method, provider registry, metrics, circuits, strategy (:fastest, :cheapest, etc.).
  - Output: an ordered set of candidate channels (may mix HTTP and WS).
- `Lasso.RPC.CircuitBreaker`
  - Circuit keyed at least by `provider_id + transport`, optionally with method-aware sub-state for fast opens on method-specific failures.
- `Lasso.RPC.Metrics`
  - Per-method latency histograms, success/error counts, timeout/hedge counts, tagged by provider/transport.
- `Lasso.RPC.BenchmarkProber`
  - Background probes for top-N methods to keep the performance matrix fresh across transports.

---

## Core interfaces (concise)

```elixir
defmodule Lasso.RPC.Transport do
  @type channel :: term()
  @type rpc_request :: map()
  @type rpc_response :: map()
  @type subscription_ref :: term()

  @callback open(%Provider{}, keyword()) :: {:ok, channel} | {:error, term()}
  @callback healthy?(channel) :: boolean()
  @callback capabilities(channel) :: %{
    unary?: boolean(),
    subscriptions?: boolean(),
    methods: :all | MapSet.t(String.t())
  }

  # Unary JSON-RPC
  @callback request(channel, rpc_request, timeout()) ::
              {:ok, rpc_response} | {:error, :unsupported_method | :timeout | term()}

  # Streaming (WS only)
  @callback subscribe(channel, rpc_request, pid()) ::
              {:ok, subscription_ref} | {:error, :unsupported_method | term()}
  @callback unsubscribe(channel, subscription_ref) :: :ok | {:error, term()}
  @callback close(channel) :: :ok
end
```

Notes:

- `Transport.WebSocket` must support unary `request/3` using JSON-RPC over WS with correlation ids.
- If a WS provider doesn’t support a method, it returns `{:error, :unsupported_method}` so the pipeline can immediately fall back.

---

## Request flows

### Unary from inbound HTTP

1. `RequestPipeline.handle/1` receives JSON-RPC request.
2. `Selection.pick_candidates(chain, method, strategy)` returns ordered channels (both transports).
3. Pipeline attempts: try first candidate, on failure or timeout, failover to next.
4. Record latency and health by `provider+transport+method`. Update circuits on failures.

### Unary from inbound WebSocket

- Same as above; only inbound framing differs. You still call the same `RequestPipeline`.

### Subscriptions from inbound WebSocket

1. `StreamCoordinator.start_subscription/3` calls `Selection` (WS-only channels with `subscriptions?`).
2. Establish upstream WS subscription; map upstream sub ids to client sub ids.
3. On upstream failure or circuit open:
   - Pick next candidate; re-subscribe; optionally deliver “gap fill” if supported.
4. Heartbeats, backoff, replay semantics owned here; metrics tagged by provider+transport (WS).

---

## Provider model and config updates

### chains.yml

- Add capability hints; discovery fills gaps at runtime.

```yaml
providers:
  - id: "alchemy_eth"
    url: "https://..."
    ws_url: "wss://..."
    type: "premium"
    capabilities:
      http:
        unary: true
      ws:
        unary: true # supports JSON-RPC unary over WS
        subscriptions: true
        methods: ["eth_blockNumber", "eth_chainId"] # optional whitelist or "all"
```

- If `methods` omitted: start permissive + discovery; cache negatives per method to avoid repeated 32601s.

### Provider runtime

- `ProviderRegistry` holds live `Channel`s:
  - HTTP: connection pool keyed by provider.
  - WS: one or small pool of persistent connections (configurable concurrency per provider).

---

## Selection and strategy updates

- Treat transport as another feature of a channel; selection returns mixed candidates ordered by:
  - Strategy:
    - Fastest: use per-method, per-transport P95/EMA latencies; prefer closed circuits.
    - Cheapest: filter by `type: public` or cost tier; use latency only to break ties.
    - Priority: static order, with circuit/health gating.
    - Round-robin: across eligible channels.
  - Health gating: exclude open circuits; down-rank half-open.
  - Capability gating: must support `unary?` for method; for subs, `subscriptions?`.

---

## Circuit breaker model

- Maintain state at `provider_id + transport` level:
  - Track failures/timeouts across methods; optionally keep a per-method recent failure set to short-circuit unsupported methods quickly.
- Half-open probes sent by `BenchmarkProber` or the next real request, per configuration.

---

## Metrics and benchmarking

- Tag dimensions: `chain`, `provider_id`, `transport`, `method`, `strategy`, `status`.
- Latency: record end-to-end (including queue/pool) and upstream-only; use histogram or EMA per method+transport.
- `BenchmarkProber`:
  - Periodically issues lightweight probes for a curated method set (e.g., `eth_blockNumber`, `eth_chainId`, `net_version`, small `eth_call`).
  - Uses both HTTP and WS channels to keep comparisons fresh.

---

## Failure and retry semantics (unary)

- On `:unsupported_method`, immediately try next candidate (no penalty).
- On timeout or failover to next candidate until budget exhausted.
- On error codes (provider-specific parsing): convert to retryable vs terminal. Terminal errors (e.g., invalid params) return immediately.

---

## Subscription failover semantics

- On upstream disconnect or repeated delivery failures:
  - Re-pick best WS channel; re-subscribe; translate new upstream subscription id; continue delivery.
  - Optionally use `GapFiller` (already present) to pull intermediate heads/logs if you have block numbers to bridge.

---

## Concurrency and pools

- HTTP: reuse current pool strategy.
- WS:
  - Default one persistent connection per provider per chain; configurable pool size for high concurrency.
  - Backpressure: cap in-flight JSON-RPC requests per WS connection to avoid HOL blocking; queue locally and/or shard over pool.
  - Ping/Pong, reconnect, jittered backoff.

---

## Backwards compatibility

- Existing endpoints remain:
  - `/rpc/:chain` and strategy-specific endpoints.
  - Inbound WS endpoint unchanged.
- Behavior change is purely smarter routing; users gain speed without config changes.

---

## Implementation plan (phased)

### Phase 1 — Foundations (completed)

- Implement `Transport` behaviour; adapt `Transport.HTTP` and `Transport.WebSocket` to provide `request/3` and `capabilities/1`.
- Introduce `ProviderRegistry` and `Channel` lifecycle (HTTP pool, WS connection).
- Teach `RequestPipeline` to accept mixed channels and to handle unsupported-method fallthrough.
- Extend `Selection` to consider transport and capabilities.
- Update metrics keys and circuit breaker to include transport.

Success criteria:

- `eth_blockNumber` over inbound HTTP can route to WS upstream when faster; retries/failover work; metrics split by transport.

### Phase 2 — Benchmarking and hedging

- Build `BenchmarkProber` for mixed transports.
- Add optional hedged requests for select methods; config-gated.
- Dashboard updates for transport dimension.

Success criteria:

- “Fastest” strategy reliably picks the faster transport; hedging reduces tail latency without cost explosions.

### Phase 3 — Subscriptions parity

- Migrate `StreamCoordinator` to use the new `Selection`, circuits, and metrics.
- Implement automatic re-subscribe failover; validate with chaos testing.

Success criteria:

- Live WS subscriptions survive provider restarts/outages; metrics reflect failovers.

### Phase 4 — Capability discovery and persistence

- Negative caching of 32601/unsupported per provider+transport+method.
- Optional persist to disk to avoid re-learning on boot.

Success criteria:

- No repeated unsupported-method attempts; selection respects learned capabilities.

### Phase 5 — Hardening

- HOL blocking mitigation for WS channels (fair queuing/sharding).
- Rate limit awareness per provider (avoid bursting on hedges).
- Comprehensive tests and soak runs.

---

## Testing strategy

- Unit tests: `Transport` adapters, selection logic, circuit transitions, capability resolution.
- Integration tests: Mixed providers (one WS-only, one HTTP-only, one dual) and method routing/hedging.
- Fault injection: timeouts, disconnects, 32601, 5xx, partial responses.
- Soak tests: sustained mixed load, monitor tail latencies and failovers.
- Mox-backed fakes for both transports.

---

## Risks and mitigations

- **WS HOL blocking**: Use request concurrency limits and/or multiple WS connections.
- **Provider variance in WS support**: Capability matrix + discovery + fast fallthrough.
- **Metric skew due to hedging**: Attribute “winner-only” latency; track hedge rate separately.
- **Circuit granularity**: Too granular explodes state; too coarse hides issues. Start provider+transport, add method hints for unsupported.

---

## Minimal API and config changes

- `chains.yml` gains optional capability hints; defaults remain sensible.
- New runtime config:
  - `:rpc => hedging: [enabled: false, methods: [...], timeout_ms: ...]`
  - `:ws => pool_size, in_flight_limit, ping_interval_ms`

### Lightweight Elixir sketches (for alignment)

```elixir
# Selection returns ordered channel candidates for a method
candidates = Selection.pick_candidates(chain: "ethereum", method: "eth_blockNumber", strategy: :fastest)
RequestPipeline.request(candidates, request, opts)
```

```elixir
# Transport.WebSocket.request wraps JSON-RPC over WS with id correlation
@impl true
def request(ws_channel, req, timeout_ms) do
  case Capability.supports?(ws_channel, req.method) do
    false -> {:error, :unsupported_method}
    true  -> WsClient.request(ws_channel, req, timeout_ms)
  end
end
```

---

### What to keep from the current codebase

- Reuse `RequestPipeline` as the unary orchestrator.
- Enhance `StreamCoordinator` for subscription failover.
- Keep `Metrics` and `BenchmarkStore`, extend with `transport` label.
- Adapt `ws_connection.ex` into the `Transport.WebSocket` channel implementation with a small pool option.
- Keep current strategies; only change candidate enumeration.

---

## Execution notes

- Build first against a small “golden methods” set to prove routing (chainId, blockNumber, gasPrice).
- Gate hedging behind config; prove P95/P99 wins before defaulting on.
- Keep the external API unchanged; make it “quietly better.”

---

- Built a transport-agnostic architecture plan that unifies HTTP and WS into a single selection/circuit/metrics system, with concrete modules, interfaces, flows, and a 5-phase implementation path.
- Key impacts: faster “fastest” strategy via WS routing when beneficial, robust failover for both unary and subscriptions, and richer dashboard metrics split by transport.
