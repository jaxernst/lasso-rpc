defmodule LassoWeb.Components.DashboardComponents do
  @moduledoc """
  Helper components for the dashboard UI, extracted for better organization.
  """

  use Phoenix.Component

  # Floating Chain Configuration Window (top-left)
  def floating_chain_config_window(assigns) do
    assigns =
      assigns
      |> assign_new(:chain_config_open, fn -> false end)
      |> assign_new(:chain_config_collapsed, fn -> true end)
      |> assign_new(:config_selected_chain, fn -> nil end)
      |> assign_new(:config_form_data, fn -> %{} end)
      |> assign_new(:config_validation_errors, fn -> [] end)
      |> assign_new(:available_chains, fn -> [] end)
      |> assign_new(:config_expanded_providers, fn -> MapSet.new() end)

    ~H"""
    <div class={["pointer-events-none absolute top-4 left-4 z-40 transition-all duration-300", if(@chain_config_open,
    do: if(@chain_config_collapsed, do: "h-12 w-80", else: "w-[28rem] h-[32rem]"),
    else: "pointer-events-none h-12 w-80 scale-90 opacity-0")]}>
      <div class={["border-gray-700/60 bg-gray-900/95 pointer-events-auto rounded-xl border shadow-2xl backdrop-blur-lg", "transition-all duration-300", if(!@chain_config_open, do: "scale-90 opacity-0")]}>
        <!-- Header / Collapsed State -->
        <div class="border-gray-700/50 flex items-center justify-between border-b px-4 py-2">
          <div class="flex min-w-0 items-center gap-2">
            <div class="h-2 w-2 rounded-full bg-purple-400"></div>
            <div class="truncate text-sm font-medium text-gray-200">Chain Configuration</div>
            <%= if @chain_config_collapsed do %>
              <div class="text-xs text-gray-400">
                ({length(@available_chains)} chains)
              </div>
            <% end %>
          </div>
          <div class="flex items-center gap-2">
            <button
              phx-click="toggle_chain_config_collapsed"
              class="bg-gray-800/60 rounded px-2 py-1 text-xs text-gray-200 transition-colors hover:bg-gray-700/60"
            >
              {if @chain_config_collapsed, do: "↙", else: "↖"}
            </button>
            <button
              phx-click="close_chain_config"
              class="bg-gray-800/60 rounded px-2 py-1 text-xs text-gray-200 transition-colors hover:bg-gray-700/60"
            >
              ×
            </button>
          </div>
        </div>

        <%= unless @chain_config_collapsed do %>
          <!-- Expanded Three-Panel Layout -->
          <div class="h-[28rem] flex flex-col">
            <!-- Chain List Panel -->
            <div class="border-gray-700/50 h-40 border-b p-3">
              <div class="mb-2 flex items-center justify-between">
                <h4 class="text-sm font-semibold text-gray-300">Configured Chains</h4>
                <button
                  phx-click="toggle_quick_add"
                  class="rounded bg-purple-600 px-2 py-1 text-xs text-white transition-colors hover:bg-purple-500"
                >
                  + Add Provider
                </button>
              </div>
              <div class="max-h-24 space-y-1 overflow-y-auto">
                <%= for chain <- @available_chains do %>
                  <button
                    phx-click="select_config_chain"
                    phx-value-chain={chain.name}
                    class={["flex w-full items-center justify-between rounded px-2 py-1.5 text-left text-xs transition-colors", if(@config_selected_chain == chain.name,
    do: "bg-purple-600/20 border-purple-600/40 border text-purple-200",
    else: "bg-gray-800/40 text-gray-300 hover:bg-gray-700/60")]}
                  >
                    <div>
                      <div class="font-medium">{String.capitalize(chain.name)}</div>
                      <div class="text-gray-400">Chain ID: {chain.chain_id || "—"}</div>
                    </div>
                    <div class="text-xs text-gray-400">{length(chain.providers || [])} providers</div>
                  </button>
                <% end %>
                <%= if Enum.empty?(@available_chains) do %>
                  <div class="py-4 text-center text-xs text-gray-500">
                    No chains configured
                  </div>
                <% end %>
              </div>
            </div>
            
    <!-- Configuration Form Panel -->
            <div class="flex-1 overflow-y-auto p-3">
              <%= if @quick_add_open do %>
                <.quick_add_provider_form quick_add_data={@quick_add_data} />
              <% else %>
                <%= if @config_selected_chain do %>
                  <.chain_config_form
                    selected_chain={@config_selected_chain}
                    form_data={@config_form_data}
                    validation_errors={@config_validation_errors}
                    expanded={@config_expanded_providers}
                  />
                <% else %>
                  <div class="py-8 text-center text-sm text-gray-500">
                    <svg
                      class="mx-auto mb-3 h-12 w-12 text-gray-600"
                      fill="none"
                      stroke="currentColor"
                      viewBox="0 0 24 24"
                    >
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="1.5"
                        d="M19.428 15.428a2 2 0 00-1.022-.547l-2.387-.477a6 6 0 00-3.86.517l-.318.158a6 6 0 01-3.86.517L6.05 15.21a2 2 0 00-1.806.547M8 4h8l-1 1v5.172a2 2 0 00.586 1.414l5 5c1.26 1.26.367 3.414-1.415 3.414H4.828c-1.782 0-2.674-2.154-1.414-3.414l5-5A2 2 0 009 10.172V5L8 4z"
                      />
                    </svg>
                    <p>Select a chain to configure</p>
                    <p class="mt-1 text-xs text-gray-600">or add a provider</p>
                  </div>
                <% end %>
              <% end %>
            </div>
            
    <!-- Action Buttons Panel -->
            <div class="border-gray-700/50 flex items-center justify-between border-t p-3">
              <div class="flex items-center space-x-2">
                <%= if @config_selected_chain do %>
                  <button
                    phx-click="test_chain_config"
                    class="rounded bg-blue-600 px-3 py-1.5 text-xs text-white transition-colors hover:bg-blue-500"
                  >
                    Test Connection
                  </button>
                  <button
                    phx-click="delete_chain_config"
                    class="rounded bg-red-600 px-3 py-1.5 text-xs text-white transition-colors hover:bg-red-500"
                  >
                    Delete Chain
                  </button>
                <% end %>
              </div>
              <div class="flex items-center space-x-2">
                <button
                  type="submit"
                  form="chain-config-form"
                  class="rounded bg-emerald-600 px-3 py-1.5 text-xs font-medium text-white transition-colors hover:bg-emerald-500"
                >
                  Save Changes
                </button>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  def chain_config_form(assigns) do
    assigns =
      assigns
      |> assign_new(:selected_chain, fn -> nil end)
      |> assign_new(:form_data, fn -> %{} end)
      |> assign_new(:validation_errors, fn -> [] end)
      |> assign_new(:expanded, fn -> MapSet.new() end)

    ~H"""
    <form
      id="chain-config-form"
      phx-change="config_form_change"
      phx-submit="save_chain_config"
      class="space-y-4"
    >
      <div class="text-sm font-medium text-gray-300">
        Configure: <span class="text-purple-300">{String.capitalize(@selected_chain)}</span>
      </div>
      
    <!-- Basic Chain Information -->
      <div class="grid grid-cols-2 gap-3">
        <div class="col-span-2">
          <label class="text-[11px] mb-1 block font-medium text-gray-400">Chain Name</label>
          <input
            type="text"
            name="chain[name]"
            value={Map.get(@form_data, :name, String.capitalize(@selected_chain))}
            phx-debounce="300"
            class="bg-gray-800/80 border-gray-600/70 w-full rounded border px-3 py-2 text-sm text-white placeholder-gray-500 focus:border-purple-500 focus:ring-1 focus:ring-purple-500"
            placeholder="e.g., Ethereum Mainnet"
          />
        </div>
        <div>
          <label class="text-[11px] mb-1 block font-medium text-gray-400">Chain ID</label>
          <input
            type="number"
            name="chain[chain_id]"
            value={Map.get(@form_data, :chain_id, "")}
            phx-debounce="300"
            class="bg-gray-800/80 border-gray-600/70 w-full rounded border px-3 py-2 text-sm text-white placeholder-gray-500 focus:border-purple-500 focus:ring-1 focus:ring-purple-500"
            placeholder="1"
          />
        </div>
        <div>
          <label class="text-[11px] mb-1 block font-medium text-gray-400">Block Time (ms)</label>
          <input
            type="number"
            name="chain[block_time]"
            value={Map.get(@form_data, :block_time, 12000)}
            phx-debounce="300"
            class="bg-gray-800/80 border-gray-600/70 w-full rounded border px-3 py-2 text-sm text-white placeholder-gray-500 focus:border-purple-500 focus:ring-1 focus:ring-purple-500"
            placeholder="12000"
          />
        </div>
      </div>
      
    <!-- Providers Section -->
      <div class="space-y-2">
        <div class="flex items-center justify-between">
          <label class="text-[11px] block font-medium text-gray-400">Providers</label>
          <button
            type="button"
            phx-click="add_provider"
            class="rounded bg-purple-600 px-2 py-1 text-xs text-white transition-colors hover:bg-purple-500"
          >
            + Add Provider
          </button>
        </div>

        <div class="max-h-40 space-y-2 overflow-y-auto pr-1">
          <%= for {provider, idx} <- Enum.with_index(Map.get(@form_data, :providers, [])) do %>
            <div class="bg-gray-800/60 border-gray-700/70 rounded border">
              <div class="flex items-center justify-between px-2 py-2">
                <button
                  type="button"
                  phx-click="toggle_provider_row"
                  phx-value-index={idx}
                  class="flex flex-1 items-center gap-2 text-left"
                >
                  <svg
                    class={["h-3 w-3 transition-transform", if(MapSet.member?(@expanded, idx),
    do: "rotate-90 text-purple-300",
    else: "text-gray-400")]}
                    viewBox="0 0 20 20"
                    fill="currentColor"
                  >
                    <path d="M6 6l6 4-6 4V6z" />
                  </svg>
                  <span class="truncate text-sm text-white">
                    {provider.name || "Provider #{idx + 1}"}
                  </span>
                </button>
                <button
                  type="button"
                  phx-click="remove_provider"
                  phx-value-index={idx}
                  class="px-2 text-xs text-rose-400 hover:text-rose-300"
                >
                  Remove
                </button>
              </div>
              <%= if MapSet.member?(@expanded, idx) do %>
                <div class="border-gray-700/60 space-y-2 border-t p-2">
                  <div class="grid grid-cols-1 gap-2">
                    <input
                      type="url"
                      name={"chain[providers][#{idx}][url]"}
                      placeholder="https://rpc.example.com"
                      value={provider.url || ""}
                      phx-debounce="300"
                      class="bg-gray-900/60 border-gray-600/70 w-full rounded border px-2 py-1.5 text-xs text-white placeholder-gray-500 focus:border-sky-500 focus:ring-1 focus:ring-sky-500"
                    />
                    <input
                      type="url"
                      name={"chain[providers][#{idx}][ws_url]"}
                      placeholder="wss://ws.example.com (optional)"
                      value={provider.ws_url || ""}
                      phx-debounce="300"
                      class="bg-gray-900/60 border-gray-600/70 w-full rounded border px-2 py-1.5 text-xs text-white placeholder-gray-500 focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500"
                    />
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>

          <%= if Enum.empty?(Map.get(@form_data, :providers, [])) do %>
            <div class="py-2 text-center text-xs text-gray-500">
              No providers configured
            </div>
          <% end %>
        </div>
      </div>
      
    <!-- Validation Errors -->
      <%= if not Enum.empty?(@validation_errors) do %>
        <div class="bg-red-900/20 border-red-600/40 rounded border p-2">
          <div class="mb-1 text-xs font-medium text-red-400">Validation Errors:</div>
          <%= for error <- @validation_errors do %>
            <div class="text-xs text-red-300">• {error}</div>
          <% end %>
        </div>
      <% end %>
    </form>
    """
  end

  def quick_add_provider_form(assigns) do
    assigns =
      assigns
      |> assign_new(:quick_add_data, fn -> %{} end)

    ~H"""
    <form
      id="quick-add-form"
      phx-change="quick_add_change"
      phx-submit="quick_add_submit"
      class="space-y-3"
    >
      <div class="text-sm font-semibold text-gray-300">Add Provider</div>
      <div class="grid grid-cols-2 gap-2">
        <div>
          <label class="text-[11px] mb-1 block text-gray-400">Chain Name</label>
          <input
            type="text"
            name="qa[name]"
            value={Map.get(@quick_add_data, :name, "")}
            placeholder="e.g., Arbitrum"
            phx-debounce="300"
            class="bg-gray-800/80 border-gray-600/70 w-full rounded border px-3 py-2 text-sm text-white placeholder-gray-500 focus:border-purple-500 focus:ring-1 focus:ring-purple-500"
          />
        </div>
        <div>
          <label class="text-[11px] mb-1 block text-gray-400">Chain ID</label>
          <input
            type="number"
            name="qa[chain_id]"
            value={Map.get(@quick_add_data, :chain_id, "")}
            placeholder="42161"
            phx-debounce="300"
            class="bg-gray-800/80 border-gray-600/70 w-full rounded border px-3 py-2 text-sm text-white placeholder-gray-500 focus:border-purple-500 focus:ring-1 focus:ring-purple-500"
          />
        </div>
        <div class="col-span-2">
          <label class="text-[11px] mb-1 block text-gray-400">HTTP URL</label>
          <input
            type="url"
            name="qa[url]"
            value={Map.get(@quick_add_data, :url, "")}
            placeholder="https://rpc.example.com"
            phx-debounce="300"
            class="bg-gray-900/60 border-gray-600/70 w-full rounded border px-3 py-2 text-sm text-white placeholder-gray-500 focus:border-sky-500 focus:ring-1 focus:ring-sky-500"
          />
        </div>
        <div class="col-span-2">
          <label class="text-[11px] mb-1 block text-gray-400">WS URL (optional)</label>
          <input
            type="url"
            name="qa[ws_url]"
            value={Map.get(@quick_add_data, :ws_url, "")}
            placeholder="wss://ws.example.com"
            phx-debounce="300"
            class="bg-gray-900/60 border-gray-600/70 w-full rounded border px-3 py-2 text-sm text-white placeholder-gray-500 focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500"
          />
        </div>
      </div>
      <div class="flex items-center justify-end gap-2 pt-2">
        <button
          type="button"
          phx-click="toggle_quick_add"
          class="bg-gray-700/80 rounded px-3 py-1.5 text-xs text-gray-200 hover:bg-gray-600"
        >
          Cancel
        </button>
        <button
          type="submit"
          form="quick-add-form"
          class="rounded bg-emerald-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-emerald-500"
        >
          Add Provider
        </button>
      </div>
    </form>
    """
  end

  def benchmarks_tab_content(assigns) do
    ~H"""
    <div class="flex h-full w-full flex-col gap-4 p-4">
      <div class="border-gray-700/50 bg-gray-900/50 rounded-lg border p-6">
        <div class="text-sm font-semibold text-gray-300">Benchmarks</div>
        <div class="mt-2 text-xs text-gray-400">
          Coming soon: provider leaderboard, method x provider latency heatmap, and strategy comparisons.
        </div>
      </div>
    </div>
    """
  end

  def metrics_tab_content(assigns) do
    assigns =
      assigns
      |> assign_new(:vm_metrics, fn -> %{} end)
      |> assign_new(:last_updated, fn -> "Never" end)
      |> assign_new(:connections, fn -> [] end)
      |> assign_new(:routing_events, fn -> [] end)
      |> assign_new(:provider_events, fn -> [] end)

    ~H"""
    <div class="flex h-full w-full flex-col gap-4 p-4">
      <div class="border-gray-700/50 bg-gray-900/50 rounded-lg border p-3">
        <div class="mb-2 text-sm font-semibold text-gray-300">System metrics</div>
        <div class="grid grid-cols-1 gap-2 text-sm text-gray-300 md:grid-cols-3">
          <div class="bg-gray-800/60 rounded p-3">
            Connections: <span class="text-emerald-300">{length(@connections)}</span>
          </div>
          <div class="bg-gray-800/60 rounded p-3">
            Routing events buffered: <span class="text-sky-300">{length(@routing_events)}</span>
          </div>
          <div class="bg-gray-800/60 rounded p-3">
            Provider events buffered: <span class="text-yellow-300">{length(@provider_events)}</span>
          </div>
        </div>
        <div class="mt-4 grid grid-cols-1 gap-2 text-sm text-gray-300 md:grid-cols-3">
          <div class="bg-gray-800/60 rounded p-3">
            CPU:
            <span class="text-emerald-300">
              {(@vm_metrics[:cpu_percent] || 0.0) |> :erlang.float_to_binary([{:decimals, 1}])}%
            </span>
          </div>
          <div class="bg-gray-800/60 rounded p-3">
            Run queue: <span class="text-emerald-300">{@vm_metrics[:run_queue] || 0}</span>
          </div>
          <div class="bg-gray-800/60 rounded p-3">
            Reductions/s: <span class="text-emerald-300">{@vm_metrics[:reductions_s] || 0}</span>
          </div>
          <div class="bg-gray-800/60 rounded p-3">
            Proc count: <span class="text-emerald-300">{@vm_metrics[:process_count] || 0}</span>
          </div>
          <div class="bg-gray-800/60 rounded p-3">
            Port count: <span class="text-emerald-300">{@vm_metrics[:port_count] || 0}</span>
          </div>
          <div class="bg-gray-800/60 rounded p-3">
            Atom count: <span class="text-emerald-300">{@vm_metrics[:atom_count] || 0}</span>
          </div>
          <div class="bg-gray-800/60 rounded p-3">
            ETS tables: <span class="text-emerald-300">{@vm_metrics[:ets_count] || 0}</span>
          </div>
          <div class="bg-gray-800/60 rounded p-3">
            Mem total: <span class="text-emerald-300">{@vm_metrics[:mem_total_mb] || 0} MB</span>
          </div>
          <div class="bg-gray-800/60 rounded p-3">
            Mem processes:
            <span class="text-emerald-300">{@vm_metrics[:mem_processes_mb] || 0} MB</span>
          </div>
          <div class="bg-gray-800/60 rounded p-3">
            Mem binary: <span class="text-emerald-300">{@vm_metrics[:mem_binary_mb] || 0} MB</span>
          </div>
          <div class="bg-gray-800/60 rounded p-3">
            Mem code: <span class="text-emerald-300">{@vm_metrics[:mem_code_mb] || 0} MB</span>
          </div>
          <div class="bg-gray-800/60 rounded p-3">
            Mem ETS: <span class="text-emerald-300">{@vm_metrics[:mem_ets_mb] || 0} MB</span>
          </div>
          <div class="bg-gray-800/60 rounded p-3">
            IO in: <span class="text-emerald-300">{@vm_metrics[:io_in_mb] || 0} MB</span>
          </div>
          <div class="bg-gray-800/60 rounded p-3">
            IO out: <span class="text-emerald-300">{@vm_metrics[:io_out_mb] || 0} MB</span>
          </div>
          <div class="bg-gray-800/60 rounded p-3">
            Sched util avg:
            <span class="text-emerald-300">
              {(@vm_metrics[:sched_util_avg] &&
                  :erlang.float_to_binary(@vm_metrics[:sched_util_avg], [{:decimals, 1}])) || "n/a"}%
            </span>
          </div>
        </div>
        <div class="mt-2 text-xs text-gray-500">Last updated: {@last_updated}</div>
      </div>
    </div>
    """
  end
end
