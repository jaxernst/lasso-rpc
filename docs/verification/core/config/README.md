# Configuration publication

## How to get to it (user POV)

Edit the configured YAML files and reload the addressed node.

## Gotchas

- Each node reads its own files. A reload receipt says nothing about peers.
- A file validation failure leaves the active configuration unchanged; reload
  cannot repair invalid files on disk. A runtime reconciliation failure after
  publication reports a reload error while the new configuration is already active.
- Retirement requires quiesced callers. Completion emits profile, node, operation,
  generation and outcome only after successful reload and confirmed profile absence.

Source baseline: Core `0538eecf8e422635560350ca5a2c1bd531678a30`; retirement
completion is introduced with this map. Inspected source paths: lib/lasso/config/backend/file.ex; lib/lasso/config/config_store.ex; lib/lasso/diagnostics.ex.
