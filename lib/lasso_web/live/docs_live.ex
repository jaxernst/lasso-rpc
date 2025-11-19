defmodule LassoWeb.DocsLive do
  use LassoWeb, :live_view
  alias LassoWeb.Components.DashboardHeader

  @impl true
  def mount(_params, _session, socket) do
    socket = assign(socket, :active_tab, "docs")
    {:ok, socket}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => _tab}, socket) do
    # Navigate back to dashboard when switching to other tabs
    {:noreply, push_navigate(socket, to: "/")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-full w-full flex-col">
      <DashboardHeader.header active_tab={@active_tab} />
      
    <!-- Content Section for landing page (no grid so it blends with header) -->
      <div class="relative flex-1 overflow-y-auto">
        <div class="relative mx-auto flex max-w-6xl flex-col gap-10 px-6 py-10 lg:py-12">
          <!-- Hero / Overview -->
          <section class="grid items-start gap-8 lg:grid-cols-[minmax(0,1.6fr)_minmax(0,1.2fr)]">
            <div class="space-y-6">
              <div class="border-purple-500/40 bg-purple-500/10 shadow-[0_0_25px_rgba(168,85,247,0.35)] inline-flex items-center gap-2 rounded-full border px-4 py-1.5 text-xs font-medium text-purple-300">
                <span class="relative flex h-2 w-2">
                  <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-purple-400 opacity-75">
                  </span>
                  <span class="relative inline-flex h-2 w-2 rounded-full bg-purple-400"></span>
                </span>
                Live multi-provider RPC routing · Ethereum & Base
              </div>

              <div class="space-y-3">
                <h1 class="text-balance text-3xl font-semibold tracking-tight text-white sm:text-4xl lg:text-5xl">
                  Programmable RPC routing for production-grade onchain apps.
                </h1>
                <p class="max-w-xl text-sm leading-relaxed text-gray-400 sm:text-base">
                  Lasso sits in front of your existing RPC providers and turns them into a
                  <span class="font-medium text-gray-200">
                    fault-tolerant, latency-aware, observable
                  </span>
                  RPC layer. No SDKs, no client rewrites—just smarter URLs.
                </p>
              </div>

              <div class="flex flex-wrap items-center gap-3">
                <a
                  href="/"
                  class="shadow-purple-500/40 inline-flex items-center gap-2 rounded-lg bg-gradient-to-r from-purple-600 to-purple-500 px-5 py-2.5 text-sm font-semibold text-white shadow-lg transition hover:shadow-purple-400/50"
                >
                  Open Live Dashboard
                  <svg class="h-4 w-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M13 7l5 5m0 0-5 5m5-5H6"
                    />
                  </svg>
                </a>
                <a
                  href="https://github.com/LazerTechnologies/lasso-rpc"
                  target="_blank"
                  rel="noopener noreferrer"
                  class="border-gray-700/60 bg-gray-900/70 inline-flex items-center gap-2 rounded-lg border px-5 py-2.5 text-sm font-semibold text-gray-200 transition hover:border-gray-500/70 hover:bg-gray-900"
                >
                  <svg class="h-4 w-4" fill="currentColor" viewBox="0 0 24 24">
                    <path
                      fill-rule="evenodd"
                      clip-rule="evenodd"
                      d="M12 2C6.477 2 2 6.477 2 12c0 4.42 2.865 8.17 6.839 9.49.5.092.682-.217.682-.482 0-.237-.008-.866-.013-1.7-2.782.603-3.369-1.34-3.369-1.34-.454-1.156-1.11-1.463-1.11-1.463-.908-.62.069-.608.069-.608 1.003.07 1.531 1.03 1.531 1.03.892 1.529 2.341 1.087 2.91.831.092-.646.35-1.086.636-1.336-2.22-.253-4.555-1.11-4.555-4.943 0-1.091.39-1.984 1.029-2.683-.103-.253-.446-1.27.098-2.647 0 0 .84-.269 2.75 1.025A9.578 9.578 0 0112 6.836c.85.004 1.705.114 2.504.336 1.909-1.294 2.747-1.025 2.747-1.025.546 1.377.203 2.394.1 2.647.64.699 1.028 1.592 1.028 2.683 0 3.842-2.339 4.687-4.566 4.935.359.309.678.919.678 1.852 0 1.336-.012 2.415-.012 2.743 0 .267.18.578.688.48C19.138 20.167 22 16.418 22 12c0-5.523-4.477-10-10-10z"
                    />
                  </svg>
                  View on GitHub
                </a>
                <span class="text-xs text-gray-500">
                  HTTP + WebSocket · JSON-RPC compatible · Read-only methods
                </span>
              </div>

              <div class="grid gap-3 text-xs text-gray-400 sm:grid-cols-3">
                <div class="border-gray-800/60 bg-gray-900/60 rounded-lg border px-3 py-2">
                  <div class="text-[11px] uppercase tracking-wide text-gray-500">Routing</div>
                  <div class="mt-1 text-sm font-medium text-gray-100">
                    `fastest`, `round-robin`, `latency-weighted`, provider override
                  </div>
                </div>
                <div class="border-gray-800/60 bg-gray-900/60 rounded-lg border px-3 py-2">
                  <div class="text-[11px] uppercase tracking-wide text-gray-500">Health</div>
                  <div class="mt-1 text-sm font-medium text-emerald-300">
                    Per-provider circuit breakers &amp; rate-limit aware failover
                  </div>
                </div>
                <div class="border-gray-800/60 bg-gray-900/60 rounded-lg border px-3 py-2">
                  <div class="text-[11px] uppercase tracking-wide text-gray-500">Insights</div>
                  <div class="mt-1 text-sm font-medium text-sky-300">
                    Live dashboard, method-level metrics, unified event stream
                  </div>
                </div>
              </div>
            </div>
            
    <!-- Dashboard-style callout -->
            <div class="border-purple-500/30 from-purple-500/10 via-purple-900/20 to-gray-950/90 shadow-[0_0_40px_rgba(168,85,247,0.35)] rounded-2xl border bg-gradient-to-br p-5">
              <div class="mb-4 flex items-start gap-3">
                <div class="bg-purple-500/30 flex h-9 w-9 flex-shrink-0 items-center justify-center rounded-lg">
                  <svg
                    class="h-5 w-5 text-purple-100"
                    fill="none"
                    stroke="currentColor"
                    viewBox="0 0 24 24"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M9 19V9a2 2 0 012-2h2a2 2 0 012 2v10M5 19h14M5 13h2a2 2 0 002-2V7a2 2 0 012-2h2a2 2 0 012 2v4a2 2 0 002 2h2"
                    />
                  </svg>
                </div>
                <div class="space-y-1">
                  <h2 class="text-sm font-semibold text-white">
                    Live provider leaderboard &amp; routing decisions
                  </h2>
                  <p class="text-purple-100/80 text-xs leading-relaxed">
                    The dashboard shows every provider, chain, and strategy in real time: latency percentiles,
                    success rates, circuit breaker status, and the exact provider chosen for each JSON-RPC call.
                  </p>
                </div>
              </div>

              <div class="border-purple-500/30 bg-black/40 space-y-3 rounded-xl border p-3">
                <div class="text-[11px] flex items-center justify-between text-gray-400">
                  <span class="uppercase tracking-wide text-gray-500">Recent routing decisions</span>
                  <span class="bg-emerald-500/20 text-[10px] inline-flex items-center gap-1 rounded-full px-2 py-0.5 font-medium text-emerald-300">
                    ● streaming
                  </span>
                </div>
                <div class="text-[11px] font-mono space-y-1.5 text-gray-300">
                  <div class="bg-gray-900/70 flex items-center justify-between gap-2 rounded-md px-2 py-1.5">
                    <span class="truncate text-sky-300">eth_blockNumber</span>
                    <span class="text-gray-500">→</span>
                    <span class="truncate text-emerald-300">ethereum_llamarpc</span>
                    <span class="text-yellow-300">31ms</span>
                  </div>
                  <div class="bg-gray-900/70 flex items-center justify-between gap-2 rounded-md px-2 py-1.5">
                    <span class="truncate text-sky-300">eth_getLogs</span>
                    <span class="text-gray-500">→</span>
                    <span class="truncate text-emerald-300">ethereum_merkle</span>
                    <span class="text-yellow-300">72ms</span>
                  </div>
                  <div class="bg-gray-900/70 flex items-center justify-between gap-2 rounded-md px-2 py-1.5">
                    <span class="truncate text-sky-300">eth_call</span>
                    <span class="text-gray-500">→</span>
                    <span class="truncate text-emerald-300">base_llamarpc</span>
                    <span class="text-yellow-300">45ms</span>
                  </div>
                </div>

                <a
                  href="/"
                  class="bg-purple-500/80 shadow-purple-500/40 inline-flex w-full items-center justify-center gap-2 rounded-lg px-3 py-2 text-xs font-semibold text-white shadow-lg transition hover:bg-purple-500"
                >
                  Inspect live traffic
                  <svg class="h-3.5 w-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M13 7l5 5m0 0-5 5m5-5H6"
                    />
                  </svg>
                </a>
              </div>
            </div>
          </section>
          
    <!-- Core value props (aligned with dashboard card style) -->
          <section class="space-y-4">
            <div class="flex flex-wrap items-center justify-between gap-3">
              <h2 class="text-lg font-semibold text-white sm:text-xl">What Lasso gives you</h2>
              <p class="max-w-xl text-xs text-gray-400 sm:text-sm">
                A single, programmable RPC entrypoint that understands providers, methods, transports, and
                health—so your app can stay fast and reliable while you add chains and traffic.
              </p>
            </div>

            <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
              <div class="border-gray-800/60 bg-gray-900/70 shadow-black/40 rounded-xl border p-4 shadow-sm">
                <div class="mb-2 flex items-center gap-2">
                  <span class="bg-purple-500/20 inline-flex h-7 w-7 items-center justify-center rounded-lg text-purple-300">
                    ⚡
                  </span>
                  <h3 class="text-sm font-semibold text-white">Strategy-aware routing</h3>
                </div>
                <p class="text-xs leading-relaxed text-gray-400">
                  Lasso continuously benchmarks providers per method and transport, then uses that data to drive
                  `:fastest`, `:round_robin`, `:latency_weighted`, and explicit provider overrides.
                </p>
              </div>

              <div class="border-gray-800/60 bg-gray-900/70 shadow-black/40 rounded-xl border p-4 shadow-sm">
                <div class="mb-2 flex items-center gap-2">
                  <span class="bg-emerald-500/15 inline-flex h-7 w-7 items-center justify-center rounded-lg text-emerald-300">
                    🛡️
                  </span>
                  <h3 class="text-sm font-semibold text-white">Per-provider circuit breakers</h3>
                </div>
                <p class="text-xs leading-relaxed text-gray-400">
                  Health and rate-limit aware breakers per provider + transport. Failures, 429s, and misconfigurations
                  are contained automatically, with half-open probing before full recovery.
                </p>
              </div>

              <div class="border-gray-800/60 bg-gray-900/70 shadow-black/40 rounded-xl border p-4 shadow-sm">
                <div class="mb-2 flex items-center gap-2">
                  <span class="bg-sky-500/20 inline-flex h-7 w-7 items-center justify-center rounded-lg text-sky-300">
                    📡
                  </span>
                  <h3 class="text-sm font-semibold text-white">
                    WebSocket multiplexing &amp; gap-filling
                  </h3>
                </div>
                <p class="text-xs leading-relaxed text-gray-400">
                  Subscriptions are multiplexed through a small number of upstream WS connections with automatic
                  failover and HTTP backfill, so you can scale listeners without melting providers.
                </p>
              </div>

              <div class="border-gray-800/60 bg-gray-900/70 shadow-black/40 rounded-xl border p-4 shadow-sm">
                <div class="mb-2 flex items-center gap-2">
                  <span class="bg-orange-500/20 inline-flex h-7 w-7 items-center justify-center rounded-lg text-orange-300">
                    🧠
                  </span>
                  <h3 class="text-sm font-semibold text-white">Aggregated method super set</h3>
                </div>
                <p class="text-xs leading-relaxed text-gray-400">
                  Provider adapters and capability checks let Lasso expose a larger, normalized method surface than
                  any single upstream, while avoiding providers that can’t serve a given call.
                </p>
              </div>

              <div class="border-gray-800/60 bg-gray-900/70 shadow-black/40 rounded-xl border p-4 shadow-sm">
                <div class="mb-2 flex items-center gap-2">
                  <span class="bg-indigo-500/20 inline-flex h-7 w-7 items-center justify-center rounded-lg text-indigo-300">
                    🔍
                  </span>
                  <h3 class="text-sm font-semibold text-white">Deep observability</h3>
                </div>
                <p class="text-xs leading-relaxed text-gray-400">
                  Structured telemetry, per-method percentiles, routing histories, and optional client-visible metadata
                  (`include_meta`) give you real answers for “which provider is slow?”.
                </p>
              </div>

              <div class="border-gray-800/60 bg-gray-900/70 shadow-black/40 rounded-xl border p-4 shadow-sm">
                <div class="mb-2 flex items-center gap-2">
                  <span class="bg-gray-500/20 inline-flex h-7 w-7 items-center justify-center rounded-lg text-gray-200">
                    🧱
                  </span>
                  <h3 class="text-sm font-semibold text-white">Elixir/OTP reliability</h3>
                </div>
                <p class="text-xs leading-relaxed text-gray-400">
                  Built on the BEAM VM with supervision trees, ETS, and telemetry. Designed for long-running,
                  highly concurrent RPC workloads where failure isolation actually matters.
                </p>
              </div>
            </div>
          </section>
          
    <!-- Routing strategies & URLs -->
          <section class="space-y-4">
            <div class="flex flex-wrap items-center justify-between gap-3">
              <h2 class="text-lg font-semibold text-white sm:text-xl">
                Routing strategies &amp; URLs
              </h2>
              <p class="max-w-xl text-xs text-gray-400 sm:text-sm">
                Swap a single slug in your URL to change how Lasso selects providers. All strategies work for both
                HTTP (POST) and WebSocket connections.
              </p>
            </div>

            <div class="grid gap-4 md:grid-cols-[minmax(0,1.4fr)_minmax(0,1.1fr)]">
              <div class="border-gray-800/70 bg-gray-950/80 space-y-3 rounded-xl border p-4">
                <div class="text-[11px] mb-2 font-medium uppercase tracking-wide text-gray-500">
                  HTTP entrypoints (Ethereum)
                </div>
                <div class="font-mono space-y-2 text-xs text-gray-200">
                  <div class="border-gray-800/70 bg-black/60 rounded-lg border px-3 py-2.5">
                    <div class="text-[11px] mb-1 flex items-center justify-between text-gray-500">
                      <span>`fastest` (per-method benchmarked)</span>
                      <span class="text-emerald-300">recommended</span>
                    </div>
                    <div>https://lasso-rpc.fly.dev/rpc/fastest/ethereum</div>
                  </div>
                  <div class="border-gray-800/70 bg-black/60 rounded-lg border px-3 py-2.5">
                    <div class="text-[11px] mb-1 flex items-center justify-between text-gray-500">
                      <span>`round-robin` (even load)</span>
                    </div>
                    <div>https://lasso-rpc.fly.dev/rpc/round-robin/ethereum</div>
                  </div>
                  <div class="border-gray-800/70 bg-black/60 rounded-lg border px-3 py-2.5">
                    <div class="text-[11px] mb-1 flex items-center justify-between text-gray-500">
                      <span>`latency-weighted` (probabilistic)</span>
                    </div>
                    <div>https://lasso-rpc.fly.dev/rpc/latency-weighted/ethereum</div>
                  </div>
                  <div class="border-gray-800/70 bg-black/60 rounded-lg border px-3 py-2.5">
                    <div class="text-[11px] mb-1 flex items-center justify-between text-gray-500">
                      <span>Provider override</span>
                    </div>
                    <div>https://lasso-rpc.fly.dev/rpc/provider/&lt;provider_id&gt;/ethereum</div>
                  </div>
                </div>

                <p class="text-[11px] mt-3 leading-relaxed text-gray-500">
                  Default `/rpc/:chain` uses a configurable strategy in `config/config.exs`
                  (e.g. `:round_robin` or `:fastest`) so you can change live behavior without touching clients.
                </p>
              </div>

              <div class="border-gray-800/70 bg-gray-950/80 space-y-3 rounded-xl border p-4">
                <div class="text-[11px] mb-2 font-medium uppercase tracking-wide text-gray-500">
                  WebSocket entrypoints (Ethereum)
                </div>
                <div class="font-mono space-y-2 text-xs text-gray-200">
                  <div class="border-gray-800/70 bg-black/60 rounded-lg border px-3 py-2.5">
                    <div class="text-[11px] mb-1 text-gray-500">Default strategy</div>
                    <div>wss://lasso-rpc.fly.dev/ws/rpc/ethereum</div>
                  </div>
                  <div class="border-gray-800/70 bg-black/60 rounded-lg border px-3 py-2.5">
                    <div class="text-[11px] mb-1 text-gray-500">Strategy-specific</div>
                    <div>wss://lasso-rpc.fly.dev/ws/rpc/fastest/ethereum</div>
                  </div>
                </div>

                <div class="text-[11px] mt-3 space-y-1 text-gray-500">
                  <p>
                    Lasso maintains long-lived WS channels with upstreams and multiplexes client subscriptions on top,
                    with failover and gap filling handled automatically.
                  </p>
                  <p>
                    Use `eth_subscribe` as usual—no custom protocol required.
                  </p>
                </div>
              </div>
            </div>
          </section>
          
    <!-- Networks & per-chain view -->
          <section class="space-y-4">
            <div class="flex flex-wrap items-center justify-between gap-3">
              <h2 class="text-lg font-semibold text-white sm:text-xl">Networks</h2>
              <p class="max-w-xl text-xs text-gray-400 sm:text-sm">
                Ethereum and Base are live on the public demo. Additional EVM chains can be added by editing
                `config/chains.yml` and they instantly appear in the dashboard and metrics APIs.
              </p>
            </div>

            <div class="grid gap-4 md:grid-cols-2">
              <div class="border-gray-800/60 bg-gray-900/70 flex items-center gap-4 rounded-xl border p-4">
                <div class="flex h-11 w-11 items-center justify-center rounded-lg bg-gradient-to-br from-purple-400 to-purple-600">
                  <span class="text-lg font-bold text-white">Ξ</span>
                </div>
                <div class="space-y-1 text-xs">
                  <div class="flex items-center gap-2">
                    <span class="text-sm font-semibold text-white">Ethereum</span>
                    <span class="bg-emerald-500/15 text-[10px] rounded-full px-2 py-0.5 font-medium text-emerald-300">
                      chain_id: 1
                    </span>
                  </div>
                  <div class="text-gray-400">
                    Hot reads, subscriptions, and historical queries handled by a mix of public and premium providers.
                  </div>
                </div>
              </div>

              <div class="border-gray-800/60 bg-gray-900/70 flex items-center gap-4 rounded-xl border p-4">
                <div class="flex h-11 w-11 items-center justify-center rounded-lg bg-gradient-to-br from-blue-400 to-blue-600">
                  <span class="text-lg font-bold text-white">B</span>
                </div>
                <div class="space-y-1 text-xs">
                  <div class="flex items-center gap-2">
                    <span class="text-sm font-semibold text-white">Base</span>
                    <span class="bg-emerald-500/15 text-[10px] rounded-full px-2 py-0.5 font-medium text-emerald-300">
                      chain_id: 8453
                    </span>
                  </div>
                  <div class="text-gray-400">
                    Same routing pipeline and observability, re-used for Base with chain-specific provider configs.
                  </div>
                </div>
              </div>
            </div>

            <p class="text-[11px] text-gray-500">
              Minimal config example lives in `config/chains.yml`—define `providers` with `id`, `name`, `url`, optional
              `ws_url`, and Lasso will include them automatically in routing, health checks, and metrics.
            </p>
          </section>
          
    <!-- Observability + analytics -->
          <section class="space-y-4">
            <div class="flex flex-wrap items-center justify-between gap-3">
              <h2 class="text-lg font-semibold text-white sm:text-xl">
                Observability &amp; analytics
              </h2>
              <p class="max-w-xl text-xs text-gray-400 sm:text-sm">
                Lasso exposes the same signals it uses for routing so you can debug issues, export reports,
                and feed your own dashboards or alerts.
              </p>
            </div>

            <div class="grid gap-4 md:grid-cols-2">
              <div class="border-gray-800/70 bg-gray-950/80 space-y-3 rounded-xl border p-4">
                <div class="text-[11px] mb-1 font-medium uppercase tracking-wide text-gray-500">
                  Live dashboard
                </div>
                <ul class="space-y-1.5 text-xs text-gray-300">
                  <li>
                    • Per-provider latency (p50 / p95 / p99), success rate, and call volume by method
                  </li>
                  <li>• Circuit breaker state and rate-limit cooldowns visualized in real time</li>
                  <li>
                    • Chain-level routing breakdowns (which providers are winning for which methods)
                  </li>
                  <li>
                    • Unified event stream combining routing, health, blocks, and client connection events
                  </li>
                </ul>
              </div>

              <div class="border-gray-800/70 bg-gray-950/80 space-y-3 rounded-xl border p-4">
                <div class="text-[11px] mb-1 font-medium uppercase tracking-wide text-gray-500">
                  APIs &amp; exports
                </div>
                <ul class="space-y-1.5 text-xs text-gray-300">
                  <li>• `GET /api/metrics/:chain` for JSON provider performance data</li>
                  <li>• CSV / JSON export helpers in `scripts/export_metrics_csv.mjs`</li>
                  <li>• Optional `include_meta=headers|body` for client-visible routing metadata</li>
                  <li>• Telemetry hooks ready for OpenTelemetry and external observability stacks</li>
                </ul>
              </div>
            </div>
          </section>
          
    <!-- Roadmap callout -->
          <section class="border-gray-800/80 from-gray-900/90 to-black/90 mb-8 rounded-2xl border bg-gradient-to-br via-gray-950 p-5">
            <div class="flex flex-wrap items-start justify-between gap-4">
              <div class="space-y-2">
                <h2 class="text-sm font-semibold text-white sm:text-base">
                  Where Lasso is going next
                </h2>
                <p class="max-w-xl text-xs text-gray-400 sm:text-sm">
                  The public demo focuses on rock-solid read-only aggregation today. The roadmap (see `project/FUTURE_FEATURES.md`)
                  includes hedged requests, result caching, best-sync routing, multi-tenant quotas, and more.
                </p>
              </div>
              <div class="space-y-1 text-xs text-gray-300">
                <div class="border-purple-500/40 bg-purple-500/10 rounded-lg border px-3 py-2">
                  <div class="text-[11px] font-medium uppercase tracking-wide text-purple-200">
                    Upcoming
                  </div>
                  <ul class="text-[11px] mt-1 space-y-0.5">
                    <li>• Hedged requests (race top N providers per method)</li>
                    <li>• Short-TTL result caching + request coalescing</li>
                    <li>• Best-sync strategy using block height &amp; reorg awareness</li>
                    <li>• Cost &amp; quota-aware routing and multi-tenant APIs</li>
                  </ul>
                </div>
              </div>
            </div>
          </section>
        </div>
      </div>
    </div>
    """
  end
end
