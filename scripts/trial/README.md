# Routing trial kit

Runs a wallet-like JSON-RPC workload against mock upstreams whose faults you control, through Lasso and through baselines, and reports success, latency, freshness and upstream calls for each. Every candidate in a scenario runs at the same time with its own mock upstreams and ports, so upstream logs never mix. One command reruns the set and reports how much repeats disagree.

## Requirements

- Node.js 20 or later. No npm packages.
- bash or any POSIX sh, for `run.sh`.
- macOS or Linux. Resource sampling uses `ps`.
- A Lasso release directory (the one holding `bin/lasso`), in `LASSO_REL`. Either unpack a standalone archive from a [GitHub release](https://github.com/jaxernst/lasso-rpc/releases), which needs no Erlang install, or build one from source with `MIX_ENV=prod mix release` (`_build/prod/rel/lasso`).

## Run

```sh
gh release download v0.9.0 --repo jaxernst/lasso-rpc --pattern 'lasso-*-macos-aarch64.tar.gz'
tar -xzf lasso-*-macos-aarch64.tar.gz
export LASSO_REL="$PWD/lasso"
scripts/trial/run.sh
```

This runs the default set (S1, S2, S2m, S3, S4, S5, S6, S9b, S9s, S9m) three times at 180 s per scenario, about 90 minutes, then writes `tables.md` and `results.json` into `scripts/trial/results/<UTC time>/`.

`run.sh` takes a set name or a comma-separated list of scenarios:

| set | scenarios |
|---|---|
| `default` | S1, S2, S2m, S3, S4, S5, S6, S9b, S9s, S9m |
| `backfill` | B1 |
| `midrun` | S4m, S4r, S4n, S11 |
| `idle` | S8, S10 (Lasso candidates only) |
| `all` | every scenario |

```sh
REPEATS=1 DURATION=60 CANDIDATES=direct,lasso,lasso-fastest scripts/trial/run.sh S2,S4,B1
```

To run one scenario by hand: `node scripts/trial/runner.mjs <scenario> [candidates] [duration_s]`, then `node scripts/trial/analyze.mjs [results dir]`.

## Candidates

| name | what runs |
|---|---|
| `direct` | the client calls up1 only |
| `race2` | a client that races two endpoints on every call: up1 and up2 get every request, the first JSON-RPC result wins, up3 is never called |
| `endpoint` | a JSON-RPC endpoint you run yourself, at `ENDPOINT_URL` (see below) |
| `lasso` | Lasso, `/rpc/profile/trial/<chain>`, the default strategy |
| `lasso-fastest` | Lasso, `/rpc/profile/trial/fastest/<chain>` |
| `lasso-bf` | Lasso, `/rpc/profile/trial/balanced-fast/<chain>` |

Lasso gets one profile, `trial`, with the chain, its three upstreams and its block time, and nothing else. It also gets a minimal `public` profile that points at a closed local port, because Lasso requires one. Each run's generated profiles are in `results/.../<candidate>/lasso-data/config/profiles/`. Lasso starts fresh for every run.

## Measure this against what you use today

The `endpoint` candidate puts any JSON-RPC endpoint you run through the same scenarios. Its mock upstreams always listen on the same ports:

| upstream | URL with the default `PORT_BASE` |
|---|---|
| up1 | `http://127.0.0.1:43001` (`PORT_BASE` + 1) |
| up2 | `http://127.0.0.1:43002` (`PORT_BASE` + 2) |
| up3 | `http://127.0.0.1:43003` (`PORT_BASE` + 3) |

Configure your proxy or load balancer with those three upstreams for chain id 137 (`0x89`) and start it. Then pass its URL:

```sh
ENDPOINT_URL=http://127.0.0.1:8080/your/chain/path scripts/trial/run.sh
```

For each run the kit starts the mocks, prints their URLs, waits up to `ENDPOINT_WAIT_S` (default 120) seconds for `ENDPOINT_URL` to answer `eth_chainId`, then sends the workload. A scenario may leave an upstream closed (S1) or hanging (S2), so make sure your endpoint answers `eth_chainId` while up3 alone is healthy.

An endpoint you start by hand keeps whatever it learned in earlier scenarios, while Lasso starts fresh each run. To give it the same treatment, set `ENDPOINT_CMD` to a shell command that starts it in the foreground. The kit runs the command after the mocks are up, with the upstream URLs in `TRIAL_UPSTREAMS` (comma-separated), records its memory and CPU, and stops it after the run.

## Scenarios

Upstreams are up1, up2 and up3. Latencies have 20% uniform jitter. Read scenarios send 5 requests per second for the duration (open loop, 10 s client timeout, seed 527): `eth_call` 35%, `eth_getBalance` 25%, `eth_blockNumber` 15%, and 5% each of `eth_chainId`, `eth_getTransactionCount`, `eth_gasPrice`, `eth_getLogs` (last 100 blocks) and `eth_getTransactionReceipt` (a transaction 3 blocks deep).

| scenario | upstreams | workload |
|---|---|---|
| S1 | up1, up2 refuse connections; up3 50 ms | reads |
| S2 | up1, up2 accept connections and never answer; up3 50 ms | reads |
| S2m | 20, 30, 50 ms; at 60 s up1 and up2 start accepting and never answering | reads |
| S3 | up1 20 ms with HTTP 429 on 60% of calls; up2 60 ms; up3 120 ms | reads |
| S4 | up1 10 ms but 5 blocks behind; up2, up3 60 ms | reads |
| S4m | 10, 60, 60 ms; at 60 s up1's head stops and stays stopped | reads |
| S4r | as S4m, and up1 rejoins the chain at 120 s | reads |
| S4n | 40, 40, 40 ms; at 60 s up1's head stops | reads |
| S5 | up1 20 ms refuses `eth_getLogs` and `eth_getTransactionReceipt`; up2 60 ms; up3 120 ms | reads |
| S6 | 20, 60, 120 ms | reads |
| S8 | 20, 60, 120 ms | none for 10 minutes; background upstream calls, CPU and memory |
| S9a | 20, 60, 120 ms | 50 distinct `eth_sendRawTransaction` at 5 per second |
| S9b | up1 20 ms accepts sends and never answers them; up2 60 ms; up3 120 ms | 50 sends at 5 per second |
| S9s | as S9b | reads plus one send every 2 s |
| S9m | 20, 60, 120 ms; at 60 s up1 starts hanging on sends | reads plus one send every 2 s |
| S10 | 13 chains, 3 upstreams each at 20, 60, 120 ms | none for 10 minutes |
| S11 | 20, 60, 120 ms; at 60 s up1 starts taking 2 s per answer | reads |
| B1 | see below | wide `eth_getLogs` backfill |
| R | real endpoints from `UPSTREAMS` | reads |

### B1: wide backfill

Nodes cap how many blocks one `eth_getLogs` call may span, and the caps differ between them.

- up1: 20 ms, caps a call at 1,000 blocks.
- up2: 60 ms, caps a call at 10,000 blocks, and answers 30% of its calls with HTTP 429.
- up3: 120 ms, no cap.

A range wider than the cap gets JSON-RPC error `-32000`. up1 words it `query exceeds max block range 1000` and up2 `exceed maximum block range: 10000`, two wordings real node clients use.

The client backfills like an indexer. Every 6 s a pass starts that reads 100,000 blocks, ending 10,000 blocks below the head, as ten 10,000-block windows sent one after another. A failed window is not retried. Every window fits up2's and up3's caps, so a candidate can serve all of them by avoiding up1 and getting past up2's 429s. The table reports windows served, passes where every window succeeded, upstream calls per window broken down by upstream and outcome, window latency, wall time per pass, and client errors by message. A served window also has its log count checked.

### Mock chain

The mocks share one deterministic chain: a block every 2 s from a fixed epoch, hashes derived from the block number, and a log at every tenth block. All instances agree, and balance, nonce and `eth_call` results encode the block they were served at, so the kit can tell how stale each answer was. Each request's params carry a unique tag that the mock logs, which gives exact upstream calls per client request.

## Repeats

`run.sh` names each run `<scenario>-r<N>`, and `analyze.mjs` adds a Repeats section: for each scenario and candidate, the lowest and highest success, p50, p95, stale reads and upstream calls per request across repeats.

Repeats agree when every spread (highest minus lowest) stays within:

| metric | tolerance |
|---|---|
| success | 1 percentage point |
| stale reads | 1 percentage point |
| p50, p95 | the larger of 5 ms and 20% of the lowest value |
| upstream calls per request | 0.1 |

The scenarios are built so the differences they show are larger than these bounds. Upstream latencies differ 2x to 3x (20, 60, 120 ms) and the mocks add 20% jitter, so a 20% band cannot change which upstream a candidate mostly uses. A fault a candidate handles or misses moves success by tens of points, while 1 point is 9 of the 900 reads in a 180 s run. A row that misses names the metrics that moved. When `direct` misses on latency, the host was busy, since `direct` adds nothing but the client to a mock; rerun on a quiet machine.

## Environment

| variable | meaning |
|---|---|
| `LASSO_REL` | Lasso release directory. Needed for `lasso*` candidates. |
| `ENDPOINT_URL` | your endpoint's URL. Needed for `endpoint`; when it is set, `run.sh` adds `endpoint` to the default candidates. |
| `ENDPOINT_CMD` | optional command that starts your endpoint for each run. |
| `ENDPOINT_WAIT_S` | how long to wait for your endpoint to answer (default 120). |
| `CANDIDATES` | comma-separated candidates for `run.sh` (default `direct,race2,lasso,lasso-fastest,lasso-bf`). |
| `REPEATS`, `DURATION` | `run.sh` repeats (default 3) and seconds per scenario (default 180). |
| `OUT` | `run.sh` results directory (default `scripts/trial/results/<UTC time>`). |
| `PORT_BASE` | first port the kit uses (default 43000). It uses 60 ports per candidate, 360 in all. |
| `RUN_ID`, `RESULTS_DIR` | `runner.mjs` run name (default: the scenario) and parent directory (default `scripts/trial/results/runs`). |
| `IDLE_S` | overrides the 600 s idle length of S8 and S10. |
| `BLOCK_PATTERN` | `burst` makes the mock chain alternate 10 s of 250 ms blocks with 10 s of 2 s blocks. |
| `LASSO_PROBE_MS`, `LASSO_MONITORING` | Lasso `monitoring` settings for the trial chain; the second takes JSON. Unset leaves Lasso's defaults. |
| `UPSTREAMS`, `CHAIN_ID`, `BLOCK_TIME_MS` | real-endpoint mode, see below. |

## Changing faults by hand

Each candidate's mock process has a control port at `PORT_BASE + 60 * i + 49`, where `i` is the candidate's place in this list, from 0: `endpoint`, `direct`, `race2`, `lasso`, `lasso-fastest`, `lasso-bf`. `GET /` returns every instance's settings; `POST /config/<instance>` merges JSON into one instance:

```sh
curl -X POST localhost:43049/config/up1 -d '{"hang": true}'
curl -X POST localhost:43049/config/up1 -d '{"hang": false, "behind": 5, "rate_429": 0.3}'
```

Settings: `latency_ms`, `jitter`, `behind` (blocks), `stall` (freeze the head), `rate_429` (fraction), `refuse_methods` (list), `hang`, `send_timeout` (hang on sends only), `max_range` (`eth_getLogs` block cap), `range_error` (`{code, message}`, `{cap}` in the message is replaced), `chain_id`. Timed switches in S2m, S4m, S9m and S11 use the same endpoint.

## Real endpoints

```sh
UPSTREAMS=https://rpc-a.example,https://rpc-b.example,https://rpc-c.example CHAIN_ID=137 BLOCK_TIME_MS=2000 \
  node scripts/trial/runner.mjs R direct,race2,lasso-fastest,lasso-bf 180
```

`direct` uses the first URL and `race2` the first two. The workload takes its head from polling the first URL once a second. Without mocks the tables report success, errors and latency only; upstream calls and stale reads need the mock logs and clock. Each candidate sends 900 requests in 3 minutes (`race2` sends that to two endpoints), so mind rate limits.

The URLs are written into the configuration files under `results/`. If they contain keys, remove those files before sharing results. The runner prints the same warning.

## Output

`results/<run>/<candidate>/` holds `client.jsonl` (one line per client request), `upstream.jsonl` (one line per upstream request, with outcome `ok`, `error`, `429` or `hang`), `meta.json`, `proxy.log`, `mock.log`, and `resources.json` for idle scenarios. `analyze.mjs` reads `.jsonl.gz` files too.

In the tables, a read is stale when its block is 2 or more blocks older than the true head when the answer arrived. "Backwards" counts answers older than one received earlier (in brackets, older by more than one block). Upstream calls per tagged request count every upstream call that carried the request's tag, including retries and hedges.
