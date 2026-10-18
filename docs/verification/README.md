# Verification map

See [Core verification](core/README.md) for the baseline, entries, runner and proof rules.

Each area has a `core/<area>/README.md` for shared context and preconditions.
Each promise lives in `core/<area>/<feature-id>.md` with its statement, guard
status, driving recipe and oracle. The filename must match its declared ID.
Changes update the individual promise files and leave shared area READMEs alone.
