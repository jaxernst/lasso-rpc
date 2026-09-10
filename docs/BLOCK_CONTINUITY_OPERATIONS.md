# Operating block continuity

`global` mode stores the monotonic floor, selected block and admitted instance
boots in PostgreSQL. Serving requests read local ETS grants. PubSub accelerates
updates; background reconciliation recovers missed messages. PostgreSQL is an
optional dependency for this policy, not for ordinary Core routing.

Read the [builder contract](BLOCK_CONTINUITY.md) before enabling it. Global mode
can return an availability error to preserve continuity. It does not choose one
block automatically for unrelated state calls.

## Install the journal

Use one durable PostgreSQL database shared by every serving instance. Use the
same journal throughout the lifetime of each protected file-profile identity.
Start with `head_policy: off` while installing and validating infrastructure.

Provide these environment variables through your deployment's secret store:

```text
LASSO_BLOCK_PUBLICATION_DATABASE_URL=<PostgreSQL connection URL>
LASSO_BLOCK_PUBLICATION_MEMBERS=iad-1,sjc-1
LASSO_NODE_ID=iad-1
```

Each process needs a stable, unique `LASSO_NODE_ID`; the member list names
**every instance accepting protected traffic**, including multiple instances in
one region. All instances use the same initial member list. On the SJC instance,
set `LASSO_NODE_ID=sjc-1`. A replacement process receives a new boot identity.
Unknown or unfenced replacement boots cannot serve protected block choices.

Run migrations once using the new artifact and the database environment:

```sh
# Source checkout
mix lasso.block_publication.migrate

# Built release (also usable with a container exec/one-off command)
bin/lasso eval 'Lasso.BlockPublication.Storage.migrate()'
```

This command opens no RPC ingress. Repeating it applies only pending migrations.
It creates the journal and capacity ledger; ordinary installations need neither
the command nor a PostgreSQL server. The first migration does not import a local
instance's volatile floor. During enrollment, each live instance contributes its
accepted local floor; a previously stopped local-only service has no durable
cross-restart guarantee to recover.

The journal requires acknowledged transactions to survive database failover.
Retain the database, backups and schema along with the service's identity. A
point-in-time restore before an acknowledged floor cannot safely resume that
same contract. Stop protected ingress and reconcile the highest retained floor
before recovery; do not reset rows to fix an availability incident.

## Enable and verify

In the desired profile's YAML chain, configure:

```yaml
chains:
  ethereum:
    chain_id: 1
    block_time_ms: 12000
    head_policy: global
    # Keep this profile's configured providers and other chain settings.
```

Distribute/reload the file on every enrolled instance. First enrollment happens
in the background; a successful config load is not proof that a grant is ready.
Qualify the providers for the actual methods and EIP-1898 hash selectors across
the freshness window plus your maximum query duration. A recent head probe alone
does not prove state availability.

Request `eth_getBlockByNumber` with `["latest", false]` and
`?include_meta=headers` through each instance's real ingress. Check the same
profile/chain, `head_policy.policy=global`, `scope=profile_chain_fleet`, number,
hash and serving instance. Decode the base64url `x-lasso-meta` header. Then run
[the complete logical read](READ_AT_ONE_BLOCK.md) through multiple instances.
Missing metadata means evidence is incomplete, not that a different block was
selected. HTTP batch headers contain only one context.

In a release console:

```elixir
Lasso.BlockPublication.Operator.capacity()
Lasso.BlockPublication.Operator.status()
Lasso.BlockPublication.Gate.read({"public", 1})
```

A fresh grant permits local number/header responses even if a provider later
lags. Advancement waits until every admitted serving boot prepares the same
block and closes its prior grant. A disconnected instance can therefore stall
advancement; the retained block expires after `max(60_000, 4 * block_time_ms)`.
Publication changes can wait up to one second inside the RPC's existing deadline.
Already hash-pinned state reads do not wait for publication.

The initial operating limit is four active profile/chain scopes per journal,
1,024 retained scopes and 32 MiB of reserved state. A rejected enrollment does
not change an existing floor or reservation. These conservative limits bound
background work; they are not a high-throughput or broad-fleet certification.
Each runtime permits at most four provider-probe tasks and four independent
closure-acknowledgment tasks, with at most one closure task per scope. Gates
close locally before those acknowledgment writes start.
Measure your provider costs, publication age and request error rate before
expanding rollout. Do not remove the capacity constraints as a rollout shortcut.

## Changing or disabling the policy

A YAML value cannot override an existing durable grant or reset its floor.
For an enrolled scope, disabling requires both the desired file configuration
and a durable operation:

1. Set `head_policy: off` on every instance and reload. Existing grants still
   govern while the durable policy is active.
2. Run `Lasso.BlockPublication.Operator.disable({"public", 1})` in a release
   console. Wait for the journal's `phase` to become `disabled` and confirm
   each serving gate is `:unmanaged`. Until every admitted boot closes or is
   fenced, protected block choices may return an error.
3. Keep the journal and member configuration. An instance retaining YAML
   `global` fails closed after durable disable until its file is updated.

To reenable, restore the file's `global` value on every instance, then run
`Lasso.BlockPublication.Postgres.configure({"public", 1}, "global", 12_000)`.
This uses the configured roster, updates the age bound, reenables the scope and
retains its floor. `Operator.enable/1` reenables without changing that bound.
Verify each ingress again. Calls made while off were outside the guarantee.

Do not delete or rename a protected file profile before coordinated disable.
A new slug is a new service identity and does not inherit its former floor.
Removing the journal environment after enrollment bypasses its recovery; keep
that configuration even when every current YAML setting is off.

## Replace or remove an instance

A normal application shutdown permanently closes local gates and writes boot
fences before replacement. Check that it completed. If replacing an older
binary without this hook, first call
`Lasso.BlockPublication.Operator.quiesce_local()` on that running instance.
This operation cannot be undone within the same boot.

A crash or unavailable journal may prevent the shutdown fence. Stop the old
process or exclude it from **all** protected ingress before recording:

```elixir
Lasso.BlockPublication.Operator.record_external_fence(
  {"public", 1}, "iad-1", "EXACT_OLD_BOOT", "Evidence that this boot cannot serve"
)
```

Apply it to every retained scope bound to that boot, including disabled history.
A timeout or missed heartbeat is not proof that the old boot stopped serving.
Never automatically fence based only on reachability.

To add an instance, use `Operator.add_member(key, member)` for each relevant
scope before sending it protected traffic. To remove one, quiesce/fence its boot,
then use `Operator.remove_fenced_member(key, member)`. Keep environment rosters
aligned with the durable roster before reenabling or creating scopes. Never
route around an admission error through an unenrolled binary.

## Recovery and rollback checks

Connection loss leaves existing fresh grants usable and prevents unsafe new
publication. Recovery reconciles the retained floor and boots before admitting
replacement processes. Once a grant expires, new block choices fail until fresh
publication resumes. Normal state requests retain their selectors and ordinary
provider retry budgets.

Before release, exercise journal interruption, worker restart, graceful and
unfenced process replacement, disable/re-enable and actual hash-pinned queries.
The repository CI runs PostgreSQL-backed three-BEAM tests and an Anvil/viem/SEL
workflow with an actual branch replacement. It preserves correlated HTTP evidence.
These tests do not certify your database provider's infrastructure failover.

For rollback, coordinate disable and verify it before deploying a binary that
cannot read this journal or honor its gates. Preserve journal tables and rows.
An ordinary routing health check does not prove the continuity policy is active.
