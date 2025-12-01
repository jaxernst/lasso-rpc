defmodule LassoWeb.Components.LatencyHeatmap do
  @moduledoc """
  Real-time latency heatmap component showing provider performance
  across different RPC methods.

  Displays a grid where:
  - Y-axis: Providers
  - X-axis: RPC methods (horizontal expansion)
  - Cell color: Based on relative latency (dynamic thresholds based on data range)
  """

  use Phoenix.Component

  @doc """
  Renders a latency heatmap for provider/method performance.

  ## Assigns
    * `:heatmap_data` - List of provider data with method latencies
    * `:methods` - List of RPC methods to display as columns
    * `:chain_name` - Name of the chain being displayed
    * `:is_live` - Whether showing live data or simulated
  """
  attr(:heatmap_data, :list, required: true)
  attr(:methods, :list, required: true)
  attr(:chain_name, :string, default: "ethereum")
  attr(:is_live, :boolean, default: false)

  def heatmap(assigns) do
    # Dedupe methods by base name (combine @http/@ws variants)
    unique_methods =
      assigns.methods
      |> Enum.map(&extract_base_method/1)
      |> Enum.uniq()
      |> Enum.take(12)

    # Limit providers for display
    display_providers = Enum.take(assigns.heatmap_data, 6)
    provider_count = length(display_providers)
    method_count = length(unique_methods)

    # Calculate dynamic thresholds per method
    method_thresholds =
      calculate_method_thresholds(display_providers, unique_methods, assigns.methods)

    assigns =
      assigns
      |> assign(:display_methods, unique_methods)
      |> assign(:display_providers, display_providers)
      |> assign(:original_methods, assigns.methods)
      |> assign(:provider_count, provider_count)
      |> assign(:method_count, method_count)
      |> assign(:method_thresholds, method_thresholds)

    ~H"""
    <div class="relative" id="latency-heatmap" phx-hook="HeatmapAnimation">
      <!-- Subtle animations -->
      <style>
        @keyframes cell-glow {
          0%, 100% { filter: brightness(1); }
          50% { filter: brightness(1.15); }
        }
        @keyframes scan-line {
          0% { transform: translateX(-100%); }
          100% { transform: translateX(400%); }
        }
        .heatmap-cell {
          position: relative;
          overflow: hidden;
        }
        .heatmap-cell::after {
          content: '';
          position: absolute;
          top: 0;
          left: 0;
          right: 0;
          bottom: 0;
          background: linear-gradient(90deg, transparent, rgba(255,255,255,0.04), transparent);
          transform: translateX(-100%);
          animation: scan-line 5s ease-in-out infinite;
        }
        .heatmap-cell:nth-child(1)::after { animation-delay: 0s; }
        .heatmap-cell:nth-child(2)::after { animation-delay: 0.2s; }
        .heatmap-cell:nth-child(3)::after { animation-delay: 0.4s; }
        .heatmap-cell:nth-child(4)::after { animation-delay: 0.6s; }
        .heatmap-cell:nth-child(5)::after { animation-delay: 0.8s; }
        .heatmap-cell:nth-child(6)::after { animation-delay: 1.0s; }
        .cell-pulse {
          animation: cell-glow 3s ease-in-out infinite;
        }
      </style>

      <%= if Enum.empty?(@heatmap_data) do %>
        <!-- Empty state -->
        <div class="border-gray-800/60 bg-gray-900/20 mx-auto max-w-2xl rounded-xl border border-dashed p-8">
          <div class="flex flex-col items-center justify-center gap-3 text-center">
            <div class="relative">
              <div class="bg-gray-800/40 flex h-10 w-10 items-center justify-center rounded-lg">
                <svg
                  class="h-5 w-5 text-gray-600"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="1.5"
                    d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z"
                  />
                </svg>
              </div>
              <div class="bg-sky-500/50 absolute -top-1 -right-1 h-2 w-2 animate-ping rounded-full">
              </div>
            </div>
            <div>
              <p class="text-sm font-medium text-gray-400">Waiting for data</p>
              <p class="mt-0.5 text-xs text-gray-600">Metrics appear as requests flow through</p>
            </div>
          </div>
        </div>
      <% else %>
        <!-- Centered container -->
        <div class="flex w-full flex-col items-start overflow-x-auto pb-6 lg:items-center lg:overflow-visible lg:pb-0">
          <div class="inline-flex origin-top-left scale-90 flex-col lg:origin-center xl:scale-100">
            <!-- Method headers (top, rotated) -->
            <div class="flex pb-1">
              <!-- Spacer for provider label column -->
              <div class=" w-36 flex-shrink-0"></div>
              <!-- Method labels - rotated -->
              <div class="gap-[8px] flex">
                <%= for {method, idx} <- Enum.with_index(@display_methods) do %>
                  <div
                    class="animate-[fadeIn_0.3s_ease-out_forwards] relative h-24 w-16 flex-shrink-0 opacity-0"
                    style={"animation-delay: #{idx * 40}ms"}
                  >
                    <span
                      class="absolute bottom-0 left-10 origin-bottom-left whitespace-nowrap text-xs font-medium text-gray-500"
                      style="transform: rotate(-30deg);"
                      title={method}
                    >
                      {format_method_display(method)}
                    </span>
                  </div>
                <% end %>
              </div>
            </div>
            
    <!-- Grid rows (providers) -->
            <div class="flex">
              <!-- Provider labels (left) -->
              <div class="flex flex-shrink-0 flex-col gap-2 pt-6">
                <%= for {provider, idx} <- Enum.with_index(@display_providers) do %>
                  <div
                    class="animate-[fadeIn_0.3s_ease-out_forwards] flex h-10 items-center justify-end pr-3 opacity-0"
                    style={"animation-delay: #{idx * 60}ms"}
                    title={provider.name}
                  >
                    <span class="truncate text-sm font-medium text-gray-500">
                      {truncate_provider(provider.name)}
                    </span>
                  </div>
                <% end %>
              </div>
              
    <!-- Grid container -->
              <div class="bg-gray-950/40 relative overflow-hidden rounded-2xl border border-gray-800 p-1.5 shadow-2xl">
                <!-- Inner glow effect -->
                <div class="from-sky-500/10 pointer-events-none absolute inset-0 bg-gradient-to-b to-transparent opacity-50">
                </div>

                <div class="bg-gray-950/50 flex gap-3 rounded-xl p-4">
                  <div class="relative flex flex-col gap-2">
                    <%= for {provider, row_idx} <- Enum.with_index(@display_providers) do %>
                      <div class="flex gap-2">
                        <%= for {method, col_idx} <- Enum.with_index(@display_methods) do %>
                          <% latency =
                            get_best_latency(provider.method_latencies, method, @original_methods) %>
                          <% thresholds = Map.get(@method_thresholds, method, {50, 100}) %>
                          <% cell_idx = row_idx * @method_count + col_idx %>
                          <% should_pulse = rem(cell_idx, 13) == 0 %>
                          <div
                            class={["heatmap-cell font-mono flex h-10 w-16 items-center justify-center rounded-md text-xs font-semibold transition-all duration-200 hover:z-10 hover:scale-110", if(should_pulse and @is_live, do: "cell-pulse", else: ""), latency_cell_class(latency, thresholds)]}
                            title={"#{provider.name} / #{method}: #{format_latency(latency)}"}
                          >
                            <%= if latency do %>
                              <span class={latency_text_class(latency, thresholds)}>
                                {format_latency_short(latency)}
                              </span>
                            <% else %>
                              <span class="text-gray-600">—</span>
                            <% end %>
                          </div>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                  
    <!-- Dynamic legend -->
                  <div class="flex flex-col gap-4 pl-2 text-xs">
                    <span class="flex items-center gap-2">
                      <span class="border-emerald-500/40 bg-emerald-500/10 h-3 w-3 rounded border">
                      </span>
                      <span class="text-gray-400">fast</span>
                    </span>
                    <span class="flex items-center gap-2">
                      <span class="border-amber-500/40 bg-amber-500/10 h-3 w-3 rounded border"></span>
                      <span class="text-gray-400">avg</span>
                    </span>
                    <span class="flex items-center gap-2">
                      <span class="border-red-500/40 bg-red-500/10 h-3 w-3 rounded border"></span>
                      <span class="text-gray-400">slow</span>
                    </span>
                  </div>
                </div>
                
    <!-- Footer row: legend left, link right -->
                <div class="relative flex items-center justify-between px-3 py-3">
                  <div class="flex items-center gap-3">
                    <div class="shadow-[0_0_8px_rgba(16,185,129,0.6)] h-2 w-2 animate-pulse rounded-full bg-emerald-500">
                    </div>
                    <h3 class="text-sm font-semibold uppercase tracking-wider text-gray-300">
                      Live Method-Level Latency Benchmarks (ms)
                    </h3>
                    <span class="text-sm text-gray-400">&bull;</span>
                    <span class="text-sm text-gray-400">
                      {@chain_name}
                    </span>
                  </div>

                  <a
                    href="/dashboard?tab=metrics"
                    class="group bg-gray-800/50 flex items-center gap-2 rounded-md px-3 py-1.5 text-xs font-medium text-gray-300 transition-all hover:bg-sky-500/10 hover:text-sky-300"
                  >
                    Full metrics
                    <svg
                      class="h-3.5 w-3.5 transition-transform group-hover:translate-x-0.5"
                      fill="none"
                      stroke="currentColor"
                      viewBox="0 0 24 24"
                    >
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2"
                        d="M9 5l7 7-7 7"
                      />
                    </svg>
                  </a>
                </div>
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # Calculate thresholds for each method independently
  defp calculate_method_thresholds(providers, display_methods, original_methods) do
    Map.new(display_methods, fn method ->
      latencies =
        providers
        |> Enum.map(fn provider ->
          get_best_latency(provider.method_latencies, method, original_methods)
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.reject(&(&1 == 0))

      {method, calculate_thresholds(latencies)}
    end)
  end

  # Calculate dynamic thresholds based on percentiles
  defp calculate_thresholds([]), do: {50, 100}

  defp calculate_thresholds(latencies) do
    sorted = Enum.sort(latencies)
    count = length(sorted)

    # Use 33rd and 66th percentiles for balanced distribution
    p33_idx = max(0, div(count, 3) - 1)
    p66_idx = max(0, div(count * 2, 3) - 1)

    p33 = Enum.at(sorted, p33_idx, 50)
    p66 = Enum.at(sorted, p66_idx, 100)

    # Ensure minimum separation
    p33 = max(p33, 10)
    p66 = max(p66, p33 + 20)

    {p33, p66}
  end

  # Extract base method name without @http/@ws suffix
  defp extract_base_method(method) do
    method
    |> String.replace(~r/@(http|ws)$/, "")
  end

  # Get the best (lowest) latency for a base method across all variants (@http, @ws, etc.)
  defp get_best_latency(method_latencies, base_method, original_methods)
       when is_map(method_latencies) do
    matching_methods =
      original_methods
      |> Enum.filter(fn m -> extract_base_method(m) == base_method end)

    latencies =
      matching_methods
      |> Enum.map(fn m -> Map.get(method_latencies, m) end)
      |> Enum.reject(&is_nil/1)

    case latencies do
      [] -> nil
      vals -> Enum.min(vals)
    end
  end

  defp get_best_latency(_, _, _), do: nil

  # Returns CSS classes for heatmap cell based on dynamic thresholds
  defp latency_cell_class(nil, _thresholds), do: "border border-gray-800/50 bg-gray-900/30"

  defp latency_cell_class(latency, {low, high}) do
    cond do
      latency <= low -> "border border-emerald-500/40 bg-emerald-500/5"
      latency <= high -> "border border-amber-500/40 bg-amber-500/5"
      true -> "border border-red-500/40 bg-red-500/5"
    end
  end

  # Returns CSS classes for latency text based on dynamic thresholds
  defp latency_text_class(nil, _thresholds), do: "text-gray-600"

  defp latency_text_class(latency, {low, high}) do
    cond do
      latency <= low -> "text-emerald-400 shadow-[0_0_10px_rgba(52,211,153,0.15)]"
      latency <= high -> "text-amber-400 shadow-[0_0_10px_rgba(251,191,36,0.15)]"
      true -> "text-red-400 shadow-[0_0_10px_rgba(248,113,113,0.15)]"
    end
  end

  # Format latency for display in cells (compact)
  defp format_latency_short(nil), do: "—"
  defp format_latency_short(latency) when latency < 1000, do: "#{round(latency)}"
  defp format_latency_short(latency), do: "#{Float.round(latency / 1000, 1)}s"

  # Format latency for tooltip
  defp format_latency(nil), do: "No data"
  defp format_latency(latency), do: "#{round(latency)}ms"

  # Truncate provider name for row labels
  defp truncate_provider(name) do
    name
    |> String.replace("_ethereum", "")
    |> String.replace("_eth", "")
    |> String.replace("Ethereum", "")
    |> String.split(~r/[\s_-]/)
    |> List.first()
    |> String.slice(0, 12)
  end

  # Format method name for display (full name, just remove eth_ prefix)
  defp format_method_display(method) do
    method
  end
end
