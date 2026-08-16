# Lasso RPC

Lasso RPC is the routing engine that chooses upstream channels and governs request attempts,
failover, and transport continuity.

## Language

**Upstream instance**:
A concrete chain endpoint, credential or quota identity, and transport whose runtime health and
routing evidence can be attributed independently.
_Avoid_: Provider account, profile provider

**Admission event**:
A live routing decision that accepts or rejects work before an upstream request is dispatched.
Circuit-open, half-open-busy, local queue, rate-admission, and pre-dispatch deadline rejections are
admission events rather than upstream attempts.
_Avoid_: Failed attempt, zero-latency attempt

**Upstream attempt**:
One request dispatched to one upstream instance after admission. Every upstream attempt has exactly
one terminal outcome, even when failover later recovers the client request.
_Avoid_: Client request, provider selection

**Attempt evidence**:
The terminal, individually attributed observation for an upstream attempt. It identifies the
upstream instance, chain, transport, bounded workload key, monotonic observation time, outcome, and
attempt-local elapsed I/O time or censoring boundary.
_Avoid_: Request duration, provider score

**Usable success**:
A valid response that can satisfy the client request. It contributes both reliability support and
an exact successful-attempt latency observation.
_Avoid_: HTTP completion, failover recovery

**Capacity rejection**:
An upstream rate-limit or quota response. It informs live admission and quota behavior without
counting as intrinsic service unreliability or successful-latency evidence.
_Avoid_: Service failure, admission rejection

**Client outcome**:
The final success or error returned to the caller after zero or more admissions and upstream
attempts. It remains distinct from each attempt outcome and from whether failover recovered an
earlier failure.
_Avoid_: Attempt outcome, provider reliability

**Routing evidence**:
A bounded, node-local summary of attempt evidence used to qualify or rank an upstream instance.
Evidence qualification is separate from live admission, and another profile may reuse evidence
only when it explicitly references the same upstream instance.
_Avoid_: Lifetime average, health score

**Evidence partition**:
One of the fixed workload keys that isolates client attempt evidence from system-probe evidence.
Client evidence is authoritative for adaptive client routing. Fresh system evidence may order an
otherwise unqualified client fallback, but it cannot qualify the route.
_Avoid_: Dynamic method bucket, shared default workload
