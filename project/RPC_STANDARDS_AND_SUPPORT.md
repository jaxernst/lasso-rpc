## RPC Standards, Support Levels, and Roadmap

This document defines Lasso’s JSON‑RPC support surfaces, known limitations, and roadmap. It also proposes a single “source of truth” registry to keep behavior, docs, and tests aligned.

### Scope and philosophy

- **Primary goal**: robust, cost/performance‑aware routing for stateless read methods and subscriptions.
- **Out of scope (for now)**: wallet/signing, stateful filters, transaction writes without strong guarantees (stickiness, queues, dedupe).

## Current capabilities

### HTTP (read-only proxy)

- Strategy-based routing with failover; JSON‑RPC 2.0 normalization.
- Explicitly supported and commonly used (pass‑through):
  - Blocks/txs: `eth_getBlockByNumber`, `eth_getBlockByHash`, `eth_getTransactionByHash`, `eth_getTransactionReceipt`
  - State: `eth_getBalance`, `eth_getTransactionCount`, `eth_getCode`, `eth_getStorageAt`
  - Calls/gas/fees: `eth_call`, `eth_estimateGas`, `eth_gasPrice`, `eth_maxPriorityFeePerGas`, `eth_feeHistory`
  - Chain/network: `eth_chainId` (native), `net_version`, `net_listening`, `web3_clientVersion` (pass‑through)
  - Proofs/block params: `eth_getProof` (EIP‑1186), EIP‑1898 block parameter objects (pass‑through)
- Non‑standard methods (e.g., `debug_*`, `trace_*`, client/chain‑specific like `eth_getBlockReceipts`) are forwarded when the upstream supports them; availability varies.

### WebSocket

- Subscriptions: `eth_subscribe` (`newHeads`, `logs`, `newPendingTransactions`) and `eth_unsubscribe`.
- Known limitation: failover backfill is implemented for `logs` only, not for `newHeads` (may miss blocks on provider failover).
- Reads over WS (e.g., `eth_getBalance`) currently lack failover; prefer HTTP for reads.

### Explicitly blocked over HTTP (enforced)

- Subscriptions: `eth_subscribe`, `eth_unsubscribe` (WS only).
- Signing/wallet/account: `eth_sign`, `eth_signTransaction`, `personal_sign`, `eth_accounts`.
- Transaction writes: `eth_sendTransaction`, `eth_sendRawTransaction`.
- Tx pool state: `txpool_content`, `txpool_inspect`, `txpool_status`.

### Implicitly risky / special handling (policy: block or add stickiness)

- Stateful filters: `eth_newFilter`, `eth_newBlockFilter`, `eth_newPendingTransactionFilter`, `eth_getFilterChanges`, `eth_uninstallFilter` (require sticky routing; prone to inconsistency across providers).
- Additional signing: `eth_signTypedData`, `eth_signTypedData_v3`, `eth_signTypedData_v4`.
- All `wallet_*` and `personal_*` namespaces (wallet UX API; not node RPC).
- Tracing/debug: `trace_*`, `debug_*`, `parity_*`, `erigon_*`, chain‑specific (`arbtrace_*`, `optimism_*`) are expensive and non‑standard.

## Batching semantics (HTTP)

- Order: responses preserve request order.
- Partial failures: each entry returns its own `result` or `error`.
- Limits: default `max_batch_requests = 50` (configurable).
- IDs: Lasso echoes `id` values and types as provided.
- JSON‑RPC version: normalized to `"jsonrpc": "2.0"`.

## Provider override and region pinning

- Provider override: pin a request to a specific `provider_id` (via path/params). If the provider fails and `allow_failover_on_override` is true, Lasso may fail over using the active strategy; otherwise it returns the error.
- Region biasing: send `x-livechain-region: <region>` to prefer or constrain selection/failover to providers in that region (when configured).

## Error model

- JSON‑RPC 2.0 enforced: `{"jsonrpc":"2.0", ...}` with the original `id` when available.
- Common codes:
  - −32600 Invalid Request
  - −32601 Method not found (or blocked in this context)
  - −32602 Invalid params
  - −32603 Internal error (upstream failure surfaced)
  - −32000 Server error (proxy/failover errors with message)
- Blocked-in-context errors include hints (e.g., “Use WebSocket for subscriptions”).

## Method coverage notes

- EIP‑1898: object block params with `hash/number/tag` and `finalized/safe` semantics are passed through; Lasso does not reinterpret.
- `eth_getLogs`: large ranges are subject to upstream caps. Recommendation: page by block range/topics and back off on provider signals. (Pagination/splitting is a roadmap item.)
- Gas and simulation variance: `eth_estimateGas` and `eth_call` can differ across providers. Consider pinning estimates to a single provider or using the “priority” strategy for consistency on latency‑sensitive flows.
- Popular non‑standard reads: `eth_getBlockReceipts` (Erigon/Alchemy) may be available; Lasso forwards when supported upstream.

## Write methods: implications and policy

Enabling writes in a multi‑provider router introduces non‑trivial complexity:

