# Changelog

All notable changes to Lasso RPC will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- A read of past state behind full nodes that keep only recent state now reaches an archive. A pruned-state refusal (such as geth's `missing trie node`) to a replay-safe state, proof or trace read below the accepted head no longer spends one of the read's dispatches; the walk stays bounded by the admission cap and the request deadline. Block, receipt and log reads, and reads at the head, still spend it.
- Learned historical depth applies per resource class instead of per method, so a cutoff learned from `eth_getBalance` refusals also covers `eth_call`, `eth_getCode` and `eth_getStorageAt` of the same state. `eth_getBalance` joins the `state` class. In the trial kit's pruned-history scenario (L1), refusals fell from 20 to 25 per run to 10 to 16.
- A route held back by a learned method refusal is now a last resort for the rest of the request instead of being dropped after the first dispatch. It is tried only after every ordinary candidate has been tried and while dispatch budget remains, so a read whose other routes fail no longer errors with budget unspent. When the request's first attempt goes to its last ordinary candidate, that attempt leaves time for the saved route. Custom strategies' candidate lists keep such a route as their last entry too. A learned deferral recovers on an accepted success from its route or expires within an hour. Routes deferred by a learned span limit or historical depth already wait behind the ordinary routes of their availability tier.

### Compatibility

- Learned outcome statistics move to version 3. Version-2 rows load unchanged, except rows for the retired `balance` class, which are dropped and relearned.
- Learned historical depth moves to version 4. Version-2 and version-3 rows are dropped and relearned.

## [0.10.0] - 2026-11-27

### Added

- BNB Smart Chain (`/rpc/bsc`) and Tempo (`/rpc/tempo`) in the bundled public profile, from keyless endpoints that passed two qualification passes. Evidence is in `docs/evidence/public-template/56.md` and `4217.md`.

### Changed

- Routes that name no strategy, such as `/rpc/:chain`, `/rpc/profile/:profile/:chain` and their WebSocket equivalents, now use `balanced-fast`, which spreads load while favoring the quickest providers. `load-balanced` stays available by name. To keep the old default, set `config :lasso, :provider_selection_strategy, :load_balanced`.
- A chain whose profile sets no head-poll interval now polls heads every `max(2 * block_time_ms, 5000)` ms, or 12 s without `block_time_ms`, instead of a fixed 12 s. Periodic `eth_chainId` identity checks run every 30 minutes instead of on every head poll. A routed request that times out still schedules a probe of its upstream, so a hung upstream still leaves rotation. Set `monitoring.chain_identity_interval_ms` to keep a shorter identity interval.
- `fastest` now ranks every request with the weighted latency permutation that `balanced-fast` uses, at exponent 8 instead of 3. A route half as fast as the quickest goes first about 1 time in 257; one ten times slower, about once in 10^8. One unproven route per request, with no evidence or only stale evidence, competes at the quickest route's weight, so a route that slows down or a new provider is measured again instead of being held off by a cached winner. Unproven routes in `balanced-fast` include stale ones too.
- A registered transaction send, such as `eth_sendRawTransaction`, reaches up to three providers one at a time with or without a chain `transactions` block. `eth_sendRawTransaction` fails over on every rejection except known transactions and sender faults, which it also reads from a plaintext non-2xx body, and a rate-limit or quota refusal or a `-32601` does not count toward the three. Before returning a rejection, Lasso looks up the hash on the upstream that answered last and on each earlier one that may have broadcast it, and returns the hash when one finds it, or `-32000` "Upstream dispatch outcome is indeterminate" when an earlier send may have broadcast and a lookup could not answer. See [transaction sends](docs/RPC_STANDARDS.md#transaction-sends).
- Reads that need the latest block are judged by head rounds. Each round asks every upstream on the chain for its head at the same moment, and an upstream's lag is the round's highest agreeing height less its own, credited for the blocks the configured block time fits between its answer and the highest one. A route whose lag is above the agreement band is tried after the others until a later round measures it within the band. An upstream that answers first every round while behind keeps its lag, where before a steadily lagging upstream could look current once its observation aged against a newer one. On a local benchmark with blocks alternating between 250 ms and 2 s, reads served more than a block behind fell from 3 to 15% to 0.4% or less. A `head_suitability` decision in `lasso_meta` lists each deferred or unmeasured route with `lag` and `lag_age_ms`, and no longer carries `mark`, `outlier` or `omitted_outliers`. Reads at a fixed block keep their current judgment. See [Head freshness](docs/ROUTING.md#head-freshness).
- `load-balanced` gives fewer first picks to a route that fails clearly more often than its peers. Each route keeps a recent failure rate per method family; one above both twice the peers' lower median and 1/32 is weighed down by the square of that ratio, never below 1/8 of a peer's share, and returns to an equal share as its rate decays. A rate limit doesn't count, and when every route fails alike none is deferred. With one of three upstreams holding every tenth read until it timed out, reads sent to it fell from about 3% to under 2% and p99 from about 3.1 s to 1.3 s. Set `LASSO_PROVIDER_KNOWLEDGE_FAILURE_RATE_DEFERRAL_MODE=off` to share load equally. See [Load Balanced](docs/ROUTING.md#load-balanced).
- A failing route's evidence lifetime doubles with each consecutive failure after the first, up to an hour, so a route that never answers is re-sampled a few times a day instead of every five minutes. A success resets it.

### Removed

- Bounded read exploration and its `config :lasso, :routing_exploration` settings. Both adaptive strategies now sample unproven routes in their ranking. The `exploration` attempt kind is gone from execution facts, whose version-2 wire shape is otherwise unchanged.
- The response-latency learner and its `response_latency` provider-knowledge effect mode. The mode reordered `fastest` results and has nothing to reorder now that `fastest` samples routes itself.

### Fixed

- An identity probe whose answer is empty, unparsable, null or not a valid hex chain ID no longer marks the upstream as serving the wrong chain. Only a readable wrong chain ID does. Previously one malformed answer blocked HTTP requests to that upstream until the next identity check; it now counts as an ordinary probe failure and requests keep flowing.

- A background HTTP 429 holds an upstream out of routing only for its `Retry-After`, or 30 s without one. The identity prober recorded a fixed 60 s cooldown on every 429, and the head poller held the route for at least two poll intervals, so a provider that asked for one second could stay out for a minute. A head-poll answer that names exhausted quota still holds the upstream for at least an hour, and a rate-limited probe no longer counts as unhealthy.
- Learned feedback reaches the learner from every bucket of its delivery lane. Only the lowest-numbered bucket with queued work was drained, so feedback in the others, such as a method refusal, waited until it expired and the matching limit was learned late or not at all. With a lower bucket kept busy, a higher bucket's item now arrives in milliseconds where before it was never delivered.

### Security

- db_connection 2.10.3, for EEF-CVE-2026-133555.

### Compatibility

- No storage format or configuration changes are required. A container deployment upgrades from v0.9.0 with the new image alone.
- Expect traffic to move: requests that name no strategy route with `balanced-fast`, `fastest` samples slower routes now and then, `load-balanced` sends fewer first picks to a route that fails often, and a raw transaction send can reach up to three providers.
- Removed settings (`config :lasso, :routing_exploration` and the `response_latency` effect mode) are no longer read.

### Known issues

- Between head observations, a provider a few blocks behind can still answer a read at a fixed block it hasn't reached with `null` or an empty log list ([#460](https://github.com/jaxernst/lasso-rpc/issues/460)).
- A `header not found` answer fails over to the next provider but doesn't get the extra send to a provider known to have the block. When that provider is half-open, the read can fail without trying it ([#458](https://github.com/jaxernst/lasso-rpc/issues/458)).
- With an even number of upstreams in a head round, a lagging one can become the mark ([#451](https://github.com/jaxernst/lasso-rpc/issues/451)).
- A pooled HTTP connection can be reused just after the upstream's keep-alive closed it, failing that attempt over ([#450](https://github.com/jaxernst/lasso-rpc/issues/450)).

## [0.9.0] - 2026-11-21

### Added

- Standalone archives for Linux x86_64, Linux aarch64 and macOS on Apple silicon, attached to each release. They run without Erlang, Docker or system OpenSSL and start with no environment variables: unpack one and run `lasso/bin/lasso start`. They need glibc 2.28 or later on Linux and macOS 12 or later. Each archive has a checksum, an SPDX SBOM and build provenance. See [Standalone Archives](docs/DEPLOYMENT.md#standalone-archives).
- `sidecar.vm.args` in the release, for a node that another application starts on the same machine: two schedulers that sleep as soon as they are idle. Use it with `RELEASE_MODE=interactive`. See [Running Beside Another Application](docs/DEPLOYMENT.md#running-beside-another-application).
- `scripts/measure_profile.mjs` sends the same calls, at the same moment, to each provider directly and through a Lasso profile that uses those providers, and prints answers, errors by kind, latency percentiles, the answering provider and upstream sends per call. It needs Node.js 18 or newer, no packages and a clone of this repository. See [Measure a profile against its own providers](docs/MIGRATION.md#measure-a-profile-against-its-own-providers).

### Fixed

- A request that reached a circuit breaker just as it changed state is no longer refused. A request reads the breaker's last published state, and if the breaker moved to half-open for a recovery attempt or closed before answering, it refused the request as unavailable although it would have admitted it. A WebSocket subscription recovering through its only HTTP upstream was closed with "continuity exhausted" on that one refusal, with most of its recovery time unused. The breaker now answers from its current state.
- A node no longer stops at boot when it cannot create its benchmark snapshot directory, as happened when a standalone archive was unpacked somewhere read-only. It starts, serves requests and logs that snapshots will not be saved. Set `RELEASE_TMP` or `LASSO_SNAPSHOTS_DIR` to a writable directory to keep them.
- `fastest` no longer keeps sending a method family to upstreams that are failing when none has qualified yet. With no qualified upstream it ordered candidates by prior latency and then provider id, so an upstream with three consecutive failures and no successes still sorted ahead of an untried one with a later id. With two of three upstreams accepting requests and never answering, 629 of 900 requests failed in a three-minute run, and every `eth_call` failed until the end; with this change 8 failed, all in the first three seconds. Upstreams whose evidence is unreliable now sort after the other unqualified ones. See [fastest](docs/ROUTING.md#fastest).
- `balanced-fast` no longer locks a method family onto the first upstream to qualify. It ranked qualified upstreams ahead of all others, so the first one to reach three successes in a family kept that family's traffic and the rest never earned the samples to qualify. On three healthy upstreams at 20, 60 and 120 ms, `eth_call` or `eth_getLogs` could stay on a slower one for a whole run. Reliable upstreams with latency evidence (client samples in the method family, else the same family's system prior) now share one weighted permutation, joined in each ranking by one upstream with no latency evidence at the weight of the quickest. Upstreams with three consecutive failures or a recent success probability below 0.75 follow, ordered the same way. `fastest` is unchanged. See [balanced fast](docs/ROUTING.md#balanced-fast).
- A provider steadily behind the freshest head no longer starts serving `latest` reads again between head polls. Each provider was credited with the blocks the chain could have produced since its own head was observed, while the freshest head was not credited the same way, so on a fast chain a provider polled at the same moment soon looked current. Requests that need the latest block now credit only the time between the two observations; reads at a fixed block keep crediting the observation's full age. See [Head freshness](docs/ROUTING.md#head-freshness).
- An upstream that accepts requests and never answers now leaves the route. Request timeouts never counted against a provider's circuit and nothing else checked it, so under `priority` every request first waited out its attempt on that upstream, and with two such upstreams ahead of a healthy one every `eth_getBalance` failed. A request timeout still does not count, because it shows only that the upstream was slower than that attempt's share of the request budget. It now has the health prober check the upstream on its next tick, and two consecutive probe timeouts (five seconds each) open its HTTP circuit. See [Circuit Breaker System](docs/ARCHITECTURE.md#circuit-breaker-system).

### Security

- Phoenix 1.8.17 and Phoenix.PubSub 2.4.1, for CVE-2026-128361 (an unsanitized presence key crashes the Presence tracker) and CVE-2026-129344 (a channel message that cannot be serialized crashes broadcast dispatch for clients on a shared topic).
- Phoenix LiveView 1.1.34, for CVE-2026-126334 (joining a LiveView without `"url"` skips its `live_session` `on_mount` hooks).

### Changed

- A release starts with no environment variables. Without `RELEASE_COOKIE` or `CLUSTER_DNS_QUERY` it runs without Erlang distribution, so it opens no EPMD or distribution port and never uses the cookie written into the release at build time, which every copy of the same build shares. Unless `LASSO_NODE_ID` and `SECRET_KEY_BASE` are set, such a node uses the node ID `local` and generates `SECRET_KEY_BASE` per boot (dashboard sessions end at restart). It reads the profiles the release now carries in `config/profiles` and writes benchmark snapshots under `RELEASE_TMP`. A distributed node still requires `SECRET_KEY_BASE` and `LASSO_NODE_ID`. See [Launching a Native Release](docs/DEPLOYMENT.md#launching-a-native-release).
- **Behavior change for native releases started without `RELEASE_COOKIE`**, as the deployment guide showed: such a node ran Erlang distribution with the build-time cookie and now runs without it, so `lasso reload`, `rpc`, `remote`, `stop`, `restart` and `pid` exit with a message that distribution is off. Set `RELEASE_COOKIE` when starting the node and when running these commands, or restart the node to apply profile changes; `lasso check-config` is unaffected. Container images, including the source `compose.yml` and `./run-docker.sh`, are built without the release's `env.sh` template and keep their current distribution behavior.
- `vm.args` no longer fixes the scheduler count to the cores of the machine that built the release; the VM uses the cores, and any CPU quota, of the machine it runs on. The flags that restated OTP 28 defaults (`-smp auto`, `+t 1048576`, `+P 1048576`, `net_ticktime 60` and `prevent_overlapping_partitions true`) are removed. Container images never used this file, so they are unaffected.
- Requests whose URL names no strategy (`/rpc/:chain`, `/rpc/profile/:profile/:chain`, `/ws/rpc/:chain` and `/ws/rpc/profile/:profile/:chain`) route with `balanced-fast` instead of `load-balanced`. This changes behaviour for those URLs: providers with lower recent latency receive more of the traffic, where `load-balanced` spread it evenly regardless of latency. URLs that name a strategy are unchanged. To keep the previous behaviour, route through `/rpc/load-balanced/:chain` (or `/rpc/profile/:profile/load-balanced/:chain` and the WebSocket equivalents), or set `config :lasso, :provider_selection_strategy, :load_balanced`. See [Default Strategy](docs/CONFIGURATION.md#default-strategy).
- Requests that need the chain's latest block prefer providers with a current head, under every strategy. A request's need comes from its own parameters: a `latest` selector, the upper bound of a log or trace range (an omitted one means `latest`), an omitted optional selector on reads such as `eth_call` and `eth_getBalance`, and lookups by transaction hash. A provider whose observed head is behind the profile's freshest head by more than the agreement band (about two seconds of blocks) is tried after the others, and so is one reporting the agreed head height on a different block hash. Historical reads at a fixed block, block-hash lookups, `finalized` and `safe` reads and writes keep strategy order, so a provider a few blocks behind still serves the blocks it has. No provider is excluded: when the current ones fail, a lagging one still answers. Head reads routed through Lasso count as observations, so this works with background polling off. See [Head freshness](docs/ROUTING.md#head-freshness).

### Removed

- `selection.max_lag_blocks` is retired. A fixed block count means different things on different chains (ten blocks is 2.5 seconds at 250 ms blocks and two minutes at 12-second blocks), and the filter excluded lagging providers even from historical reads they could serve. Profiles that still set it keep loading; the field has no effect, and each load logs a warning naming the profile and chains. Remove it from your profiles. Nothing replaces it: freshness preference is automatic and follows `block_time_ms`.

### Compatibility

- No storage format changes. A container deployment, including the downloadable `compose.yml`, upgrades from v0.8.6 with the new image alone and keeps its distribution behavior and data paths.
- A native release started without `RELEASE_COOKIE` runs without Erlang distribution. Set `RELEASE_COOKIE` when starting the node and when running `lasso reload`, `rpc`, `remote`, `stop`, `restart` or `pid`; without it those commands exit with a message that distribution is off, and SIGTERM stops the node.
- A native release started without `LASSO_DATA_DIR` or `LASSO_PROFILES_DIR` reads the profiles it carries and writes snapshots under `RELEASE_TMP`, no longer `config/profiles` and `priv/benchmark_snapshots` in its working directory. Set `LASSO_DATA_DIR` to keep your own profiles and history. Its scheduler count now follows the machine it runs on, not the build machine.
- Profiles that set `selection.max_lag_blocks` still load and log a warning on each load. Remove the field.
- Expect traffic to move: requests for the latest block try providers more than the agreement band behind the freshest head after the others, `balanced-fast` spreads each method family across reliable upstreams, and an upstream whose health probe times out twice in a row has its HTTP circuit opened.

## [0.8.6] - 2026-11-19

### Added

- `lasso check-config` and the profile loader warn about each `*.yaml` file in the profiles directory. Profile files must end in `.yml`; previously a `.yaml` file was skipped without a word, so its profile returned 404 while `check-config` reported the configuration valid. The warning never fails a check, load or reload, and files starting with `.` or `_` stay silent.
- The README and `docs/DEPLOYMENT.md` show how to run a profile exported from a hosted Lasso account on a self-hosted node.

### Fixed

- A WebSocket continuity backfill that fails on one HTTP source and is retried on another is now logged once, at warning level, instead of several times at error level. Owner crashes, an expired recovery deadline and terminal resubscribe failures still log at error.
- An upstream that answers HTTP 402 because its plan allowance is spent is treated like HTTP 429: Lasso tries the next provider, keeps any `Retry-After` hint as that provider's cooldown, and no longer counts the refusal toward the provider's circuit breaker. Previously each 402 counted as a provider failure, so a keyed upstream whose daily allowance ran out could open its circuit for every method. When every provider refuses, the client gets `-32005` with no upstream body bytes.
- A gateway that refuses a method with HTTP 406 and a non-JSON-RPC body (RFC 9110 15.5.7, before its RPC handler runs) no longer counts as a provider failure. Lasso tries the next provider for that request and leaves the refusing provider's circuit closed, so its other methods keep serving. Previously five refusals of one method opened the circuit for every method. When no provider serves the request, the client gets a `-32006` capability refusal with no upstream body bytes. Previously a 406 body that was not valid UTF-8 made the client response fail with HTTP 500.

### Changed

- The bundled `public` profile serves Robinhood Chain (chain ID 4663), and its Base providers are the keyless endpoints that passed two live qualification passes. Each provider declares the log range and request budget it sustained, providers that refused log queries are kept out of `eth_getLogs`, and only endpoints that served account state at genesis in both passes take historical reads. Base no longer lists endpoints that failed qualification or that their operator documents as not for production. See the [qualification evidence](docs/evidence/public-template/).
- The bundled `public` profile serves Optimism (chain ID 10), Unichain (130) and World Chain (480) from keyless endpoints that passed two live qualification passes, with the same per-provider log ranges, request budgets and history rules as Base. Each chain keeps an archival provider with no declared log range for historical `eth_getLogs`. World Chain has two primary keyless routes.

### Removed

- `LASSO_COWBOY_TELEMETRY_ENABLED` is gone. Cowboy per-request telemetry was already on by default and now always is; setting the variable has no effect.
- The unused provider-knowledge template shadow path is gone: the `:provider_knowledge_template_observer`, `:provider_knowledge_template_outcomes`, `:provider_knowledge_template_catalog`, `:provider_knowledge_classifier_mode`, `:provider_knowledge_request_fault_mode` and `:provider_knowledge_eval_sample_enabled` application settings, the `[:lasso, :provider_knowledge, :classifier_shadow]` telemetry event, the `classifier_shadow_since_boot` census field, and the `:provider_messages` and `:provider_outcomes` projection lanes. All were off or inert in Core, so routing is unchanged; setting any of these settings now has no effect.

### Compatibility

- No storage or profile format changes. Upgrading from v0.8.5 needs only the new image or release.
- HTTP 402 and 406 refusals no longer open circuits. They appear as rate limits and capability refusals, so alerts keyed on those circuit openings stop firing.
- Setting a removed variable or application setting has no effect and is not an error.

## [0.8.5] - 2026-11-19

### Added

- A provider can declare `request_budget` (`requests_per_second` and an optional `burst`) to cap what each Lasso node sends that upstream: client requests, retries and fallbacks, subscription calls, and background head and identity checks. Every profile that references the same upstream shares one budget. When the budget is spent, requests move to another eligible provider without counting against the spent one, and background checks skip their turn. If every eligible provider is spent, the client gets `-32005` with `data.reason: "upstream_request_budget_exhausted"` and `data.retry_after_ms` set to the earliest refill. Provider details show the budget and admitted and refused totals. Previously a provider with a hard request quota needed a separate egress limiter in front of Lasso. See [outbound request budget](docs/CONFIGURATION.md#outbound-request-budget).

### Fixed

- Providers added or updated at runtime keep every setting a profile file accepts. Previously runtime registration copied a fixed list of fields and silently dropped the rest, such as `background_observations` and the observation intervals. Runtime changes now go through the same parser and schema as profile files, and the whole candidate configuration is validated before anything is published, so an invalid change returns an error and leaves the running configuration untouched.
- `Lasso.Providers.update_provider/4` keeps omitted settings, and an explicit `nil` removes an optional one. Two updates to the same provider at once can no longer overwrite each other: the second returns `{:error, :provider_changed}`.
- Providers with only a `ws_url` load and serve. Previously some startup and dashboard paths assumed an HTTP URL.
- After an HTTP connection failure, Lasso stops routing to the refused endpoint and restores it within seconds of recovery, including subscription replay while the circuit is on probation.
- When a disconnect cancels an in-flight replacement for a sole-provider WebSocket subscription, the subscription waits for reconnect within its recovery deadline instead of closing as though the provider had been removed.
- `eth_getLogs` refusals for exactly one block (equal resolved `fromBlock` and `toBlock`, or a `blockHash` query) no longer tell clients to narrow the range. Lasso tries other providers and, if none serves the request, returns a `-32006` capability refusal without narrowing advice, so missing history can't trap a client in repeated narrowing.
- Dashboard cluster coverage shows responding nodes out of expected nodes. Missing configured nodes stay in the total, and traffic summaries read as incomplete until every expected node reports. Without `:expected_cluster_nodes`, the total is the connected node count.

### Changed

- Capability and error-rule category names must be categories Lasso knows. Previously an unknown name loaded and never matched anything; now the profile fails to load with an error naming the field.

### Compatibility

- No storage changes. Upgrading from v0.8.4 needs only the new image or release.
- Profiles with unknown `capabilities.unsupported_categories` or `error_rules[].category` names must fix them before upgrading.
- `Lasso.Providers.update_provider` accepts only plain map patches; a struct returns `{:error, :invalid_provider_updates}`. Code that updates the same provider concurrently should retry on `{:error, :provider_changed}`. `add_provider` and `update_provider` reject fields a profile file would reject, including `credentials`, which was accepted at runtime and never used.

## [0.8.4] - 2026-11-18

### Fixed

- When one provider refuses an `eth_getLogs` range as too large and the remaining attempts time out or are rate-limited, the client receives the range error (`-32005`, `data.reason: "log_range_too_large"`, `data.action: "reduce_block_range"`) instead of whichever timeout or rate limit came last. Previously the advice could be lost, so a client kept retrying a range no provider would serve. When refusing providers set `capabilities.limits.max_block_range`, `data.max_block_range` reports the smallest of those caps. Lasso no longer reads a number from provider error text, which could report a history-retention limit as a range cap.
- HTTP 429 responses honor the wait the provider asks for. A `Retry-After` header, in seconds or as an HTTP date, takes precedence; otherwise Lasso uses `data.retry_after_ms`, then `data.retry_after` in whole seconds, then a delay in the message such as `Try again in 120 seconds`. Previously the header was ignored, so a provider that asked for two minutes got traffic back after the 30-second default. Every delay is capped at ten minutes, however large the value. Lasso keeps the 429's code and up to 1,000 bytes of its message and discards the rest of the error body.
- When the only upstream behind a subscription disconnects while Lasso replays missed blocks and returns within the 30-second recovery deadline, the subscription continues and delivers later heads. Previously the client was closed with `1011` even though the provider came back. Replay also tries an independent HTTP source before the replacement provider's own endpoint on chains with `transactions` routing, as it already did on every other chain.

### Changed

- A zero or past `Retry-After` value is ignored in favor of the body hint or the default cooldown, so it can't send traffic straight back to a provider that is refusing it.
- Startup and reload reject `capabilities.limits.block_age_methods` entries whose method has no block number parameter Lasso can read, such as `eth_getLogs`. The error says to remove the entry and to limit log queries with `max_block_range` instead. Such an entry used to load and never apply; now the profile fails to load.

### Documentation

- `fastest` measures latency per kind of request (basic reads, state, logs, trace, transactions, subscriptions) and transport, not per method. `round-robin` is an alias of `load-balanced`, which randomizes provider order per request, and responses report it as `load_balanced`.
- Profiles that reference the same upstream share its health and circuit breakers.

### Compatibility

- No storage changes. Upgrading from v0.8.3 needs only the new image or release.
- Profiles listing a method without a readable block number in `block_age_methods` must drop that entry before upgrading.

## [0.8.3] - 2026-11-18

### Fixed

- When a subscription moves to a replacement provider, that provider's first event reaches the client. Previously it could arrive before Lasso finished switching and be dropped, so the client skipped a head or the logs in it. Events from a replacement attempt that fails are now discarded before the next attempt, so a log that the winning provider's replay doesn't contain, such as one from a fork, no longer reaches the client.
- Subscription recovery replays through the highest block the stream already saw, including blocks seen only in events from a discarded replacement attempt. Previously recovery could complete below that height, so a `logs` subscription could skip a log and a `newHeads` subscription could miss the last head it saw until another one arrived. When the chosen replay source is behind, Lasso tries another eligible HTTP source that has caught up before waiting on the lagging one, which it re-checks every 100 ms. Every attempt shares the original 30-second recovery deadline. If no source covers the height in time, the client is closed with `1011` instead of skipping blocks.
- When an upstream WebSocket sends a ping and a close frame in one batch and then drops the connection, Lasso keeps the upstream's close code and reason, such as `1011`. Previously the failed pong write replaced them with a transport error.
- Provider configuration errors name the profile, chain and provider (by `id`, or by position when there is no `id`), the exact failing field, the expected type or allowed fields, and the type found. Previously an invalid provider reported a generic `invalid value type or range`, an unsupported field didn't list the supported ones, and a header error didn't say which field was wrong. Values, credentials and header names stay out of the message.
- Providers added at runtime are checked against the same `url`, `ws_url` and `priority` rules as profile files. Previously runtime registration with `validate: false` accepted a provider with no URL or a string priority.
- Subscription integration tests restore the suite's WebSocket client setting during teardown. Clearing it had crashed shared test runtimes, which made an exhausted subscription close after about one second in CI instead of after its 30-second recovery window.

### Compatibility

- Configuration errors keep the `{:invalid_profile_config, field, message}` shape, but `field` now starts with `profile.<name>.` and names the provider, and `message` states the expected and found types. Scripts that match the old message text need updating.
- Runtime provider registration reports header and field errors found during registration as `{:invalid_profile_config, field, message}` instead of `:invalid_provider_headers`.
- No storage changes. Upgrading from v0.8.2 needs only the new image or release.

## [0.8.2] - 2026-11-17

### Security

- Update Plug to 1.20.4 to address EEF-CVE-2026-120287, where the multipart `:length` limit did not count part and header framing.
- `mix hex.audit` still ignores EEF-CVE-2026-115701 (Cowboy) and EEF-CVE-2026-113431 (Cowlib) until a Hex release fixes them. Keep public nodes behind a reverse proxy that speaks HTTP/1.1 to Lasso; see [deployment](docs/DEPLOYMENT.md).

### Fixed

- An HTTP 429, 401 or 403 from an upstream now fails a read over to another provider even when its body is a JSON-RPC invalid-request or parse error. Previously Lasso could return it to the client as a bad request while a healthy provider went unused. Every HTTP 429 counts as a rate limit, and the body's quota wording and any retry-after hint stay with the error, so a quota refusal still keeps its longer cooldown.
- After a provider explicitly refuses a method, Lasso tries one route from an independent provider before more routes from the one that refused. Previously a read could spend its whole three-dispatch budget on routes from the refusing provider. Routes on unrecognized hosts are not treated as independent, and the next ordinary route stays within the budget.
- Subscriptions survive a brief upstream WebSocket disconnect. Recovery keeps retrying within its 30-second deadline, so a returning original provider or a sole upstream can resume the subscription; previously the client could be closed within milliseconds. Permanent failures and the deadline still close the client with `1011`.
- Refusing one incoming subscription frame under node-local ingress pressure now invalidates only that subscription, which recovers through the continuity path. Previously it closed the shared upstream WebSocket, failing unrelated pending requests and disconnecting every subscription on it.
- Lasso reads the `id`, `result` and `error` of a JSON-RPC response only at its top level. An upstream error whose `data` contained its own `id` could be matched to the wrong request.
- Provider URLs with credentials (`https://user:password@host/rpc`, `wss://user:password@host/ws`) authenticate with HTTP Basic on HTTP requests, WebSocket handshakes and discovery. Previously credentialed HTTP URLs failed and credentialed WebSocket URLs were rejected. Credentials no longer appear in discovery output or inspected state. See [configuration](docs/CONFIGURATION.md#environment-variable-substitution).
- `mix lasso.probe` works on a standalone node. It refused its own HTTP requests and reported zero supported methods.
- `/api/health` reports `cluster.enabled` from configured clustering (expected peers or libcluster topologies) or connected peers. A standalone node no longer reports clustering because a topology snapshot exists or Erlang distribution is on.
- The dashboard method row labels average latency `avg` instead of `p50`, and the browser no longer logs an unknown-hook error on every dashboard load.

### Changed

- Dashboard call counts, routing share, success rate, latency percentiles, RPS and per-method figures count client requests only. Lasso's own head polls, health probes and discovery no longer appear as provider traffic. Block height, lag and circuit state are unchanged.
- `deployment/compose.release.yml` in a source checkout defaults to the current release image instead of v0.4.5. The `compose.yml` attached to each release already named its own image.

### Added

- Container publication runs an upgrade check from the previous published release on both native architectures: it upgrades from that release's image, rolls back and recovers forward, and attaches the evidence to the release. A missing or unreadable previous-release record fails publication. See [releasing](docs/RELEASING.md#block-continuity-qualification).

### Documentation

- Migration describes transaction sends with transaction providers (up to three sends, one provider at a time, within the deadline) and points to `/rpc/priority/:chain`.
- Configuration states that unsupported methods fall back to the unsupported providers when no provider supports a method, that `max_block_age` has no effect on `eth_getLogs`, and how to run `check-config` and `reload` from source.
- Testing states that `--include integration` also runs tests that carry an excluded tag.
- The stale `.claude/` directory is removed.

### Compatibility

- One configuration change can be needed. A provider that puts credentials in its `url` or `ws_url` and also sets an Authorization header through `headers`, `auth_headers` or `api_key` now fails validation at startup or reload. Keep one of the two.
- Scripts that read `cluster.enabled` from `/api/health` on a standalone node with Erlang distribution on now see `false`.
- No storage changes. Upgrading from v0.8.1 needs only the new image or release.

## [0.8.1] - 2026-11-17

### Fixed

- A WebSocket subscription in a profile with exactly two providers now survives losing either one. Previously the subscription closed with `1011 Lasso subscription continuity exhausted`, because the blocks missed during failover could only be fetched from a third provider. Lasso now fills them from another eligible HTTP provider first and, when none is left, from the replacement provider's own HTTP endpoint.
- `head_policy: local` follows a same-height reorg. It could return the displaced latest block, and a canonical EIP-1898 state read that followed could fail.
- The dashboard reads each provider's height and lag from its own profile. With two profiles on one chain ID it could show a negative block height while reporting Healthy. The chain panel's recent decisions, distribution and RPS show live traffic again, and load-balanced mode is described as randomized order rather than even shares.
- `mix test` passes reliably on a fresh clone. Tests that relied on fixed sleeps now wait for the transitions they check. Two wall-clock measurements, the parser latency ceiling and the deadline-wakeup p95, moved under the excluded `:slow` tag; see [testing](docs/TESTING.md).

### Security

- `mix hex.audit` ignores EEF-CVE-2026-115701 (Cowboy) and EEF-CVE-2026-113431 (Cowlib) until a Hex release fixes them. Run public nodes behind a reverse proxy that speaks HTTP/1.1 to Lasso; see [deployment](docs/DEPLOYMENT.md).

### Removed

- The root `examples/` directory, including the executable logical-read client. [Read at one block](docs/READ_AT_ONE_BLOCK.md) remains the guide for hash-pinned reads.

### Documentation

- The architecture, deployment and contributing guides match the code: transaction sends are supported, `PHX_SERVER` is optional, and native releases have a launch example using `LASSO_DATA_DIR`.
- Configuration and routing state what transaction providers leave visible: simulations send calldata to read providers, hash polling links a connection to a transaction, and identity probes and head subscriptions still reach transaction providers.

### Compatibility

- No configuration or storage changes. Upgrading from v0.8.0 needs only the new image or release.

## [0.8.0] - 2026-11-04

### Added

- Choose which providers receive your signed transactions. A chain's `transactions: {providers: [provider_id], fallback: none}` block sends transactions only to those providers, and reads, subscriptions and block recovery use the others. Sending fails closed by default; `fallback: read_providers` adds an explicit second phase over the read providers. See [configuration](docs/CONFIGURATION.md#transaction-providers) and [routing](docs/ROUTING.md#transaction-providers).
- Opt-in metadata reports `send_policy` on sends, plus `execution_safety` and `classified_by` on every request. See the [API reference](docs/API_REFERENCE.md#observability-metadata).

### Changed

- Methods are classified by what they do, as reads, sends, subscriptions or other methods. See [execution classes](docs/RPC_STANDARDS.md#execution-classes).
- Relay-native submission methods, bundle methods and simulations of signed transactions are now sends. An unregistered method whose params carry a signed transaction is also a send and runs once, so a transaction policy keeps its bytes on the transaction providers.
- A learned method refusal now skips that upstream for the method while another candidate remains, and methods outside the registry learn sooner. The final candidate is always kept, and a provider override bypasses learned refusals.
- `mix lasso.probe` reports every transaction submission method as unverifiable.

### Security

- Update Ecto to 3.14.3 to address the query-cache memory exhaustion advisory (EEF-CVE-2026-118391).

### Compatibility

- Profiles without a `transactions` block keep ordinary routing for `eth_sendRawTransaction`.
- `execution_safety` now has four values: `replay_safe`, `raw_transaction_broadcast`, `subscription` and `unknown`. Update anything that matches on the removed values.

## [0.7.1] - 2026-10-30

### Security

- Update Phoenix HTML to 4.4.0 and ssl_verify_fun to 1.1.8 to address attribute-injection (CVE-2026-117645) and TLS hostname-verification (CVE-2026-117666) advisories.

### Changed

- The three `LASSO_PROVIDER_KNOWLEDGE_*_MODE` variables accept `on`/`off`, `true`/`false` and `1`/`0` in any case. Other values still fail startup.
- Startup logs a warning when `LW_BETA` is set, naming `BALANCED_FAST_BETA` as its replacement. `LW_BETA` has not been read since v0.6.0.

### Documentation

- Complete the v0.7.0 compatibility notes: `eth_getLogs` range-limit failover and missing-block recovery are always on, and the YAML `null` validation note applies to profiles that never loaded on earlier releases.

## [0.7.0] - 2026-10-29

### Added

- Learned provider limits are on by default. When an upstream repeatedly refuses a method, lacks the history a request needs, or rejects an `eth_getLogs` range, Lasso learns that from live traffic and defers the upstream behind alternatives for matching requests. The upstream stays available as a last resort, and a learned limit expires or is withdrawn when the upstream later serves what it refused. Operator-declared capabilities always take precedence over learned limits. Turn each kind off independently with `LASSO_PROVIDER_KNOWLEDGE_METHOD_REFUSAL_MODE`, `LASSO_PROVIDER_KNOWLEDGE_HISTORICAL_DEPTH_MODE` or `LASSO_PROVIDER_KNOWLEDGE_SPAN_LIMIT_MODE` set to `off`. Learned state is local to each node and relearned after a restart. Opt-in request metadata, local diagnostics and `/metrics` series show deferrals that changed the order and limits withdrawn by a later success. See [routing](docs/ROUTING.md) and [configuration](docs/CONFIGURATION.md).

- `config/examples/chainstack.yml` profile template for Chainstack Global Nodes on Ethereum, Base, and Arbitrum. One `CHAINSTACK_MULTICHAIN_TOKEN` multichain auth token authorizes every chain. Chainstack is `priority: 1` with keyless public fallbacks on each chain; route through `/rpc/profile/chainstack/priority/:chain` to keep it primary. The template caps `eth_getLogs` at the Developer plan range and classifies Chainstack's disabled-tracer error so the request fails over to another provider when one supports it. See [provider templates](docs/CONFIGURATION.md#provider-templates).

### Compatibility

- Routing order can now change on its own: an upstream with a learned limit is tried after alternatives for matching requests. Set the three `LASSO_PROVIDER_KNOWLEDGE_*_MODE` variables to `off` to keep v0.6.0 ordering.
- An upstream's `eth_getLogs` range or result-size error now fails over to the remaining providers instead of returning immediately. The client receives the range error only when no provider serves the request. Each such request can make up to two extra upstream calls. Declare `capabilities.limits.max_block_range` on providers with known limits so Lasso skips them for larger ranges before dispatch. The learned-limit switches do not disable this.
- A `null` answer for a numeric block from `eth_getBlockByNumber`, `eth_getBlockReceipts` or `eth_getBlockTransactionCountByNumber`, or empty `eth_getLogs` from an upstream whose head is below `toBlock`, is retried once on another upstream with fresh evidence of that block. The client receives the alternate's answer, or the original if the alternate fails. The learned-limit switches do not disable this.
- Capability list fields must be lists. File profiles have rejected YAML `null` for `unsupported_methods`, `unsupported_categories` and `limits.block_age_methods` since v0.3.4, so profiles that load on earlier releases are unaffected; write `[]` for no declarations.
- No profile, publication-journal or benchmark-history migration.

## [0.6.0] - 2026-10-16

### Added

- Bounded selection and exhaustion diagnostics identify admission gates and precise internal failure causes while preserving caller-facing error categories. Prometheus selection labels are bounded, and sampled routing outcome counters are explicitly identified as diagnostics.
- `POST /rpc/priority/:chain` and `/rpc/profile/:profile/priority/:chain` route requests with the `priority` strategy. WebSocket clients can connect at `/ws/rpc/priority/:chain`, which previously resolved `priority` as the chain name.

### Changed

- Load-balanced selection gives each physical upstream one first-pick share and tries distinct upstreams before sibling transports for replay-safe reads, within the existing dispatch budget and availability tiers.
- The `latency-weighted` strategy is now `balanced-fast`, positioned between `load-balanced` and `fastest`. `latency-weighted` stays a permanent alias in HTTP and WebSocket URLs and the `strategy` query parameter, and routes identically. `lasso_meta.strategy` and request logs report `balanced_fast`, and the dashboard shows Balanced Fast. The module is `Lasso.RPC.Strategies.BalancedFast`, and its exponent is set with `BALANCED_FAST_BETA` (application key `:balanced_fast_beta`); `LW_BETA` is no longer read.
- `GET /api/ready` without parameters now reports replica readiness: configuration loaded, catalog published, and distribution running when clustering is configured. It no longer reflects upstream state, so a dead upstream no longer takes every replica out of service. `?profile=&chain=` keeps the strict upstream-backed check, and `?profile=` alone still checks every chain in that profile. The scoped check now counts half-open HTTP routes with recovery capacity as eligible, as routing admits them.

### Fixed

- Keep routing on the matching published catalog while replacement configuration is prepared. Batch profile warming publishes validated changes together, repairs missing workers without republishing unchanged profiles, and preserves the previous catalog and controls when a candidate fails.
- Account for retained JSON-RPC errors within response memory limits. Release superseded and abandoned payloads, and retain worker ownership until the recipient adopts a result. Linked-parent shutdown cancels execution before another upstream send.
- Fence physical quota feedback by breaker epoch and prevent stale responses from degrading replacement-generation learning.
- Render dashboard method statistics when duration samples are absent.
- Keep instance shutdown responsive during WebSocket handshakes and retain bounded, redacted close evidence for connection recovery diagnostics.
- Replay-safe reads can fail over explicit provider plan restrictions reported as invalid requests. Error classification retains nonserialized resolution provenance without changing the customer JSON-RPC shape.
- Prometheus scrapes use cached routing head evidence rather than waiting on a head owner.
- `balanced-fast` no longer fails a request when a provider's mean successful latency reads 0. Weighting treats a zero mean as unmeasured, as qualification already does.
- A request that ends unsuccessfully after every upstream it reached rejected the method returns that upstream's `-32601` with its message and data instead of `-32000`, unless a later candidate failed before dispatch, in which case the availability error is returned. A `-32601` mixed with another outcome, such as a provider failure, quota exhaustion, or timeout, no longer becomes the answer because it happened to come last; the caller receives the other outcome's error or the availability error. Retry behavior is unchanged: replay-safe reads continue to another upstream within their attempt budget, and unknown methods and `eth_sendRawTransaction` keep their single dispatch.
- Concurrent first observations of a request series share one `lasso_rpc_requests_total` row instead of splitting into duplicate samples. Route totals are documented as exact while their routing scope stays published.
- Exporter failures stay inside the exporter: a raising `MetricsScope` hook drops the observation and is counted, route-total reads keep their previous values, and telemetry handlers stay attached. Route totals count successes and errors separately, so neither moves backwards under concurrency, and are limited to 2,048 series per node.
- A `RELEASE_COOKIE` that starts with `+` or `-` is now used as the distribution cookie, prefixed with `lasso`. `erl` parsed such a value as a flag: a leading `+` stopped the node before boot with `bad -n option`, which hits about 1 in 64 random base64 cookies, and a leading `-` was dropped, so the node used `~/.erlang.cookie` and could not cluster with nodes on other hosts. Release commands print a warning, and nodes and operator commands that share the configured value still agree.

### Security

- Update Decimal to 3.1.2 to address its rounding allocation advisory.

### Compatibility

- Rename `LW_BETA` to `BALANCED_FAST_BETA` (application key `:balanced_fast_beta`). The old optional tuning variable is no longer read.
- Existing `latency-weighted` HTTP/WebSocket URLs and `strategy` values keep working as permanent aliases of `balanced-fast`; response metadata and logs report `balanced_fast`.
- `/api/ready` without parameters now reports replica readiness. Load balancers that relied on upstream-backed readiness should use `/api/ready?profile=PROFILE&chain=CHAIN` for their route.
- No required YAML profile schema, publication-journal migration, or benchmark-history migration. Preserve configured profiles, secrets, journal data and history when replacing containers. After global publication enrollment, rollback still requires a compatible binary or the documented coordinated disable procedure.
- Signed raw transactions retain one upstream dispatch; no automatic resend is introduced. Client authentication remains the operator's reverse-proxy/network responsibility.

## [0.5.1] - 2026-10-06

### Added

- Expand `/metrics` into a bounded operator contract with conventional names for routed latency, non-success upstream attempts, failovers, circuit admission, WebSocket and subscription continuity, stream memory, credential health and BEAM runtime, plus a Grafana dashboard (`docs/grafana/lasso-core-v1.json`).
- Add opt-in OpenTelemetry tracing with W3C trace context propagation and JSON-log trace correlation. Tracing is disabled by default and never affects routing results.
- Export exact per-route request totals (`lasso_rpc_route_requests_total`, `lasso_rpc_route_duration_seconds_total`, `lasso_rpc_route_detail_sampled_out_total`) read from the request aggregate counters, so throughput and success ratios no longer depend on sampled diagnostics.
- Add `Lasso.Observability.MetricsScope` so multi-tenant hosts can bound profile, chain and provider label values and choose which routes the scrape-time families cover.

### Changed

- `lasso_provider_head_lag_blocks` reports routing's own per-transport assessment against each route's routing plan and gains a `transport` label. Transports routing cannot assess have no sample.
- `lasso_upstream_attempts_total` gains `profile` and `origin` labels, separating client-driven upstream failures from probes and other system traffic.
- Request aggregate counters persist across catalog rebuilds while their routing scope stays published.

### Fixed

- Restore provider eligibility when a 429 rate-limit cooldown expires. Preserve monotonic deadlines even when their values are negative; v0.5.0 could leave a provider rate-limited until restart after its first 429. Anyone whose providers return 429 should upgrade; restarting only masks the issue.
- Record successful upstream execution before a terminal head-policy rejection, preserving accurate provider health and attempt diagnostics.

### Compatibility

- No required profile schema or publication-journal migration. Retain existing journals and follow the documented replacement procedure for enrolled global deployments.
- This patch includes the additive observability features listed above. OpenTelemetry remains opt-in and disabled by default.
- Prometheus consumers should review the new metric families and the added `transport`, `profile`, and `origin` labels described above.

## [0.5.0] - 2026-09-28

### Added

- Add a route-readiness endpoint, node-local Prometheus metrics, JSON console logging, safe `check-config` and `reload` release commands, and authenticated Caddy/nginx deployment examples. Health still means process health; readiness and an upstream-backed RPC call provide separate evidence.
- Expose profile-scoped, transport-qualified head observations and routing decisions. Bounded method-family evidence and opt-in exploration help select an eligible upstream without changing JSON-RPC request shapes.
- Add a standalone provider discovery CLI with bounded method, limit, archive, and WebSocket probes. Quiet subscriptions are reported as accepted rather than proven supported; malformed responses and mismatched chain identities do not establish capability evidence.
- Extend native AMD64 and ARM64 container acceptance to exercise operator endpoints, proxy configuration, reload, and optional publication-journal continuity.

### Changed

- Bound HTTP response retention, upstream dispatch, WebSocket frame/event ingress, subscription recovery buffers, and retry backfill within existing request and continuity budgets. Release response capacity when a successful upstream response is rejected or abandoned.
- Discard an HTTP/1 checkout after a receive timeout so an unfinished response cannot be reused by a later request. This adds a lightweight linked task around each bounded HTTP dispatch while Finch's upstream timeout behavior remains unresolved.
- Carry Finch send observations across that checkout task so proven predispatch failures remain retryable, while started or confirmed sends cannot be mislabeled safe to replay.
- Recover stale or restarted WebSocket subscriptions through the continuity coordinator and bounded replay outside the per-chain pool, keeping other subscription keys responsive while an upstream subscribe stalls.
- Preserve distinct provider opportunities during replay-safe fallback, qualify head and archive evidence before routing, and retain final upstream error attribution. An oversized `eth_getLogs` range now returns a range-actionable error where the upstream identifies that constraint.
- Surface sustained upstream credential failures in sanitized operator diagnostics. Reconcile provider removal and supervisor recovery without publishing stale channels, and keep WebSocket recovery tied to the current connection and configured replay horizon.

### Security

- Upgrade Mint to 1.11.0 and HPAX to 1.1.0 for the newly published HTTP framing and HTTP/2 fixes. Keep operator ingress authentication, request limits, and TLS at the network or reverse-proxy boundary; Core does not supply client identity or billing.

### Compatibility

- No required profile schema or publication-journal migration. Existing `off`, `local`, and optional `global` continuity modes remain; keep the existing journal and use the documented coordinated replacement procedure for enrolled global deployments.
- Stricter JSON-RPC envelope, method-parameter, provider-capability, and discovery-response validation can reject malformed inputs that earlier versions forwarded or treated as evidence. Check custom profiles with `check-config` before reloading; a rejected reload retains the active configuration.
- Prometheus counters and readiness are local to each node. Head observations are bounded evidence, not finality or proof of arbitrary RPC execution. Provider quotas, archive depth, subscription recovery, and sustained workload capacity still require qualification against the operator's upstreams.

## [0.4.5] - 2026-09-23

### Security

- Upgrade Phoenix to 1.8.14, Cowboy to 2.19.0, Cowlib to 2.20.0, and Ranch to 2.3.0. Cowlib 2.20.0 resolves `CVE-2026-43971`; the two remaining acknowledged Cowlib advisories affect encoder paths Lasso does not call.

### Fixed

- Correct Public Arbitrum archive routing: thirdweb and Blast now serve historical state reads. dRPC, PublicNode, Tenderly, and Nodies remain available for recent traffic but no longer claim historical-state support.
- Keep pinned numeric reads eligible when no fresh head is available to establish their age. Once age is known, requests beyond the configured threshold still require an archival provider.
- Return structured, non-retriable admission errors when a request requires archival support or a transport that no configured provider supplies, without recording an upstream attempt. Explicit invalid-argument evidence also takes precedence over incidental provider, authentication, throttling, or retry wording in the request error.

### Documentation and project operations

- Correct the load-balanced routing summaries to describe bounded distinct-provider fallback for replay-safe reads, while keeping health tiers, recovered-head preference, dispatch limits, and provider capacity constraints explicit.
- Add a provider-neutral migration and canary guide, support and maintainer policies, ownership rules, and structured issue and pull request templates.

### Compatibility

- No configuration or journal migration is required. Retry budgets and method-safety dispatch limits are unchanged.
- Unknown block age no longer establishes an archival requirement for numeric selectors. Requests can reach eligible providers within the normal execution budget; provider responses still drive ordinary failover. Known-old requests retain archival admission.
- EIP-1898 state reads selected by block hash now require an archival provider, because their age cannot be established before dispatch. A chain with no archival provider rejects them at admission.
- The bundled Public Arbitrum provider set changes. Operators with local profile overrides retain their configured routes and should review archival declarations against historical state reads, not header availability alone.
- Lasso OSS continues to require authentication and inbound rate limiting at the operator's ingress boundary.

## [0.4.4] - 2026-09-20

### Fixed

- Give distinct physical provider instances a first pass within each availability tier for load-balanced replay-safe unary fallback, before alternate HTTP/WebSocket routes consume the attempt budget. Alternate transports remain available, and lazy and eager selection follow the same tier ordering.

### Documentation

- Clarify the existing latency-weighted fallback: recent latency measurements receive weighted ordering before shuffled unmeasured routes when no candidate qualifies.

### Compatibility

- No configuration or journal migration is required. The three-dispatch replay-safe budget, original request deadline, candidate admission limits, and existing dispatch rules for transactions, stateful methods, and unknown methods are unchanged.
- Health tiers and explicit recovered-head preference retain precedence. Healthy-sibling deferral is bounded by the cursor's remaining candidate limit; other routing strategies retain their existing behavior.
- Trying another provider first can delay a working alternate transport. A hash selector can still leave more distinct providers eligible than the dispatch budget covers. Historical state availability remains provider-dependent; this release does not certify archive workload coverage or provider capacity.

## [0.4.3] - 2026-09-20

### Fixed

- Reject HTTP dispatch to a physical provider endpoint after a malformed or mismatched `eth_chainId` probe. A later matching probe restores admission; ordinary request successes cannot clear the rejection. Probe results are fenced by configuration generation and observation order, and unrelated configuration reloads retain the rejection.
- Drain buffered orphan log additions and removals in their original per-log order before replacement-block additions during WebSocket recovery, including replacements at different block heights.
- Remove URL user information, paths, queries and fragments from provider diagnostics and catalog endpoint projections. Diagnostic origins still contain the scheme, host and port.
- Update Mint to 1.10.1.

### Documentation and maintenance

- Clarify local/global block protection, hash-pinned state reads, routing metadata, and the boundary between self-hosted Core and hosted Lasso Cloud.
- Document the default mock-backed test suite and the separate PostgreSQL/Anvil integration checks; remove an unused failover policy module.

### Compatibility

- No configuration or journal migration is required. Retain the existing journal and follow the documented replacement procedure for global continuity deployments.
- Unknown HTTP identity keeps normal admission until a probe provides evidence. The guard does not infer WebSocket identity from an HTTP endpoint or attest arbitrary provider responses.
- Core deduplicates positive and removed logs separately. Repeated removal and re-addition of the same log within the deduplication window is not fully modeled; this release does not guarantee recovery through every repeated reorg sequence.
- Historical state availability and provider capacity remain provider-dependent. These fixes do not qualify hosted Public or Premium profiles for archive workloads.

## [0.4.2] - 2026-09-11

### Changed

- Local block continuity captures the mandatory floor once per request and atomically retains the greatest accepted height. Sequential nonoverlapping requests within one application generation remain nondecreasing; overlapping responses can complete out of height order.
- Connected BEAM instances exchange accepted-height hints through bounded background work. Hints prefer suitable providers without raising the local admission floor or removing valid fallbacks. Local mode requires no publication database or peer acknowledgment. Recovery after an application restart or node switch is best effort, with no promised time or block-gap bound.
- Provider preference uses transport observations with the captured route's freshness settings. Existing health, capability, explicit override and fallback-group rules retain precedence; a stalled preferred provider leaves time for a valid fallback within the existing request deadline.

### Fixed

- Propagate committed publication snapshots between runtimes and retry stale closure acknowledgments from already received revisions, avoiding extra journal reads at cutover. Preserve periodic recovery, boot checks, durable closure, and the invalidation topic used by older runtimes; no schema or configuration changes are required.

- Reconcile journal inventory in one supervised background task, allowing committed updates to proceed while a read is slow. Stale inventory results cannot regress a newer publication; cold bootstrap still requires a successful inventory.

- Avoid serialized journal transactions for locally ineligible block proposals and unchanged readiness evidence. Provider checks continue so anchor, provider, floor and freshness changes can still drive publication; observation timestamps alone no longer repeat readiness writes. No configuration or journal migration is required.

### Compatibility

- Existing `off`, `local` and `global` configuration values remain valid. Global retains its durable coordinated contract and journal/membership requirements. Explicit number/hash state reads retain their targets. Local floors and hints are volatile application state; losing all copies loses that history.
- Local choices still require an eligible provider response and can fail when a provider regresses and every fallback is unavailable or quota-limited. This release does not add a retained-response cache or certify any customer's provider capacity.

## [0.4.1] - 2026-09-10

### Fixed

- Acknowledge closed publication gates concurrently across scopes, with at most four acknowledgment tasks independent of provider probes. Cross-region database latency no longer accumulates serially across all closing scopes. Gates still require durable acknowledgment before a newer publication can open; request deadlines and selectors are unchanged.

- Supervise the coordinator and its background tasks together, so a coordinator crash stops blocked tasks before replacement work starts.

### Compatibility

- No configuration or journal migration changes. Upgrade from v0.4.0 using the existing graceful replacement procedure and retain acknowledged history. Binaries predating global publication remain unsafe after enrollment.

## [0.4.0] - 2026-09-10

### Added

- Opt-in `global` block continuity: profile/chain block choices use a durable fleet publication, with local serving grants and no per-request PostgreSQL lookup. Repeated heights are allowed; stale or unavailable publication returns an error.
- Optional PostgreSQL journal, explicit install/upgrade command, and release-console operations for membership, graceful replacement and retained-floor recovery. Ordinary `off` and instance-only `local` deployments require no database server.
- Standard hash-pinned logical-read guide and executable viem/SEL/Multicall/worker example, including query deadlines, bounded routing evidence and whole-query reorg recovery.
- Browser-readable profile, request and routing metadata for local and upstream responses.

### Compatibility

- The policy covers `eth_blockNumber` and `eth_getBlockByNumber("latest", ...)`. State reads retain their original number/hash/tag; applications propagate one hash through the complete logical request.
- Global deployments must retain one journal and a complete, explicitly managed instance roster. Do not delete or restore older journal history while serving the same protected profile identities. See the publication operations guide before enabling or rolling back.
- Provider-observed canonicality is not finality or proof of arbitrary `eth_call` execution. One provider is supported without provider redundancy.


## [0.3.6] - 2026-09-08

### Fixed

- Restore the routing catalog automatically after its owner restarts. Failed recovery publications discard their unfinished tables and retry without requiring a configuration reload.

## [0.3.5] - 2026-09-07

### Fixed

- New profiles can subscribe through shared WebSocket upstreams after configuration reload without restarting the node. Routing eligibility reads the physical connection state instead of requiring a pre-existing profile channel cache entry.
- Exclude disconnected WebSocket upstreams even when profile channel caches still contain their wrappers; publish connected state before notifying consumers.
- Container acceptance checks cover subscription acknowledgment, block delivery, and unsubscribe for newly reloaded profiles sharing existing connections.

### Compatibility

- No YAML schema or storage migration. Distribute and reload profile files on each node; environment and mount changes still require recreation. Existing v0.3.4 installations should retain the restart workaround until upgraded.

### Distribution

- Publish versioned AMD64/ARM64 container images with anonymous installation checks, build provenance, SBOMs, and signed publication attestations.
- Attach a standalone Compose recipe and native verification reports to each container release; document installation, custom profiles, image pinning, migration, and rollback.
- Pass an optional local `.env` file into source-built Compose containers so provider credentials reach the running application.

## [0.3.4] - 2026-09-07

### Compatibility

- Configuration validation now rejects unsupported settings that were previously ignored. Check custom profiles against `docs/CONFIGURATION.md` before upgrading; the bundled profiles use the supported schema. A rejected reload retains the active configuration.

### Configuration and operator controls

- Reject unsupported YAML fields, invalid values, duplicate provider IDs, and unresolved credentials before activation; retain the active configuration on a failed reload or missing public profile.
- Honor profile WebSocket backfill limits and application circuit-breaker thresholds. Read the documented `LW_BETA` setting.
- Clamp request tester rates across profile changes and distinguish HTTP strategy selection from priority-based subscriptions.
- Correct obsolete provider capability settings in the example profiles. Remove unused configuration facades, controls, and logging claims; document the supported routing and observability contracts.

### Changed

- Run Docker containers as UID/GID 10001 with a smaller runtime image, an image health check, and OCI source/license metadata
- Add a Compose deployment with persistent profiles/history, a read-only root filesystem, and upgrade guidance

### Fixed

- Load the profiles seeded under `LASSO_DATA_DIR` and allow explicit runtime profile/history directories
- Resolve benchmark snapshot storage when the collector starts instead of when the code is compiled
- Use local HTTP URLs and persistent storage in the Docker helper
- Stop and clear request tester runs when switching between profiles, including profiles with identical chain lists
- Keep the profile selector accessible above floating dashboard panels

## [0.3.3] - 2026-09-07

### Changed

- Made setup, deployment, configuration, and contributor documentation self-contained
- Removed unused profile-downgrade and crawler-preview plugs, unreachable editing forms, and unused landing-page assets
- Removed private lint extensions, unrelated vendor tooling, and obsolete planning documents

### Fixed

- Derived metrics API success rates, latency samples, and provider counts from actual local measurements; unavailable counters return `null`
- Included the dashboard favicon in Docker builds
- Corrected asset-build prerequisites, provider-credential examples, VM metrics defaults, and test commands
- Clarified dashboard access controls and removed unsupported performance estimates

## [0.3.2] - 2026-09-07

### Changed

- Refreshed the self-hosted dashboard with shared topology styling, chain logos, touch/pinch navigation, responsive details, and an HTTP/WebSocket request tester
- Documented file-based profile management and configuration reloads
- Made provider status reflect transport availability and observation freshness; unavailable measurements display as unknown

### Fixed

- Updated Mint to 1.10.0 to address the September 2026 security advisories
- Preserved upstream JSON-RPC error codes and data, refined quota/revert classification, and handled HTTP error bodies consistently
- Recognized method-specific block selectors without misclassifying transaction hashes as historical block requests
- Removed credential-bearing paths and query strings from displayed provider endpoints
- Preserved final request-tester outcomes when stopping and counted JSON-RPC errors returned with HTTP 200 as errors
- Loaded metrics from bulk cache completion and rejected stale results after profile switches
- Guarded invalid dashboard tabs and chain identifiers, empty-profile metrics, and tester profile changes
- Stabilized WebSocket recovery tests by waiting for the recovery transition

### Documentation

- Documented YAML profile reloads and clarified that tester rate settings do not enforce client quotas

## [0.3.1] - 2026-09-04

### Fixed

- Time-aligned fast-chain consensus using bounded HTTP observation credit while preserving WebSocket heads as direct evidence
- Rejected stale block observations from provider lag decisions instead of manufacturing current synchronization state
- Stored each worker's effective freshness and polling cadence with block-height observations so routing and dashboard status share one contract

## [0.3.0] - 2026-08-28

### Added

- Bounded request execution with explicit ownership, deadlines, byte budgets, terminal facts, and projection lanes for HTTP and WebSocket traffic
- Precompiled routing plans, candidate cursors, and bounded routing evidence used by every public selection strategy
- Generation-bound transport dispatch and strict upstream JSON-RPC response validation
- A validated Mint WebSocket client that resolves each configured origin once, pins the connection to that address set, and preserves the original HTTP and TLS authority
- Cluster-aware circuit-breaker admission, recovery control, and transport diagnostics

### Changed

- Upgraded the release runtime to Erlang/OTP 28 and the routing stack to Phoenix 1.8 and Finch 0.23
- Reworked provider selection to defer cold evidence, reuse immutable routing state, and avoid unnecessary materialization on the request path
- Strengthened WebSocket subscription ownership, reconnection, gap-fill bounds, and stale-generation handling
- Aggregated request and dashboard diagnostics through bounded local projection lanes
- Kept self-hosted localhost and private-network providers supported while pinning each WebSocket connection to its resolved address set

### Fixed

- Applied provider-specific error rules consistently to live HTTP and WebSocket transports
- Preserved provider metadata on WebSocket errors and classified structural execution evidence before ambiguous provider messages
- Prevented stale or cancelled transport attempts from being accepted after their request owner or connection generation changed
- Made provider capability reads safe when configuration fields are absent
- Corrected dashboard routing counters, provider details, and cluster-wide activity reconciliation
- Hardened response-size admission, batch accounting, circuit recovery races, and WebSocket continuity cleanup

## [0.2.0] - 2026-08-05

### Fixed

- Updated Cowboy to 2.18.0 and Cowlib to 2.19.0 to remediate the HTTP header parsing and HPACK/QPACK memory-exhaustion advisories reported by `mix hex.audit`
- `run-docker.sh` now provides the production-required `LASSO_NODE_ID` for local Docker runs, preventing a startup failure on a clean checkout
- Added standard `mix assets.setup`, `mix assets.build`, and `mix assets.deploy` aliases so local and release asset builds use the same commands

- `/api/health` no longer returns 500 on single-node deployments (missing `regions` field on cluster topology)
- Invalid provider override (e.g. `/rpc/provider/nonexistent/ethereum`) now returns a clean `-32602 "Provider not found"` error instead of a misleading "All circuits open" exhaustion message
- WebSocket connections to unknown profiles (`/ws/rpc/profile/zzz/...`) and unknown provider overrides (`/ws/rpc/provider/ghost/...`) are now rejected at handshake; previously they silently fell back to default routing and returned subscription IDs that never delivered events

### Documentation

- Aligned public setup, API, deployment, configuration, and architecture docs with the canonical `public` profile, current routes, and the OSS authentication model

### Changed

- Lasso RPC is now licensed under Apache-2.0 to support broader self-hosting, distribution, and commercial embedding
- Profiles are now loaded exclusively from YAML files in `config/profiles/`; profile slugs are opaque routing IDs, chain aliases resolve to positive integer EIP-155 IDs internally, and `default` remains an alias for `public`
- Configuration reloads publish a complete new snapshot only after validation; malformed YAML or invalid chain IDs leave the last known-good snapshot active. A cold restart loads profiles from disk before routing begins
- Dashboard and RPC routes accept both configured chain aliases and decimal chain IDs, while WebSocket startup attempts are jittered to avoid synchronized upstream handshakes
- Default profile (`config/profiles/default.yml`) removed in favor of the canonical `public` profile; existing `default` slug requests still work via the alias system, eliminating the `Duplicate chain IDs detected across profiles` startup warning
- `public` profile pruned of broken provider configurations: removed dead WebSocket URLs from LlamaRPC (Ethereum and Base), removed unreachable `arbitrum_meowrpc` (TLS failure), removed `base_sepolia_onfinality` (returns 401 Unauthorized)
- Removed undefined optional lint-check warnings
- Hardcoded `"default"` string fallbacks across controllers, plugs, and dashboard components replaced with `Lasso.Config.ProfileValidator.default_profile/0` to remove a class of single-source-of-truth drift bugs
- `HealthController` topology logic extracted to `Lasso.Cluster.HealthTopology` and shared with the cloud variant so the OSS/cloud controllers can no longer drift independently
- Several integration tests strengthened from `assert error != nil` to assert the specific `JSONRPC.Error` shape, code, and category — closes a regression channel that had previously masked a bug fix being lost during sync

## [0.1.0] - 2026-01-06

### Added

- Multi-provider, multi-chain Ethereum JSON-RPC proxy for HTTP and WebSocket
- Intelligent routing strategies: fastest, load-balanced, latency-weighted
- Per-method, per-transport latency benchmarking
- Profile system for isolated routing configurations (dev/staging/prod/multi-tenant)
- Circuit breakers with per-provider, per-transport state
- WebSocket subscription multiplexing with gap-filling on provider failover
- LiveView real-time dashboard with:
  - Provider health monitoring
  - Routing decision breakdowns
  - Per-method latency metrics
  - Issue logs and circuit breaker state
  - RPC load testing interface
- Transport-aware failover and retry logic
- Configurable rate limiting per profile
- OpenTelemetry integration for observability
- Support for Ethereum, Base, and extensible to other EVM chains
- Pre-configured public provider support (LlamaRPC, PublicNode, DRPC, etc.)

### Documentation

- Comprehensive README with quick start guide
- Architecture documentation (ARCHITECTURE.md)
- Testing guide (TESTING.md)
- Observability setup (OBSERVABILITY.md)
- RPC standards compliance (RPC_STANDARDS.md)
- Contributing guidelines (CONTRIBUTING.md)
- Security policy (SECURITY.md)

### Infrastructure

- Docker support with multi-stage builds
- GitHub Actions CI pipeline (test, lint, type-check)
- Credo and Dialyzer static analysis
- Comprehensive test suite (unit + integration)

[Unreleased]: https://github.com/jaxernst/lasso-rpc/compare/v0.10.0...HEAD
[0.10.0]: https://github.com/jaxernst/lasso-rpc/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/jaxernst/lasso-rpc/compare/v0.8.6...v0.9.0
[0.8.6]: https://github.com/jaxernst/lasso-rpc/compare/v0.8.5...v0.8.6
[0.8.5]: https://github.com/jaxernst/lasso-rpc/compare/v0.8.4...v0.8.5
[0.8.4]: https://github.com/jaxernst/lasso-rpc/compare/v0.8.3...v0.8.4
[0.8.3]: https://github.com/jaxernst/lasso-rpc/compare/v0.8.2...v0.8.3
[0.8.2]: https://github.com/jaxernst/lasso-rpc/compare/v0.8.1...v0.8.2
[0.8.1]: https://github.com/jaxernst/lasso-rpc/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/jaxernst/lasso-rpc/compare/v0.7.1...v0.8.0
[0.7.1]: https://github.com/jaxernst/lasso-rpc/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/jaxernst/lasso-rpc/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/jaxernst/lasso-rpc/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/jaxernst/lasso-rpc/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/jaxernst/lasso-rpc/compare/v0.4.5...v0.5.0
[0.4.5]: https://github.com/jaxernst/lasso-rpc/compare/v0.4.4...v0.4.5
[0.4.4]: https://github.com/jaxernst/lasso-rpc/compare/v0.4.3...v0.4.4
[0.4.3]: https://github.com/jaxernst/lasso-rpc/compare/v0.4.2...v0.4.3
[0.4.2]: https://github.com/jaxernst/lasso-rpc/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/jaxernst/lasso-rpc/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/jaxernst/lasso-rpc/compare/v0.3.6...v0.4.0
[0.3.6]: https://github.com/jaxernst/lasso-rpc/compare/v0.3.5...v0.3.6
[0.3.5]: https://github.com/jaxernst/lasso-rpc/compare/v0.3.4...v0.3.5
[0.3.4]: https://github.com/jaxernst/lasso-rpc/compare/v0.3.3...v0.3.4
[0.3.3]: https://github.com/jaxernst/lasso-rpc/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/jaxernst/lasso-rpc/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/jaxernst/lasso-rpc/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/jaxernst/lasso-rpc/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/jaxernst/lasso-rpc/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/jaxernst/lasso-rpc/releases/tag/v0.1.0
