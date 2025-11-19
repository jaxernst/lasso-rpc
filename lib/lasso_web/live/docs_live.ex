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
    <div class="flex h-full w-full flex-col bg-gray-950">
      <DashboardHeader.header active_tab={@active_tab} />

      <!-- Content Section with subtle grid background and gradient overlay -->
      <div class="grid-pattern relative flex-1 overflow-y-auto">
        <!-- Subtle gradient overlay for softer transition -->
        <div class="absolute inset-0 bg-gradient-to-b from-gray-900/30 via-transparent to-gray-950/50 pointer-events-none">
        </div>
        <div class="relative bg-gray-950/90">
          <!-- Main Content -->
          <div class="mx-auto max-w-4xl px-6 py-12 space-y-12">

        <!-- Hero Section -->
        <section class="space-y-6 pt-4">
          <div class="inline-flex items-center gap-2 rounded-full bg-purple-500/10 px-4 py-1.5 text-sm text-purple-400 border border-purple-500/20">
            <span class="relative flex h-2 w-2">
              <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-purple-400 opacity-75"></span>
              <span class="relative inline-flex rounded-full h-2 w-2 bg-purple-400"></span>
            </span>
            Free public RPC endpoints now available
          </div>

          <p class="text-xl text-gray-300 leading-relaxed">
            A <span class="text-white font-semibold">distributed RPC aggregator</span> that continuously measures provider performance and routes each request to the fastest, most reliable option—automatically. Built on Elixir/OTP for <span class="text-purple-400">fault tolerance at scale</span>.
          </p>

          <!-- Dashboard Callout -->
          <div class="rounded-xl border border-purple-500/30 bg-purple-500/5 p-5">
            <div class="flex items-start gap-4">
              <div class="flex h-10 w-10 items-center justify-center rounded-lg bg-purple-500/20 flex-shrink-0">
                <svg class="h-5 w-5 text-purple-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z" />
                </svg>
              </div>
              <div class="flex-1">
                <h3 class="font-semibold text-white mb-1">View Live Endpoints & Performance</h3>
                <p class="text-sm text-gray-400 leading-relaxed mb-3">
                  All available RPC endpoints, routing strategies, and real-time provider performance metrics are visible in the live dashboard.
                </p>
                <a href="/" class="inline-flex items-center gap-2 text-sm font-medium text-purple-400 hover:text-purple-300 transition-colors">
                  Open Dashboard
                  <svg class="h-4 w-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 7l5 5m0 0l-5 5m5-5H6" />
                  </svg>
                </a>
              </div>
            </div>
          </div>
        </section>

        <!-- Key Features -->
        <section class="space-y-6">
          <h2 class="text-2xl font-bold text-white">Why Lasso</h2>

          <div class="grid gap-5 md:grid-cols-2">
            <div class="rounded-xl border border-gray-800/50 bg-gray-900/20 p-5 hover:border-gray-700/50 transition-colors">
              <div class="mb-3 flex h-10 w-10 items-center justify-center rounded-lg bg-purple-500/10">
                <svg class="h-5 w-5 text-purple-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z" />
                </svg>
              </div>
              <h3 class="text-base font-semibold mb-2 text-white">Intelligent Routing</h3>
              <p class="text-gray-400 text-sm leading-relaxed">
                Real-time performance tracking across HTTP and WebSocket providers. Requests automatically routed to the fastest option based on method-specific latency benchmarks.
              </p>
            </div>

            <div class="rounded-xl border border-gray-800/50 bg-gray-900/20 p-5 hover:border-gray-700/50 transition-colors">
              <div class="mb-3 flex h-10 w-10 items-center justify-center rounded-lg bg-emerald-500/10">
                <svg class="h-5 w-5 text-emerald-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m5.618-4.016A11.955 11.955 0 0112 2.944a11.955 11.955 0 01-8.618 3.04A12.02 12.02 0 003 9c0 5.591 3.824 10.29 9 11.622 5.176-1.332 9-6.03 9-11.622 0-1.042-.133-2.052-.382-3.016z" />
                </svg>
              </div>
              <h3 class="text-base font-semibold mb-2 text-white">Built-In Resilience</h3>
              <p class="text-gray-400 text-sm leading-relaxed">
                Per-provider circuit breakers, automatic failover, and retry logic. Provider failures are contained and traffic seamlessly shifts to healthy alternatives.
              </p>
            </div>

            <div class="rounded-xl border border-gray-800/50 bg-gray-900/20 p-5 hover:border-gray-700/50 transition-colors">
              <div class="mb-3 flex h-10 w-10 items-center justify-center rounded-lg bg-sky-500/10">
                <svg class="h-5 w-5 text-sky-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M7 12l3-3 3 3 4-4M8 21l4-4 4 4M3 4h18M4 4h16v12a1 1 0 01-1 1H5a1 1 0 01-1-1V4z" />
                </svg>
              </div>
              <h3 class="text-base font-semibold mb-2 text-white">WebSocket Multiplexing</h3>
              <p class="text-gray-400 text-sm leading-relaxed">
                Smart subscription management reduces upstream connections by 100x. Automatic gap-filling during failover ensures continuous event streams without missing blocks.
              </p>
            </div>

            <div class="rounded-xl border border-gray-800/50 bg-gray-900/20 p-5 hover:border-gray-700/50 transition-colors">
              <div class="mb-3 flex h-10 w-10 items-center justify-center rounded-lg bg-orange-500/10">
                <svg class="h-5 w-5 text-orange-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z" />
                </svg>
              </div>
              <h3 class="text-base font-semibold mb-2 text-white">Deep Observability</h3>
              <p class="text-gray-400 text-sm leading-relaxed">
                Live dashboard with provider rankings, real-time routing decisions, and comprehensive telemetry. Optional client-visible metadata for debugging.
              </p>
            </div>
          </div>
        </section>

        <!-- Quick Start -->
        <section id="quickstart" class="space-y-6">
          <h2 class="text-2xl font-bold text-white">Quick Start</h2>

          <div class="space-y-4">
            <div class="rounded-xl border border-gray-800/50 bg-gray-900/20 p-5">
              <h3 class="text-base font-semibold mb-3 text-white">Example Endpoints</h3>
              <p class="text-sm text-gray-400 mb-4">
                Lasso supports multiple routing strategies across HTTP and WebSocket. View all available endpoints and their real-time performance in the dashboard.
              </p>
              <div class="space-y-2">
                <div>
                  <div class="text-xs text-gray-500 mb-1">Fastest Provider (HTTP)</div>
                  <code class="block rounded-lg bg-gray-900/60 px-3 py-2 text-sm text-gray-300 font-mono border border-gray-800/50">
                    https://lasso-rpc.fly.dev/rpc/fastest/ethereum
                  </code>
                </div>
                <div>
                  <div class="text-xs text-gray-500 mb-1">Load Balanced (WebSocket)</div>
                  <code class="block rounded-lg bg-gray-900/60 px-3 py-2 text-sm text-gray-300 font-mono border border-gray-800/50">
                    wss://lasso-rpc.fly.dev/ws/rpc/ethereum
                  </code>
                </div>
              </div>
            </div>

            <div class="rounded-xl border border-gray-800/50 bg-gray-900/20 p-5">
              <h3 class="text-base font-semibold mb-3 text-white">Routing Strategies</h3>
              <div class="space-y-2 text-sm">
                <div class="flex items-start gap-3">
                  <code class="text-purple-400 font-mono text-xs">/rpc/fastest/:chain</code>
                  <span class="text-gray-400">Routes to lowest-latency provider per method</span>
                </div>
                <div class="flex items-start gap-3">
                  <code class="text-purple-400 font-mono text-xs">/rpc/round-robin/:chain</code>
                  <span class="text-gray-400">Evenly distributes across healthy providers</span>
                </div>
                <div class="flex items-start gap-3">
                  <code class="text-purple-400 font-mono text-xs">/rpc/latency-weighted/:chain</code>
                  <span class="text-gray-400">Probabilistic selection favoring faster providers</span>
                </div>
              </div>
            </div>
          </div>
        </section>

        <!-- Architecture -->
        <section id="architecture" class="space-y-6">
          <h2 class="text-2xl font-bold text-white">Architecture</h2>

          <div class="rounded-xl border border-gray-800/50 bg-gray-900/20 p-5">
            <h3 class="text-base font-semibold mb-3 text-white">Built on Elixir/OTP (BEAM VM)</h3>
            <p class="text-gray-400 text-sm leading-relaxed mb-4">
              Lasso leverages the Erlang VM's proven architecture for fault-tolerant, real-time systems. The same runtime powering Discord, WhatsApp, and Supabase.
            </p>
            <div class="grid gap-3 md:grid-cols-2 text-sm">
              <div class="flex items-start gap-2">
                <svg class="h-5 w-5 text-emerald-400 flex-shrink-0 mt-0.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7" />
                </svg>
                <span class="text-gray-300">100k+ lightweight processes per VM for massive concurrency</span>
              </div>
              <div class="flex items-start gap-2">
                <svg class="h-5 w-5 text-emerald-400 flex-shrink-0 mt-0.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7" />
                </svg>
                <span class="text-gray-300">OTP supervision trees for automatic failure recovery</span>
              </div>
              <div class="flex items-start gap-2">
                <svg class="h-5 w-5 text-emerald-400 flex-shrink-0 mt-0.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7" />
                </svg>
                <span class="text-gray-300">ETS tables for sub-millisecond in-memory lookups</span>
              </div>
              <div class="flex items-start gap-2">
                <svg class="h-5 w-5 text-emerald-400 flex-shrink-0 mt-0.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7" />
                </svg>
                <span class="text-gray-300">Hot code reloading without service interruption</span>
              </div>
            </div>
          </div>

          <div class="rounded-xl border border-gray-800/50 bg-gray-900/20 p-5">
            <h3 class="text-base font-semibold mb-3 text-white">Core Components</h3>
            <div class="space-y-3 text-sm">
              <div>
                <div class="font-semibold text-sky-400 mb-1">Transport-Agnostic Pipeline</div>
                <p class="text-gray-400 leading-relaxed">
                  Unified request routing across HTTP and WebSocket providers. Selection strategies automatically consider both transports based on real-time performance metrics.
                </p>
              </div>
              <div>
                <div class="font-semibold text-sky-400 mb-1">Per-Method Benchmarking</div>
                <p class="text-gray-400 leading-relaxed">
                  Passive latency measurement per chain, method, and transport. Fastest strategy uses live performance data, not static configuration.
                </p>
              </div>
              <div>
                <div class="font-semibold text-sky-400 mb-1">Circuit Breaker Protection</div>
                <p class="text-gray-400 leading-relaxed">
                  Per-provider, per-transport circuit breakers prevent cascade failures. Automatic recovery with half-open state testing before full restoration.
                </p>
              </div>
              <div>
                <div class="font-semibold text-sky-400 mb-1">Subscription Continuity</div>
                <p class="text-gray-400 leading-relaxed">
                  WebSocket subscriptions automatically failover to backup providers with HTTP gap-filling to ensure no missed blocks during provider switches.
                </p>
              </div>
            </div>
          </div>
        </section>

        <!-- Supported Chains -->
        <section class="space-y-6">
          <h2 class="text-2xl font-bold text-white">Supported Networks</h2>

          <div class="grid gap-4 md:grid-cols-2">
            <div class="rounded-xl border border-gray-800/50 bg-gray-900/20 p-5 flex items-center gap-4">
              <div class="flex h-12 w-12 items-center justify-center rounded-lg bg-gradient-to-br from-purple-400 to-purple-600">
                <span class="text-white font-bold text-lg">Ξ</span>
              </div>
              <div>
                <div class="font-semibold text-white">Ethereum</div>
                <div class="text-xs text-gray-500">Chain ID: 1</div>
              </div>
            </div>

            <div class="rounded-xl border border-gray-800/50 bg-gray-900/20 p-5 flex items-center gap-4">
              <div class="flex h-12 w-12 items-center justify-center rounded-lg bg-gradient-to-br from-blue-400 to-blue-600">
                <span class="text-white font-bold text-lg">B</span>
              </div>
              <div>
                <div class="font-semibold text-white">Base</div>
                <div class="text-xs text-gray-500">Chain ID: 8453</div>
              </div>
            </div>
          </div>

          <p class="text-sm text-gray-500">
            Additional EVM chains configurable via <code class="text-purple-400 font-mono">config/chains.yml</code>
          </p>
        </section>

        <!-- Performance -->
        <section class="space-y-6">
          <h2 class="text-2xl font-bold text-white">Performance Characteristics</h2>

          <div class="rounded-xl border border-purple-500/20 bg-purple-500/5 p-6">
            <div class="grid gap-6 md:grid-cols-3">
              <div class="text-center">
                <div class="text-3xl font-bold text-purple-400 mb-1">&lt;5ms</div>
                <div class="text-sm text-gray-400">Added routing latency</div>
              </div>
              <div class="text-center">
                <div class="text-3xl font-bold text-purple-400 mb-1">100k+</div>
                <div class="text-sm text-gray-400">Concurrent connections</div>
              </div>
              <div class="text-center">
                <div class="text-3xl font-bold text-purple-400 mb-1">&lt;1ms</div>
                <div class="text-sm text-gray-400">Provider selection time</div>
              </div>
            </div>
          </div>

          <div class="text-sm text-gray-400 leading-relaxed">
            Minimal overhead routing is offset by smarter upstream selection. Real-world latency improvements of 30-60% common when fastest strategy selects better providers than static configuration.
          </div>
        </section>

        <!-- Footer CTA -->
        <section class="rounded-2xl border border-purple-500/30 bg-gradient-to-br from-purple-500/10 to-purple-900/10 p-8 text-center mb-8">
          <h3 class="text-2xl font-bold mb-3 text-white">Ready to accelerate your RPC layer?</h3>
          <p class="text-gray-400 mb-6">
            Drop-in replacement for existing RPC endpoints. No SDK required.
          </p>
          <div class="flex flex-wrap justify-center gap-3">
            <a href="/" class="inline-flex items-center gap-2 rounded-lg bg-gradient-to-r from-purple-600 to-purple-500 px-6 py-3 text-sm font-semibold text-white shadow-lg shadow-purple-500/25 hover:shadow-purple-500/40 transition-all">
              View Live Dashboard
              <svg class="h-4 w-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 7l5 5m0 0l-5 5m5-5H6" />
              </svg>
            </a>
            <a href="https://github.com/LazerTechnologies/lasso-rpc" target="_blank" rel="noopener noreferrer" class="inline-flex items-center gap-2 rounded-lg bg-gray-800/50 border border-gray-700/50 px-6 py-3 text-sm font-semibold text-gray-200 hover:bg-gray-700/50 hover:border-gray-600/50 transition-colors">
              <svg class="h-5 w-5" fill="currentColor" viewBox="0 0 24 24">
                <path fill-rule="evenodd" clip-rule="evenodd" d="M12 2C6.477 2 2 6.477 2 12c0 4.42 2.865 8.17 6.839 9.49.5.092.682-.217.682-.482 0-.237-.008-.866-.013-1.7-2.782.603-3.369-1.34-3.369-1.34-.454-1.156-1.11-1.463-1.11-1.463-.908-.62.069-.608.069-.608 1.003.07 1.531 1.03 1.531 1.03.892 1.529 2.341 1.087 2.91.831.092-.646.35-1.086.636-1.336-2.22-.253-4.555-1.11-4.555-4.943 0-1.091.39-1.984 1.029-2.683-.103-.253-.446-1.27.098-2.647 0 0 .84-.269 2.75 1.025A9.578 9.578 0 0112 6.836c.85.004 1.705.114 2.504.336 1.909-1.294 2.747-1.025 2.747-1.025.546 1.377.203 2.394.1 2.647.64.699 1.028 1.592 1.028 2.683 0 3.842-2.339 4.687-4.566 4.935.359.309.678.919.678 1.852 0 1.336-.012 2.415-.012 2.743 0 .267.18.578.688.48C19.138 20.167 22 16.418 22 12c0-5.523-4.477-10-10-10z" />
              </svg>
              View on GitHub
            </a>
          </div>
        </section>

          </div>
        </div>
      </div>
    </div>
    """
  end
end
