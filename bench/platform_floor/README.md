# HTTP platform-floor benchmark

This benchmark separates HTTP platform cost from Lasso routing cost. It is a
diagnostic, not a release gate and not an eRPC comparison suite.

The four floor lanes are:

| mode | endpoint | work |
| --- | --- | --- |
| bare | `/echo` | Cowboy, Plug, JSON decode/encode |
| bare | `/proxy` | echo work plus one Finch HTTP/1 request |
| phoenix | `/echo` | Phoenix endpoint/router plug stack plus JSON decode/encode |
| phoenix | `/proxy` | Phoenix floor plus one Finch HTTP/1 request |

The floor deliberately excludes Lasso routing, breaker, retry, projection,
dashboard, and metering logic. Compare a Lasso run with the Phoenix proxy floor
to estimate the Lasso-specific slice without pretending the platform is free.

## Measurement contract

- Run the target and synthetic upstream in separate containers with explicit
  CPU and memory limits.
- Use at least two load-driver workers and two upstream workers.
- Keep request/response validation and one-to-one upstream amplification enabled.
- Treat target cgroup CPU microseconds per successful request as the primary
  cost metric. Use throughput to show saturation headroom, not as a standalone
  winner.
- Report p50, p95, and p99 latency, errors, target throttling, peak memory, and
  upstream request/response counts.
- Rotate lane order for at least three rounds. Do not compare cells whose load
  driver or upstream is saturated.

The driver uses Node worker threads so one JavaScript event loop does not cap the
target. The upstream uses Node cluster workers and exposes control/statistics on
a separate admin port.

## Build and run

From the repository root:

```sh
docker build -f bench/platform_floor/floor_app/Dockerfile -t lasso-platform-floor .

docker run --rm --name lasso-floor-upstream --cpus=2 --memory=1g \
  -v "$PWD/bench/platform_floor:/bench:ro" \
  -e WORKERS=2 -e PORT=4100 -e ADMIN_PORT=4101 \
  -p 4100:4100 -p 4101:4101 node:22-alpine \
  node /bench/synthetic_upstream.mjs
```

Start a floor lane:

```sh
docker run --rm --name lasso-platform-floor --cpus=4 --memory=2g \
  --add-host=host.docker.internal:host-gateway \
  -e FLOOR_MODE=phoenix -e PORT=4200 \
  -e UPSTREAM_URL=http://host.docker.internal:4100 \
  -p 4200:4200 lasso-platform-floor
```

Run a measured cell from the host:

```sh
node bench/platform_floor/load_driver.mjs \
  --url=http://127.0.0.1:4200/proxy \
  --workers=4 --concurrency=128 --warmup=5 --duration=15 \
  --targetContainer=lasso-platform-floor \
  --upstreamContainer=lasso-floor-upstream \
  --upstreamAdminUrl=http://127.0.0.1:4101
```

The result is one JSON document suitable for appending to a JSONL artifact.
The target and upstream containers must use cgroup v2 for exact CPU accounting.
The output includes their CPU quota, CPU and throttled time, memory, and the
load driver's equivalent core usage so saturated cells can be rejected.

Run the benchmark utility tests with:

```sh
node --test bench/platform_floor/test/*.test.mjs
```
