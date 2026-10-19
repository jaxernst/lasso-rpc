# core-config-1

- `core-config-1` A valid YAML profile becomes routable after a successful local reload. **unguarded**.

[Area and shared preconditions](README.md).

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
