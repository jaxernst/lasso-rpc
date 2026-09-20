# Test Guide

The test suites use ExUnit tags to separate local fixtures from tests requiring
additional services or live providers. Run commands from the repository root.
The executable source of CI requirements is [.github/workflows/ci.yml](../.github/workflows/ci.yml).

## Default suite

Install Elixir 1.18.4, Erlang/OTP 28, and Node.js 22 (the CI versions), then:

```bash
mix deps.get
mix test
```

This excludes `:skip`, `:integration`, `:real_providers`, `:slow`,
`:publication_db`, and `:anvil`. It needs no provider credentials, PostgreSQL,
or Anvil. Tests start a local Phoenix listener on port 4002; do not run two
suites concurrently on that port. Dashboard JavaScript contract tests run through
ExUnit, so Node.js must be on `PATH`.

## Mock-provider integration suite

```bash
mix test --include integration
```

This includes the default tests and integration tests backed by local mock
providers. It still excludes publication-database and Anvil tests. To run only
the integration-tagged tests:

```bash
mix test --only integration
```

## Full CI integration suite

The CI integration job also verifies durable publication recovery and an
Ethereum logical-read fixture. It requires:

- PostgreSQL 16, with a disposable `lasso_publication_test` database.
- Anvil v1.4.4 (Foundry), available as `anvil` on `PATH`.
- Node.js 22 and npm for the committed logical-read fixture lockfile.

If you do not already have a disposable PostgreSQL instance, start one with
Docker using a free local port (55432 here):

```bash
docker run --detach --name lasso-publication-test \
  --publish 127.0.0.1:55432:5432 \
  --env POSTGRES_USER=postgres \
  --env POSTGRES_PASSWORD=postgres \
  --env POSTGRES_DB=lasso_publication_test \
  postgres:16

docker exec lasso-publication-test pg_isready -U postgres
```

Wait until `pg_isready` reports that it is accepting connections. Use only a
disposable database: the publication tests create and clear their fixture data.
Set the URL to your local instance, then reproduce the CI commands:

```bash
export LASSO_TEST_PUBLICATION_DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:55432/lasso_publication_test
export LASSO_QUERY_EVIDENCE_PATH=logical-read-evidence.json

mix deps.get
anvil --version
node --test examples/published-block-query.test.mjs
npm ci --prefix examples/logical-read --ignore-scripts --no-audit --no-fund
npm test --prefix examples/logical-read
mix test --include integration --include publication_db --include anvil
node examples/logical-read/verify-evidence.mjs logical-read-evidence.json
```

The test harness starts its own Anvil processes. CI preserves
`logical-read-evidence.json` as an artifact; keep this file when investigating
fixture failures. No paid provider credentials are required. To remove the
PostgreSQL container created above after testing:

```bash
docker rm --force lasso-publication-test
```

## Live provider and slow tests

```bash
mix test --include integration --include real_providers --include slow
```

These opt-in tests can make real network requests. Check the specific test's
configuration and credentials before running it. This command does not enable
`:publication_db` or `:anvil`.

## Tags

| Tag | Purpose | Default |
| --- | --- | --- |
| No tag | Unit and local fixture tests | Included |
| `:integration` | Multiple components with local mock providers | Excluded |
| `:publication_db` | PostgreSQL publication recovery | Excluded |
| `:anvil` | Local Ethereum execution fixture | Excluded |
| `:real_providers` | Live upstream RPC requests | Excluded |
| `:slow` | Expensive tests, which may also carry other tags | Excluded |
| `:skip` | Explicitly disabled tests | Excluded |

Use `@moduletag :integration` for a module or `@tag :integration` for one test.
Some tests carry multiple tags; enabling `:integration` alone does not enable
an excluded service-specific tag.

## Other CI checks

CI separately runs compilation with warnings as errors, formatting, Credo,
Dialyzer, dependency auditing, container publication guard tests, and Docker
build/boot checks. The main local commands are:

```bash
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix dialyzer
mix hex.audit
python3 -m unittest discover -s scripts/distribution -p 'test_*.py'
```

See the workflow for the complete container health-check invocation. Passing
`mix test` alone does not establish that the full CI workflow passed.
