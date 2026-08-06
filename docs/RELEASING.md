# Releasing Lasso RPC

This checklist is for maintainers preparing a public release. It intentionally separates release preparation from publishing a tag, so version selection and publication stay explicit decisions.

## Prepare the release candidate

1. Start from a clean checkout of the intended commit and review `git status`.
2. Review every entry in `CHANGELOG.md` under `Unreleased`. Move it into a new versioned section only after choosing the release version and date.
3. Update `version` in `mix.exs`, the README version badge, and the comparison links at the end of `CHANGELOG.md` together.
4. Confirm the public surface: README quick start, `docs/API_REFERENCE.md`, `docs/CONFIGURATION.md`, `docs/DEPLOYMENT.md`, and `SECURITY.md` accurately describe the current release.
5. Verify that no credentials, `.env` files, local database files, or machine metadata are staged.

## Verify

Run these from the repository root:

```bash
mix deps.get
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix test --include integration
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
docker build --pull --no-cache --tag lasso-rpc:rc .
```

Then boot the release or container with `SECRET_KEY_BASE`, `LASSO_NODE_ID`, `PHX_HOST`, and `PHX_SERVER=true` configured. Confirm:

- `GET /api/health` returns `200`.
- `GET /api/chains` lists the expected public chains.
- An HTTP request to `/rpc/ethereum` succeeds.
- The dashboard loads at `/dashboard` and the profile selector works.
- An invalid profile and invalid provider override return clear client errors.

## Publish

1. Commit the release-version and changelog changes.
2. Create and push an annotated tag: `git tag -a vX.Y.Z -m "Lasso RPC vX.Y.Z"`.
3. Create the GitHub release from that tag using the finalized changelog section as release notes.
4. Announce the release with its compatibility notes, Docker image/reference if published, and the security boundary: Lasso OSS has no built-in client authentication.

## Post-release

1. Verify the published source archive and release/container boot from a clean environment.
2. Watch health, provider failures, and dashboard errors during the launch window.
3. Open a new `Unreleased` section and record any follow-ups discovered during the release.
