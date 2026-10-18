# Configuration publication

## Sub-features

- `core-config-1` A valid YAML profile becomes routable after a successful local reload. **unguarded**.
- `core-config-2` An invalid YAML reload fails while the last valid configuration keeps serving. **unguarded**.
- `core-config-3` Removing a profile and successfully reloading retires its local runtime while preserving instances referenced by other profiles. **unguarded**.

## How to get to it (user POV)

Edit the configured YAML files and reload the addressed node.

## Driving it with the harness

Set `$PROFILES` to the addressed node's configured profiles directory and
`$RELEASE` to its release root. Install a complete `$PROFILE.yml` with matching
slug and distinct fixture response. For 1, reload and require that response.
For 2, replace it with an invalid field type, require reload failure and require
the previous response. Restore the valid file before continuing. For 3, maintain
a second profile referencing the same upstream, remove the first file, reload,
and require the removed route to fail while the second still serves.

For each numbered journey, record the edit and reload result, then send the
read and assert the specific result described above:

```bash
"$RELEASE/bin/lasso" reload
curl -sS -i -H 'content-type: application/json' --data @read.json "$RPC/priority/$CHAIN"
```

## Gotchas

- Each node reads its own files. A reload receipt says nothing about peers.
- A file validation failure leaves the active configuration unchanged; reload
  cannot repair invalid files on disk. A runtime reconciliation failure after
  publication reports a reload error while the new configuration is already active.
- Retirement requires quiesced callers. Completion emits profile, node, operation,
  generation and outcome only after successful reload and confirmed profile absence.

Source baseline: Core `0538eecf8e422635560350ca5a2c1bd531678a30`; retirement
completion is introduced with this map. Inspected source paths: lib/lasso/config/backend/file.ex; lib/lasso/config/config_store.ex; lib/lasso/diagnostics.ex.