- Nonce/ordering: sticky routing per `(chain, from_address)` and a queued nonce manager to avoid gaps/collisions.
- Idempotency/multi‑broadcast: dedupe by tx hash; only re‑broadcast on confirmed mempool drop to avoid duplicates/bans.
- Lifecycle binding: bind follow‑up reads (`getTransactionByHash`, receipt polling) to the same upstream until mined to avoid “tx not found”.
- Replacement/cancellation: upstream policies differ; must encode a coherent replacement policy.
- Abuse/rate‑limits: writes are sensitive; require per‑source throttling, backoff, and observability.
- Security: `eth_sendTransaction` implies server‑side keys/signing—out of scope for a stateless proxy.

Policy: keep writes blocked until sticky routing, a tx queue, dedupe store, and controlled re‑broadcast are implemented. Wallet/signing methods remain blocked server‑side (client wallets per EIP‑1193).

## Subscriptions: reliability and shortcomings

- Today: failover with backfill is implemented for `logs` only.
- Shortcoming: `newHeads` lacks backfill; provider failover can miss blocks.
- Roadmap: add `newHeads` backfill, deduplication, and continuity guarantees; define sticky bindings and failover policy per subscription type.

## Community standards to track

- EIP‑1474 (Ethereum JSON‑RPC): baseline method set; good reference for coverage/naming.
- EIP‑1193 (Provider API): wallet/dapp JS interface; explains `wallet_*` — blocked server‑side.
- EIP‑1898 (Block param object): safer block targeting; supported via pass‑through.
- EIP‑1186 (`eth_getProof`): proofs for account/storage; pass‑through compatible.
- EIP‑4337 (Account Abstraction): bundler RPCs (`eth_sendUserOperation`, `eth_estimateUserOperationGas`, `eth_getUserOperationReceipt`). Maintain a separate “bundler pool” and policy; do not mix with node pools.
- EIP‑4844 (Proto‑danksharding / blobs): affects fee markets and schemas; standard methods continue to work; blob extras are provider‑specific.

## Recommendations and “source of truth”

### Explicit allow/deny by category

- Categories: stateless reads, stateful filters, subscriptions, signing/wallet, writes, tracing/debug, AA bundler.
- Define for each: allowed protocols (HTTP/WS), failover policy, stickiness, default allow/deny, observability.

### Provider capability registry

- Track provider support for expensive/non‑standard features (tracing, AA, blob extras, `eth_getBlockReceipts`, etc.).
- Use capabilities during selection to avoid routing to incompatible providers and to shape failover sets.

### Failover policy matrix

- Stateless reads: allow failover.
- Subscriptions: allow failover with backfill (`logs` today; `newHeads` roadmap).
- Stateful filters: block or enforce sticky single‑provider routing with no failover.
- Writes: block until write‑path design is complete.

### Performance/cost hints

- Annotate “expensive” methods (e.g., `trace_*`, large `eth_getLogs`) so routing can prefer providers that tolerate them or require explicit opt‑in.

### Proposed MethodRegistry

A central registry (e.g., `lib/livechain/rpc/method_registry.ex`) enumerates methods with metadata:

- `name`, `namespace`, `protocols`, `statefulness`, `allow_default`
- `sticky_required`, `failover_policy`, `idempotent`
- `security` tags (signing, account, wallet)
- `cost_weight`, `capabilities`, `notes`

From the registry:

- Generate controller/router guards (HTTP blocklist, WS‑only).
- Generate documentation (README and this file).
- Validate requests at runtime with precise errors/hints.
- Drive dashboard (“supported/blocked by provider/chain”).
- Power tests (golden tests vs registry).

## Roadmap (high‑impact)

1. Subscriptions: add `newHeads` backfill and policy; formalize WS provider stickiness and failover.
2. Filters: explicitly block by default, or add sticky session routing with timeouts; promote WS subscriptions as the migration path.
3. Write path (if pursued): per‑account stickiness, nonce manager, tx queue, dedupe store, controlled rebroadcast, receipt binding, and strong rate‑limits.
4. Capability registry: static + active probing; selection/failover aware of features.
5. Conformance/docs: OpenRPC/JSON Schema ingestion; auto‑generate README “Supported Methods” from the registry.
6. Logs ergonomics: optional pagination/splitting helper for large `eth_getLogs` ranges.

## Policy summary (what we block and why)

- Block over HTTP: subscriptions, signing/wallet/account, writes, txpool state, stateful filters (unless sticky routing is implemented).
- Allow over HTTP with failover: stateless reads (listed above).
- Allow over WS: `eth_subscribe`/`eth_unsubscribe`; backfill policies vary by subscription type.
- Forward non‑standard methods on a best‑effort basis; do not rely on them for core functionality.

## Alignment with current code

- `@max_batch_requests` (default 50) enforces batch limits.
- Provider override and `x-livechain-region` are supported; `allow_failover_on_override` controls failover after pinning.
- Recommended alignment: expand the HTTP blocklist in `lib/livechain_web/controllers/rpc_controller.ex` to include `eth_signTypedData*`, all `wallet_*`, all `personal_*`, and filter methods (`eth_new*Filter`, `eth_getFilterChanges`, `eth_uninstallFilter`) to match this policy.
