defmodule LassoWeb.HomeLive do
  use LassoWeb, :live_view
  alias LassoWeb.Components.DashboardHeader
  alias LassoWeb.Components.LatencyHeatmap
  alias Lasso.Config.ConfigStore
  alias Lasso.Benchmarking.BenchmarkStore

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Process.send_after(self(), :tick, 1000)
    end

    config_status = Lasso.Config.ConfigStore.status()
    base_url = URI.parse(LassoWeb.Endpoint.url()).authority

    # Load initial heatmap data
    heatmap_chain = "ethereum"
    {heatmap_data, heatmap_methods, heatmap_live} = load_heatmap_data(heatmap_chain)

    socket =
      socket
      |> assign(:page_title, "Lasso RPC")
      |> assign(
        :page_description,
        "Smart RPC aggregation for consumer grade blockchain apps"
      )
      |> assign(:base_url, base_url)
      |> assign(:active_tab, "docs")
      |> assign(:active_strategy, "fastest")
      |> assign(:routing_decisions, initial_decisions())
      |> assign(:provider_health, initial_health())
      |> assign(:metrics, %{latency: 42, success_rate: 99.9})
      |> assign(:total_endpoints, config_status.total_endpoints)
      |> assign(:total_providers, config_status.total_providers)
      |> assign(:total_strategies, config_status.total_strategies)
      |> assign(:is_live, false)
      |> assign(:heatmap_chain, heatmap_chain)
      |> assign(:heatmap_data, heatmap_data)
      |> assign(:heatmap_methods, heatmap_methods)
      |> assign(:heatmap_live, heatmap_live)

    {:ok, socket}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 1000)

    # Try to get real data
    real_calls = Lasso.Benchmarking.BenchmarkStore.get_recent_calls("ethereum", 4)

    {new_decisions, is_live} =
      if length(real_calls) > 0 do
        {real_calls, true}
      else
        # Fallback to simulation
        {rotate_decisions(socket.assigns.routing_decisions), false}
      end

    # Refresh heatmap data
    {heatmap_data, heatmap_methods, heatmap_live} =
      load_heatmap_data(socket.assigns.heatmap_chain)

    {:noreply,
     socket
     |> assign(:routing_decisions, new_decisions)
     |> assign(:is_live, is_live)
     |> assign(:metrics, fluctuate_metrics(socket.assigns.metrics))
     |> assign(:heatmap_data, heatmap_data)
     |> assign(:heatmap_methods, heatmap_methods)
     |> assign(:heatmap_live, heatmap_live)}
  end

  defp initial_decisions do
    [
      %{
        method: "eth_sendRawTransaction",
        provider: "ethereum_llamarpc",
        latency: 180,
        color: "text-purple-300",
        strategy: "fastest"
      },
      %{
        method: "eth_getLogs",
        provider: "ethereum_merkle",
        latency: 72,
        color: "text-yellow-300",
        strategy: "best_sync"
      },
      %{
        method: "debug_traceCall",
        provider: "alchemy_eth",
        latency: 245,
        color: "text-purple-300",
        strategy: "throughput"
      },
      %{
        method: "eth_call",
        provider: "base_llamarpc",
        latency: 45,
        color: "text-emerald-300",
        strategy: "fastest"
      }
    ]
  end

  defp initial_health do
    [
      %{
        name: "Primary Node A",
        status: "ACTIVE",
        latency: "45ms",
        color: "bg-emerald-400",
        text: "text-emerald-400",
        subtext: "text-gray-500"
      },
      %{
        name: "Backup Node B",
        status: "COOLDOWN (4s)",
        latency: "Rate Limit (429)",
        color: "bg-yellow-400",
        text: "text-yellow-400",
        subtext: "text-yellow-500/80",
        animate: true
      },
      %{
        name: "Public Node C",
        status: "OFFLINE",
        latency: "Circuit Breaker Open",
        color: "bg-red-400",
        text: "text-red-400",
        subtext: "text-red-400/80"
      }
    ]
  end

  defp rotate_decisions([_first | rest]) do
    new_decision = generate_random_decision()
    rest ++ [new_decision]
  end

  defp generate_random_decision do
    methods = [
      "eth_getBalance",
      "eth_call",
      "eth_estimateGas",
      "eth_chainId",
      "eth_sendRawTransaction",
      "eth_getStorageAt",
      "debug_traceTransaction",
      "eth_getTransactionReceipt",
      "trace_block"
    ]

    providers = ["alchemy_eth", "infura_eth", "quicknode_eth", "blast_api", "ankr", "drpc"]
    strategies = ["fastest", "best_sync", "throughput", "round_robin"]

    latency = Enum.random(15..450)

    color =
      cond do
        latency < 50 -> "text-emerald-300"
        latency < 150 -> "text-yellow-300"
        true -> "text-purple-300"
      end

    %{
      method: Enum.random(methods),
      provider: Enum.random(providers),
      latency: latency,
      color: color,
      strategy: Enum.random(strategies)
    }
  end

  defp fluctuate_metrics(metrics) do
    new_latency = max(10, min(100, metrics.latency + Enum.random(-5..5)))
    new_success = max(98.0, min(100.0, metrics.success_rate + Enum.random(-10..10) / 100))

    %{latency: new_latency, success_rate: Float.round(new_success, 2)}
  end

  # Load heatmap data from BenchmarkStore for a specific chain
  defp load_heatmap_data(chain_name) do
    # Get providers configured for this chain
    providers =
      case ConfigStore.get_providers(chain_name) do
        {:ok, provider_list} -> provider_list
        _ -> []
      end

    # Get realtime stats to find available RPC methods
    realtime_stats = BenchmarkStore.get_realtime_stats(chain_name)
    rpc_methods = Map.get(realtime_stats, :rpc_methods, [])

    # If no data, return empty state
    if Enum.empty?(providers) or Enum.empty?(rpc_methods) do
      {[], [], false}
    else
      # Build heatmap data: for each provider, get latency per method
      heatmap_data =
        providers
        |> Enum.map(fn provider ->
          method_latencies =
            rpc_methods
            |> Enum.reduce(%{}, fn method, acc ->
              case BenchmarkStore.get_rpc_method_performance_with_percentiles(
                     chain_name,
                     provider.id,
                     method
                   ) do
                %{avg_duration_ms: avg_latency} when is_number(avg_latency) ->
                  Map.put(acc, method, avg_latency)

                _ ->
                  acc
              end
            end)

          %{
            id: provider.id,
            name: provider.name || provider.id,
            method_latencies: method_latencies
          }
        end)
        # Only include providers that have at least one method with data
        |> Enum.filter(fn p -> map_size(p.method_latencies) > 0 end)

      # Determine if we have live data
      has_data = length(heatmap_data) > 0

      {heatmap_data, rpc_methods, has_data}
    end
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    # Navigate to dashboard with selected tab
    {:noreply, push_navigate(socket, to: "/dashboard?tab=#{tab}")}
  end

  @impl true
  def handle_event("select_strategy", %{"strategy" => strategy}, socket) do
    {:noreply, assign(socket, :active_strategy, strategy)}
  end

  defp get_strategy_details(strategy) do
    case strategy do
      "fastest" ->
        %{
          url: "fastest",
          name: "Fastest",
          var_name: "clientFast",
          comment: "Route to the lowest latency provider for the given RPC method"
        }

      "throughput" ->
        %{
          url: "throughput",
          name: "Throughput",
          var_name: "clientBatch",
          comment: "Load balanced across providers based on capacity"
        }

      "best_sync" ->
        %{
          url: "best-sync",
          name: "Best Sync",
          var_name: "clientSync",
          comment: "Always read from the canonical chain tip"
        }
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :strategy_details, get_strategy_details(assigns.active_strategy))

    ~H"""
    <div
      id="main-scroll-container"
      phx-hook="ParallaxBackground"
      class="relative h-full w-full overflow-y-auto scroll-smooth"
    >
      <!-- Background Effects -->
      <div class="pointer-events-none fixed inset-0 z-0 overflow-hidden">
        <div
          data-parallax-speed="0.05"
          class="-left-[10%] -top-[10%] h-[300px] w-[300px] bg-purple-500/10 blur-[100px] absolute rounded-full transition-transform will-change-transform sm:h-[500px] sm:w-[500px]"
        >
        </div>
        <div
          data-parallax-speed="0.1"
          class="-right-[10%] top-[20%] h-[400px] w-[400px] bg-blue-500/10 blur-[120px] absolute rounded-full transition-transform will-change-transform sm:h-[600px] sm:w-[600px]"
        >
        </div>
      </div>

      <div class="relative z-10 flex min-h-full flex-col">
        <DashboardHeader.header active_tab={@active_tab} />

        <div class="flex-1">
          <div class="max-w-[min(90%,110rem)] relative mx-auto flex flex-col gap-12 py-6 lg:max-w-[min(83%,110rem)] lg:gap-20 lg:py-20">
            <!-- Hero / Overview -->
            <section
              id="hero-section"
              phx-hook="ScrollReveal"
              class="grid translate-y-8 items-center gap-8 opacity-0 transition-all duration-1000 ease-out lg:grid-cols-[minmax(0,1.6fr)_minmax(0,1.15fr)] lg:gap-10"
            >
              <div class="animate-fade-in-up space-y-6">
                <div class="space-y-4 lg:space-y-6">
                  <h1 class="text-balance leading-[1.1] text-3xl font-bold tracking-tight text-white sm:text-5xl lg:text-[3.5rem]">
                    Smart RPC aggregation for
                    <span class="bg-gradient-to-r from-purple-400 to-blue-400 bg-clip-text text-transparent">
                      consumer grade
                    </span>
                    blockchain apps.
                  </h1>

                  <div class="flex flex-wrap gap-4">
                    <div class="border-purple-500/30 bg-blue-400/10 text-white/90 inline-flex items-center gap-2 rounded-full border px-3 py-1.5 text-sm font-medium backdrop-blur-sm">
                      <span class="bg-emerald-400/90 shadow-[0_0_0_3px_rgba(16,185,129,0.35)] inline-flex h-2 w-2 animate-pulse rounded-full">
                      </span>
                      {@total_endpoints} live public RPC endpoints
                    </div>

                    <div class="border-purple-500/30 bg-blue-400/10 text-white/90 inline-flex items-center gap-2 rounded-full border px-3 py-1.5 text-sm font-medium backdrop-blur-sm">
                      <span class="bg-emerald-400/90 shadow-[0_0_0_3px_rgba(16,185,129,0.35)] inline-flex h-2 w-2 animate-pulse rounded-full">
                      </span>
                      {@total_providers} node providers
                    </div>

                    <div class="border-purple-500/30 bg-blue-400/10 text-white/90 inline-flex items-center gap-2 rounded-full border px-3 py-1.5 text-sm font-medium backdrop-blur-sm">
                      <span class="bg-emerald-400/90 shadow-[0_0_0_3px_rgba(16,185,129,0.35)] inline-flex h-2 w-2 animate-pulse rounded-full">
                      </span>
                      {@total_strategies} configurable routing strategies
                    </div>
                  </div>

                  <p class="max-w-xl text-base leading-relaxed text-gray-300 sm:text-lg">
                    Lasso wrangles your node infrastructure and turns it into a
                    <span class="border-purple-500/50 border-b font-medium text-gray-100">
                      fast, performant, reliable, and deeply configurable
                    </span>
                    RPC layer. No SDKs, no downtime, just better RPC endpoints.
                  </p>
                </div>

                <div class="flex flex-wrap items-center gap-4 pt-8">
                  <a
                    href="/dashboard"
                    class="group shadow-purple-500/20 relative inline-flex items-center gap-2 rounded-lg bg-purple-600 px-6 py-3 text-sm font-semibold text-white shadow-lg transition-all hover:shadow-purple-500/40 hover:scale-105 hover:bg-purple-500"
                  >
                    <span class="relative z-10 flex items-center gap-2">
                      Open live dashboard
                      <svg
                        class="h-4 w-4 transition-transform group-hover:translate-x-1"
                        fill="none"
                        stroke="currentColor"
                        viewBox="0 0 24 24"
                      >
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          stroke-width="2"
                          d="M13 7l5 5m0 0-5 5m5-5H6"
                        />
                      </svg>
                    </span>
                  </a>
                  <a
                    href="https://github.com/LazerTechnologies/lasso-rpc"
                    target="_blank"
                    rel="noopener noreferrer"
                    class="group border-gray-700/70 bg-gray-900/60 inline-flex items-center gap-2 rounded-lg border px-6 py-3 text-sm font-semibold text-gray-200 transition-all hover:border-gray-500 hover:bg-gray-800 hover:text-white"
                  >
                    <svg
                      class="h-5 w-5 transition-transform group-hover:rotate-12"
                      fill="currentColor"
                      viewBox="0 0 24 24"
                    >
                      <path
                        fill-rule="evenodd"
                        clip-rule="evenodd"
                        d="M12 2C6.477 2 2 6.477 2 12c0 4.42 2.865 8.17 6.839 9.49.5.092.682-.217.682-.482 0-.237-.008-.866-.013-1.7-2.782.603-3.369-1.34-3.369-1.34-.454-1.156-1.11-1.463-1.11-1.463-.908-.62.069-.608.069-.608 1.003.07 1.531 1.03 1.531 1.03.892 1.529 2.341 1.087 2.91.831.092-.646.35-1.086.636-1.336-2.22-.253-4.555-1.11-4.555-4.943 0-1.091.39-1.984 1.029-2.683-.103-.253-.446-1.27.098-2.647 0 0 .84-.269 2.75 1.025A9.578 9.578 0 0112 6.836c.85.004 1.705.114 2.504.336 1.909-1.294 2.747-1.025 2.747-1.025.546 1.377.203 2.394.1 2.647.64.699 1.028 1.592 1.028 2.683 0 3.842-2.339 4.687-4.566 4.935.359.309.678.919.678 1.852 0 1.336-.012 2.415-.012 2.743 0 .267.18.578.688.48C19.138 20.167 22 16.418 22 12c0-5.523-4.477-10-10-10z"
                      />
                    </svg>
                    View on GitHub
                  </a>
                </div>

                <div class="flex flex-wrap items-center gap-3 pt-2 text-sm font-medium tracking-tight text-gray-400">
                  <span class="flex items-center gap-1.5">
                    <svg
                      class="h-4 w-4 text-emerald-500"
                      fill="none"
                      stroke="currentColor"
                      viewBox="0 0 24 24"
                    >
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2"
                        d="M5 13l4 4L19 7"
                      >
                      </path>
                    </svg>
                    HTTP + WebSocket endpoints
                  </span>
                  <span class="h-1 w-1 rounded-full bg-gray-700"></span>
                  <span class="flex items-center gap-1.5">
                    <svg
                      class="h-4 w-4 text-emerald-500"
                      fill="none"
                      stroke="currentColor"
                      viewBox="0 0 24 24"
                    >
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2"
                        d="M5 13l4 4L19 7"
                      >
                      </path>
                    </svg>
                    Ethereum JSON-RPC superset
                  </span>
                  <span class="h-1 w-1 rounded-full bg-gray-700"></span>
                  <span class="flex items-center gap-1.5">
                    <svg
                      class="h-4 w-4 text-emerald-500"
                      fill="none"
                      stroke="currentColor"
                      viewBox="0 0 24 24"
                    >
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2"
                        d="M5 13l4 4L19 7"
                      >
                      </path>
                    </svg>
                    Automatic failover + redundancy
                  </span>
                </div>
              </div>
              
    <!-- Dashboard-style callout -->
              <div class="animate-float relative z-10">
                <div class="animate-pulse-glow absolute -inset-1 rounded-2xl bg-gradient-to-r from-purple-600 to-blue-600 opacity-30 blur">
                </div>
                <div class="border-purple-500/25 from-purple-500/10 via-slate-950/90 to-black/90 shadow-[0_20px_45px_rgba(15,23,42,0.75)] relative rounded-2xl border bg-gradient-to-br p-4 backdrop-blur-xl sm:p-6">
                  <div class="mb-6 flex items-start gap-4">
                    <div class="bg-purple-500/20 border-purple-500/30 flex h-10 w-10 flex-shrink-0 items-center justify-center rounded-xl border">
                      <svg
                        class="h-6 w-6 text-purple-200"
                        fill="none"
                        stroke="currentColor"
                        viewBox="0 0 24 24"
                      >
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          stroke-width="2"
                          d="M8 7h12m0 0l-4-4m4 4l-4 4m0 6H4m0 0l4 4m-4-4l4-4"
                        />
                      </svg>
                    </div>
                    <div class="space-y-1">
                      <h2 class="text-base font-semibold text-white">
                        Smart, Observable RPC Request Routing
                      </h2>
                      <p class="text-purple-100/70 text-xs leading-relaxed">
                        See every provider, chain, and strategy in real time: latency percentiles, success rates,
                        circuit breaker status, and exactly which upstream handled each JSON-RPC call.
                      </p>
                    </div>
                  </div>

                  <div class="border-purple-500/20 bg-black/40 space-y-3 rounded-xl border p-3 sm:p-4">
                    <div class="text-[11px] flex items-center justify-between font-medium uppercase tracking-wider text-gray-400">
                      <span>Recent routing decisions</span>
                      <span class="bg-emerald-500/10 text-[10px] border-emerald-500/20 inline-flex items-center gap-1.5 rounded-full border px-2 py-0.5 font-bold text-emerald-400">
                        <span class="h-1.5 w-1.5 animate-pulse rounded-full bg-emerald-400"></span>
                        {if @is_live, do: "live", else: "simulated"}
                      </span>
                    </div>
                    <div class="font-mono text-[11px] space-y-2 text-gray-200">
                      <%= for decision <- @routing_decisions do %>
                        <div class="bg-gray-900/60 border-gray-800/50 flex items-center justify-between gap-2 rounded-lg border px-3 py-2 transition-all hover:bg-gray-800/60">
                          <div class="flex items-center gap-2 overflow-hidden">
                            <%= if Map.get(decision, :strategy) do %>
                              <span class="text-[9px] hidden rounded bg-gray-800 px-1.5 py-0.5 font-bold uppercase tracking-wider text-gray-400 lg:inline-flex">
                                {decision.strategy}
                              </span>
                            <% end %>
                            <span class="truncate font-medium text-sky-300">{decision.method}</span>
                          </div>

                          <div class="flex flex-shrink-0 items-center gap-2">
                            <span class="text-gray-600">→</span>
                            <span class="max-w-[80px] truncate text-right text-gray-300 lg:max-w-[100px]">
                              {decision.provider}
                            </span>
                            <span class={"#{decision.color} min-w-[40px] text-right font-bold"}>
                              {decision.latency}ms
                            </span>
                          </div>
                        </div>
                      <% end %>
                    </div>

                    <a
                      href="/dashboard"
                      class="group bg-purple-500/10 border-purple-500/20 mt-2 inline-flex w-full items-center justify-center gap-2 rounded-lg border px-3 py-2.5 text-xs font-semibold text-purple-200 transition-all hover:bg-purple-500 hover:text-white"
                    >
                      Inspect live traffic
                      <svg
                        class="h-3.5 w-3.5 transition-transform group-hover:translate-x-1"
                        fill="none"
                        stroke="currentColor"
                        viewBox="0 0 24 24"
                      >
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
              </div>
            </section>
            
    <!-- Feature 1: Intelligent Routing -->
            <section
              id="feature-routing"
              phx-hook="ScrollReveal"
              class="grid translate-y-8 items-center gap-8 opacity-0 transition-all duration-1000 ease-out lg:grid-cols-2 lg:gap-20"
            >
              <div class="space-y-8">
                <div class="space-y-4">
                  <div class="inline-flex items-center gap-2 text-sm font-bold uppercase tracking-wide text-purple-400">
                    <span class="h-[1px] w-8 bg-purple-400"></span> Intelligent Routing
                  </div>
                  <h2 class="text-3xl font-bold text-white sm:text-4xl">
                    Tune your RPC infra for your application's needs
                  </h2>
                  <p class="text-base leading-relaxed text-gray-400">
                    Different apps require different performance characteristics from their RPC endpoints. Optimize for speed, cost, sync, throughput, or whatever matters most to you.
                    Express those preferences through RPC endpoint slugs.
                  </p>
                </div>

                <div class="space-y-4">
                  <button
                    phx-click="select_strategy"
                    phx-value-strategy="fastest"
                    class={"#{if @active_strategy == "fastest", do: "bg-gray-800/60 ring-purple-500/50 shadow-purple-500/10 shadow-lg ring-1", else: "hover:bg-gray-900/30"} group flex w-full gap-5 rounded-xl p-3 text-left transition-all duration-200 sm:p-4"}
                  >
                    <div class="flex-none pt-1">
                      <div class={"#{if @active_strategy == "fastest", do: "shadow-purple-500/40 bg-purple-500 text-white shadow-lg", else: "bg-gray-800 text-gray-400 group-hover:bg-purple-500 group-hover:text-white"} flex h-8 w-8 items-center justify-center rounded-full text-sm font-bold transition-colors"}>
                        1
                      </div>
                    </div>
                    <div class="min-w-0 flex-1">
                      <h3 class={"#{if @active_strategy == "fastest", do: "text-purple-300", else: "text-white group-hover:text-purple-300"} text-base font-semibold transition-colors"}>
                        Fastest
                      </h3>
                      <p class="mt-2 text-sm leading-relaxed text-gray-400">
                        Routes to the provider with the lowest p50 latency for that specific method over the last 5 minutes.
                      </p>
                    </div>
                  </button>

                  <button
                    phx-click="select_strategy"
                    phx-value-strategy="throughput"
                    class={"#{if @active_strategy == "throughput", do: "bg-gray-800/60 ring-purple-500/50 shadow-purple-500/10 shadow-lg ring-1", else: "hover:bg-gray-900/30"} group flex w-full gap-5 rounded-xl p-3 text-left transition-all duration-200 sm:p-4"}
                  >
                    <div class="flex-none pt-1">
                      <div class={"#{if @active_strategy == "throughput", do: "shadow-purple-500/40 bg-purple-500 text-white shadow-lg", else: "bg-gray-800 text-gray-400 group-hover:bg-purple-500 group-hover:text-white"} flex h-8 w-8 items-center justify-center rounded-full text-sm font-bold transition-colors"}>
                        2
                      </div>
                    </div>
                    <div class="min-w-0 flex-1">
                      <h3 class={"#{if @active_strategy == "throughput", do: "text-purple-300", else: "text-white group-hover:text-purple-300"} text-base font-semibold transition-colors"}>
                        Throughput (Weighted)
                      </h3>
                      <p class="mt-2 text-sm leading-relaxed text-gray-400">
                        Probabilistic routing where faster providers get a larger share of the traffic. Maximizes total system throughput.
                      </p>
                    </div>
                  </button>

                  <button
                    phx-click="select_strategy"
                    phx-value-strategy="best_sync"
                    class={"#{if @active_strategy == "best_sync", do: "bg-gray-800/60 ring-purple-500/50 shadow-purple-500/10 shadow-lg ring-1", else: "hover:bg-gray-900/30"} group flex w-full gap-5 rounded-xl p-3 text-left transition-all duration-200 sm:p-4"}
                  >
                    <div class="flex-none pt-1">
                      <div class={"#{if @active_strategy == "best_sync", do: "shadow-purple-500/40 bg-purple-500 text-white shadow-lg", else: "bg-gray-800 text-gray-400 group-hover:bg-purple-500 group-hover:text-white"} flex h-8 w-8 items-center justify-center rounded-full text-sm font-bold transition-colors"}>
                        3
                      </div>
                    </div>
                    <div class="min-w-0 flex-1">
                      <h3 class={"#{if @active_strategy == "best_sync", do: "text-purple-300", else: "text-white group-hover:text-purple-300"} text-base font-semibold transition-colors"}>
                        Best Sync
                      </h3>
                      <p class="mt-2 text-sm leading-relaxed text-gray-400">
                        Ensures you're always reading from the tip of the chain. Routes to providers with the highest block height.
                      </p>
                    </div>
                  </button>
                </div>
              </div>

              <div class="bg-gray-950/50 relative w-full min-w-0 max-w-full transform rounded-2xl border border-gray-800 p-1 shadow-2xl transition-transform duration-500 sm:hover:scale-[1.01]">
                <div class="from-purple-500/10 absolute -inset-px rounded-2xl bg-gradient-to-b to-transparent opacity-50">
                </div>
                <div class="bg-gray-900/90 font-mono relative rounded-xl p-4 text-xs sm:p-6">
                  <div class="mb-6 flex items-center gap-2 border-b border-gray-800 pb-4 text-gray-500">
                    <div class="flex gap-2">
                      <div class="bg-red-500/20 h-3 w-3 rounded-full"></div>
                      <div class="bg-yellow-500/20 h-3 w-3 rounded-full"></div>
                      <div class="bg-emerald-500/20 h-3 w-3 rounded-full"></div>
                    </div>
                    <span class="ml-3 font-medium">client_setup.ts</span>
                  </div>

                  <div class="min-w-0 space-y-1 overflow-x-auto pb-2 text-sm text-gray-300">
                    <div class="mb-6 text-gray-400">
                      <span class="text-purple-400">import</span>
                      &#123; createPublicClient, http, webSocket &#125;
                      <span class="text-purple-400">from</span> <span class="text-emerald-300">'viem'</span>;
                    </div>

                    <div class="mb-2 italic text-gray-500">// {@strategy_details.comment}</div>
                    <div>
                      <span class="text-purple-400">const</span> {@strategy_details.var_name} = createPublicClient(&#123;
                    </div>
                    <div class="pl-4">
                      chain: mainnet,
                    </div>
                    <div class="pl-4">
                      transport: http(<span class="text-emerald-300">"https://{@base_url}/rpc/<span class="font-bold text-yellow-300">{@strategy_details.url}</span>/eth"</span>)
                    </div>
                    <div>&#125;);</div>

                    <div class="mt-8"></div>

                    <div class="mb-2 italic text-gray-500">
                      // Prioritize best sync for real-time block updates
                    </div>
                    <div>
                      <span class="text-purple-400">const</span>
                      clientRealtime = createPublicClient(&#123;
                    </div>
                    <div class="pl-4">
                      chain: mainnet,
                    </div>
                    <div class="pl-4">
                      transport: webSocket(<span class="text-emerald-300">"wss://{@base_url}/ws/rpc/<span class="font-bold text-yellow-300">best-sync</span>/eth"</span>)
                    </div>
                    <div>&#125;);</div>
                  </div>
                </div>
              </div>
            </section>
            
    <!-- Feature 2: Resilience -->
            <section
              id="feature-resilience"
              phx-hook="ScrollReveal"
              class="grid translate-y-8 items-center gap-8 opacity-0 transition-all duration-1000 ease-out lg:grid-cols-2 lg:gap-12"
            >
              <div class="bg-gray-950/50 relative order-2 transform rounded-2xl border border-gray-800 p-1 shadow-2xl transition-transform duration-500 hover:scale-[1.01] lg:order-1">
                <div class="from-emerald-500/10 absolute -inset-px rounded-2xl bg-gradient-to-b to-transparent opacity-50">
                </div>
                <div class="bg-gray-900/90 relative rounded-xl p-4 sm:p-6">
                  <!-- Mock System Status UI -->
                  <div class="space-y-4">
                    <div class="flex items-center justify-between border-b border-gray-800 pb-4">
                      <span class="text-sm font-semibold text-gray-300">Provider Health Pool</span>
                      <span class="flex items-center gap-2 text-xs font-bold text-emerald-400">
                        <span class="relative flex h-2.5 w-2.5">
                          <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-emerald-400 opacity-75">
                          </span>
                          <span class="relative inline-flex h-2.5 w-2.5 rounded-full bg-emerald-500">
                          </span>
                        </span>
                        System Operational
                      </span>
                    </div>

                    <%= for provider <- @provider_health do %>
                      <div class={"#{if Map.get(provider, :animate), do: "animate-pulse", else: ""} bg-gray-800/40 border-gray-700/30 flex items-center justify-between rounded-lg border p-3 transition-colors hover:bg-gray-800/60"}>
                        <div class="flex items-center gap-4">
                          <div class={"#{provider.color} shadow-[0_0_8px_currentColor] h-2.5 w-2.5 rounded-full"}>
                          </div>
                          <div>
                            <div class="text-sm font-medium text-gray-200">{provider.name}</div>
                            <div class={"#{provider.subtext} text-xs"}>{provider.latency}</div>
                          </div>
                        </div>
                        <div class={"#{provider.text} text-[10px] rounded bg-gray-900 px-2 py-1 font-bold"}>
                          {provider.status}
                        </div>
                      </div>
                    <% end %>

                    <div class="bg-black/30 font-mono border-gray-800/50 mt-4 flex items-center gap-3 rounded-lg border p-3 text-xs text-gray-400">
                      <span class="font-bold text-purple-400">event</span>
                      <span>[failover] Node B -> Node A (0ms downtime)</span>
                    </div>
                  </div>
                </div>
              </div>

              <div class="order-1 space-y-8 lg:order-2">
                <div class="space-y-4">
                  <div class="inline-flex items-center gap-2 text-sm font-bold uppercase tracking-wide text-emerald-400">
                    <span class="h-[1px] w-8 bg-emerald-400"></span> Resilience & Scale
                  </div>
                  <h2 class="text-3xl font-bold text-white sm:text-4xl">
                    Don't let infrastructure failures impact your users.
                  </h2>
                  <p class="text-base leading-relaxed text-gray-400">
                    Lasso gives you layers of infra backups and intelligently manages them so your app doesn't have to.
                  </p>
                </div>

                <div class="grid gap-4 sm:grid-cols-2">
                  <div class="bg-gray-900/30 group rounded-xl border border-gray-800 p-5 transition-colors hover:border-emerald-500/30">
                    <h3 class="text-sm font-bold text-white transition-colors group-hover:text-emerald-300">
                      Zero-Downtime Failover
                    </h3>
                    <p class="mt-2 text-xs leading-relaxed text-gray-400">
                      Intelligent routing automatically switches between providers and protocols (HTTP/WS) to bypass outages and latency spikes.
                    </p>
                  </div>
                  <div class="bg-gray-900/30 group rounded-xl border border-gray-800 p-5 transition-colors hover:border-emerald-500/30">
                    <h3 class="text-sm font-bold text-white transition-colors group-hover:text-emerald-300">
                      Fault Isolated
                    </h3>
                    <p class="mt-2 text-xs leading-relaxed text-gray-400">
                      Chains and providers run in isolated supervision trees. Failures are contained and never cascade.
                    </p>
                  </div>

                  <div class="bg-gray-900/30 group rounded-xl border border-gray-800 p-5 transition-colors hover:border-emerald-500/30">
                    <h3 class="text-sm font-bold text-white transition-colors group-hover:text-emerald-300">
                      Massive Concurrency
                    </h3>
                    <p class="mt-2 text-xs leading-relaxed text-gray-400">
                      100k+ parallel routing connections enabled by the BEAM VM
                    </p>
                  </div>

                  <div class="bg-gray-900/30 group rounded-xl border border-gray-800 p-5 transition-colors hover:border-emerald-500/30">
                    <h3 class="text-sm font-bold text-white transition-colors group-hover:text-emerald-300">
                      Real-time Health Monitoring
                    </h3>
                    <p class="mt-2 text-xs leading-relaxed text-gray-400">
                      Continuously tracks latency, errors, and sync status per provider, view live status in the dashboard.
                    </p>
                  </div>
                </div>
              </div>
            </section>
            
    <!-- Feature 3: Observability -->
            <section
              id="feature-observability"
              phx-hook="ScrollReveal"
              class="grid translate-y-8 items-start gap-4 opacity-0 transition-all duration-1000 ease-out 2xl:grid-cols-[minmax(0,1fr)_auto] 2xl:gap-12"
            >
              <div class="space-y-8">
                <div class="space-y-4">
                  <div class="inline-flex items-center gap-2 text-sm font-bold uppercase tracking-wide text-sky-400">
                    <span class="h-[1px] w-8 bg-sky-400"></span> Deep Observability
                  </div>
                  <p class="max-w-[500px] text-base leading-relaxed text-gray-400">
                    Get a unified view of your entire RPC layer. See where providers are winning and where providers are failing with granular metrics...
                  </p>
                </div>

                <div class="pt-4">
                  <a
                    href="/dashboard"
                    class="group inline-flex items-center gap-2 text-sm font-bold text-sky-400 transition-colors hover:text-sky-300"
                  >
                    Explore the metrics
                    <span aria-hidden="true" class="transition-transform group-hover:translate-x-1">
                      →
                    </span>
                  </a>
                </div>
              </div>
              
    <!-- Real Latency Heatmap -->
              <div class="hidden w-full flex-col items-start overflow-x-visible sm:flex">
                <LatencyHeatmap.heatmap
                  heatmap_data={@heatmap_data}
                  methods={@heatmap_methods}
                  chain_name={@heatmap_chain}
                  is_live={@heatmap_live}
                />
              </div>
            </section>
          </div>
        </div>
        
    <!-- Footer / Closing -->
        <footer class="border-gray-800/50 bg-gray-900/30 mt-auto border-t backdrop-blur-sm">
          <div class="max-w-[min(90%,110rem)] mx-auto px-6 py-12 lg:max-w-[min(83%,110rem)] lg:py-16">
            <div class="grid gap-8 md:grid-cols-2 lg:grid-cols-4 lg:gap-12">
              <div class="col-span-2 space-y-6">
                <h3 class="text-xl font-bold text-white">Ready for production</h3>
                <p class="max-w-md text-sm leading-relaxed text-gray-400">
                  Lasso is built on Elixir/OTP for massive concurrency and fault tolerance. It's designed to sit in your infrastructure as a stateless, scalable layer.
                </p>
                <div class="flex gap-6">
                  <a
                    href="https://github.com/LazerTechnologies/lasso-rpc"
                    class="text-sm font-semibold text-white transition-colors hover:text-purple-400"
                  >
                    GitHub
                  </a>
                  <a
                    href="https://github.com/LazerTechnologies/lasso-rpc/tree/main/project"
                    target="_blank"
                    rel="noopener noreferrer"
                    class="text-sm font-semibold text-white transition-colors hover:text-purple-400"
                  >
                    Documentation
                  </a>
                  <a
                    href="/dashboard"
                    class="text-sm font-semibold text-white transition-colors hover:text-purple-400"
                  >
                    Dashboard
                  </a>
                </div>
              </div>

              <div>
                <h4 class="text-sm font-bold uppercase tracking-wide text-white">
                  Supported Networks
                </h4>
                <ul class="mt-4 space-y-3 text-sm text-gray-400">
                  <li class="flex items-center gap-3">
                    <span class="shadow-[0_0_8px_currentColor] h-2 w-2 rounded-full bg-emerald-500">
                    </span>
                    Ethereum Mainnet
                  </li>
                  <li class="flex items-center gap-3">
                    <span class="shadow-[0_0_8px_currentColor] h-2 w-2 rounded-full bg-blue-500">
                    </span>
                    Base
                  </li>
                  <li class="flex items-center gap-3">
                    <span class="h-2 w-2 rounded-full bg-gray-600"></span> + Any EVM Chain
                  </li>
                </ul>
              </div>

              <div>
                <h4 class="text-sm font-bold uppercase tracking-wide text-white">Roadmap</h4>
                <ul class="mt-4 space-y-3 text-sm text-gray-400">
                  <li class="flex items-center gap-2">
                    <span class="text-purple-500">›</span> Hedged Requests
                  </li>
                  <li class="flex items-center gap-2">
                    <span class="text-purple-500">›</span> Result Caching
                  </li>
                  <li class="flex items-center gap-2">
                    <span class="text-purple-500">›</span> Best-Sync Routing
                  </li>
                  <li class="flex items-center gap-2">
                    <span class="text-purple-500">›</span> Multi-tenant Quotas
                  </li>
                </ul>
              </div>
            </div>
          </div>
        </footer>
      </div>
    </div>
    """
  end
end
