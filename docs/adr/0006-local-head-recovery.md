# Local monotonic choices with asynchronous recovery hints

Status: candidate for staging comparison. This supplements the existing global
publication policy; it does not weaken or remove that policy's contract.

## Contract

The `local` policy captures the profile/chain floor when a protected block choice
initializes. Its successful height must meet that captured floor. Acceptance
atomically raises the aggregate maximum. Therefore, if A completes before B
begins on the same application generation, B cannot successfully return below A.
Overlapping requests may finish out of height order without retrying solely
because another overlapping request raised the aggregate maximum.

A per-scope epoch changes when global enrollment fences local admission. An old
local snapshot cannot become usable again after the global policy is disabled.
Disabling or canceling enrollment restores the greater of the remembered and
published heights, retaining the remembered hash at equal height.
Same-height hash conflicts against the captured floor or the current equal-height
floor remain errors. Height ordering does not prove ancestry, canonicality or
state availability. Explicit selectors and one-hash logical reads retain their
existing behavior.

## Recovery and selection

`HeadRecovery` reads at most 64 raw floor rows and 64 raw hint rows per 100 ms
scan. It coalesces accepted heights and broadcasts changed hints through PubSub.
Unchanged hints are eligible for retransmission after two seconds. A startup
repair request clears peers' send caches at most once per two seconds without
restarting their in-progress scans. Traversals tolerate stale continuations.
Full-scan and delivery time determine recovery lag; the tick is not a per-key
delivery deadline.

The application owns the hint table, so worker restart retains it. Peers
retransmit learned maxima as well as their own accepted heights; a survivor can
therefore restore knowledge from a failed source. Messages accept only bounded
batches for currently configured `local` scopes. Same-height conflicting hashes
produce a hint with an unknown hash until a higher height arrives.

RPCs only read local ETS. A recovered height above the captured local floor
prefers providers with fresh observations at or above that height. Static and
ranked candidate groups are stably partitioned, including lazily resolved
groups. Core currently retains one observation per upstream instance; preference
requires that stored observation to match the candidate transport. Missing or
overwritten transport evidence leaves normal fallback ordering available. Existing health/rate-limit tiers, capability checks and explicit provider
overrides retain precedence. A cached fastest winner is reused only when its
observation meets the recovered target. Preference does not move a later deferred
group ahead of an earlier group and does not apply to arbitrary custom strategy
lists; these are best-effort limitations rather than extra selection machinery.

Requests still ask for `latest`. A remote hint never raises the mandatory local
minimum, excludes fallback providers, or causes an otherwise locally valid
response to be discarded. A known lower fallback can succeed; opt-in response
metadata records the recovered height and the returned height's gap below it.
Qualified provider references remain evidence and are no longer an additional
mandatory minimum for local monotonicity.

## Failure and production boundary

Cold instances serve without a new peer-recovery gate. Missing hints are explicit
as null recovery metadata. Worker restarts preserve the application tables;
application/VM replacement loses them and starts a new generation. Lost messages,
partitions or total in-memory loss can cause cross-instance regressions of
unbounded depth. This candidate adds no database checkpoint, per-advance peer
acknowledgment, lease or consensus protocol.

Cloud still reconciles existing durable global enrollment during cold bootstrap.
This candidate removes database work from local-policy advancement; it does not
remove Cloud's configuration/database or global-compatibility bootstrap dependency.

The protected block choice methods remain `eth_blockNumber []` and
`eth_getBlockByNumber ["latest", boolean]`. State reads with implicit `latest`
are not a shared logical query. Existing 60-second minimum header-age ceilings
remain in place for controlled comparison; their fast-chain product adequacy
must be assessed separately from typical measured freshness.

## Qualification

Compare policy-off routing, this local candidate and strict global publication
using BNB Chain, Base, Polygon and Ethereum, plus a 250 ms fixture. Record
sequential numerical regressions separately from overlapping completions and
hash changes. Measure source/provider switches, hint gaps, latency, retries,
availability, freshness and complete pinned queries. Inject missed replication,
worker restart, source loss and replacement under load. Keep raw-policy baseline,
forced handoffs and injected faults as separate populations. Staging results
must identify their source and topology before they inform production readiness.
