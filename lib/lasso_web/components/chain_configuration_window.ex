defmodule LassoWeb.Components.ChainConfigurationWindow do
  @moduledoc """
  A stateful LiveComponent for chain configuration management.
  This component handles its own state, events, and PubSub subscriptions for chain configuration.
  """

  use LassoWeb, :live_component
  require Logger

  alias Lasso.Config.ChainConfigManager
  alias Lasso.Config.ConfigValidator

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    collapsed_state =
      Map.get(assigns, :is_collapsed, socket.assigns[:chain_config_collapsed] || true)

    socket =
      socket
      |> assign(assigns)
      |> assign(:chain_config_collapsed, collapsed_state)

    # Load available chains when needed
    socket =
      if socket.assigns[:available_chains] == [] or is_nil(socket.assigns[:available_chains]) do
        load_available_chains(socket)
      else
        socket
      end

    # Auto-select chain/provider when expanding and context is available
    socket =
      if not collapsed_state and
           (Map.get(assigns, :selected_chain) || Map.get(assigns, :selected_provider)) do
        auto_select_context(socket, assigns)
      else
        socket
        |> assign_new(:config_selected_chain, fn -> nil end)
        |> assign_new(:config_form_data, fn -> %{} end)
        |> assign_new(:config_validation_errors, fn -> [] end)
        |> assign_new(:config_expanded_providers, fn -> MapSet.new() end)
        |> assign_new(:quick_add_open, fn -> false end)
        |> assign_new(:quick_add_data, fn -> %{} end)
      end

    {:ok, socket}
  end

  defp auto_select_context(socket, assigns) do
    selected_chain = Map.get(assigns, :selected_chain)

    if selected_chain do
      # Load the selected chain configuration
      case ChainConfigManager.get_chain(selected_chain) do
        {:ok, config} ->
          form_data = %{
            name: config.name,
            chain_id: config.chain_id,
            block_time: config.block_time,
            providers:
              Enum.map(config.providers, fn provider ->
                %{
                  id: provider.id,
                  name: provider.name,
                  url: provider.url,
                  ws_url: provider.ws_url,
                  priority: provider.priority,
                  type: provider.type,
                  api_key_required: provider.api_key_required,
                  region: provider.region
                }
              end)
          }

          socket
          |> assign(:config_selected_chain, selected_chain)
          |> assign(:config_form_data, form_data)
          |> assign(:config_validation_errors, [])
          |> assign(:config_expanded_providers, MapSet.new())
          |> assign(:quick_add_open, false)
          |> assign(:quick_add_data, %{})

        {:error, _} ->
          socket
          |> assign(:config_selected_chain, nil)
          |> assign(:config_form_data, %{})
          |> assign(:config_validation_errors, [])
          |> assign(:config_expanded_providers, MapSet.new())
          |> assign(:quick_add_open, false)
          |> assign(:quick_add_data, %{})
      end
    else
      socket
      |> assign(:config_selected_chain, nil)
      |> assign(:config_form_data, %{})
      |> assign(:config_validation_errors, [])
      |> assign(:config_expanded_providers, MapSet.new())
      |> assign(:quick_add_open, false)
      |> assign(:quick_add_data, %{})
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class={["pointer-events-none absolute bottom-4 left-4 z-40 transition-all duration-300", if(@chain_config_collapsed, do: "h-12 w-96", else: "w-[32rem] h-[36rem]")]}>
      <div class="border-gray-700/60 bg-gray-900/95 pointer-events-auto rounded-xl border shadow-2xl backdrop-blur-lg transition-all duration-300">
        <!-- Header / Collapsed State -->
        <div class="border-gray-700/50 flex items-center justify-between border-b px-4 py-2">
          <div class="flex min-w-0 flex-1 items-center gap-2">
            <div class="h-2 w-2 flex-shrink-0 rounded-full bg-purple-400"></div>
            <div class="flex-shrink-0 text-sm font-medium text-gray-200">Provider Configuration</div>
            <%= if @chain_config_collapsed do %>
              <div class="flex items-center space-x-2 whitespace-nowrap text-xs text-gray-400">
                <span class="text-purple-300">{length(@available_chains)} chains</span>
                <span>•</span>
                <span class="text-emerald-300">
                  {length(Map.get(assigns, :connections, []))} providers
                </span>
              </div>
            <% end %>
          </div>
          <div class="ml-2 flex items-center gap-2">
            <button
              phx-click="toggle_collapsed"
              phx-target={@myself}
              class="bg-gray-800/60 rounded px-2 py-1 text-xs text-gray-200 transition-all hover:bg-gray-700/60"
            >
              <div class={["transition-transform duration-200", if(@chain_config_collapsed, do: "rotate-0", else: "rotate-180")]}>
                ↗
              </div>
            </button>
          </div>
        </div>

        <%= unless @chain_config_collapsed do %>
          <!-- Expanded Layout -->
          <div class="h-[32rem] flex flex-col">
            <!-- Chain List Panel -->
            <div class="border-gray-700/50 h-44 border-b p-3">
              <div class="mb-3 flex items-center justify-between">
                <h4 class="text-sm font-semibold text-gray-300">Configured Chains</h4>
                <div class="flex items-center gap-2">
                  <button
                    phx-click="add_new_chain"
                    phx-target={@myself}
                    class="rounded bg-emerald-600 px-2 py-1 text-xs text-white transition-colors hover:bg-emerald-500"
                  >
                    + New Chain
                  </button>
                  <button
                    phx-click="toggle_quick_add"
                    phx-target={@myself}
                    class="rounded bg-purple-600 px-2 py-1 text-xs text-white transition-colors hover:bg-purple-500"
                  >
                    + Add Provider
                  </button>
                </div>
              </div>
              <div class="max-h-28 space-y-1 overflow-y-auto">
                <%= for chain <- @available_chains do %>
                  <button
                    phx-click="select_chain"
                    phx-value-chain={chain.name}
                    phx-target={@myself}
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
                    No chains configured. Click "New Chain" to get started.
                  </div>
                <% end %>
              </div>
            </div>
            
    <!-- Configuration Form Panel -->
            <div class="flex-1 overflow-y-auto p-3">
              <%= if @quick_add_open do %>
                <.quick_add_form quick_add_data={@quick_add_data} myself={@myself} />
              <% else %>
                <%= if @config_selected_chain do %>
                  <.chain_form
                    selected_chain={@config_selected_chain}
                    form_data={@config_form_data}
                    validation_errors={@config_validation_errors}
                    expanded={@config_expanded_providers}
                    myself={@myself}
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
                        d="M9 12l2 2 4-4M7.835 4.697a3.42 3.42 0 001.946-.806 3.42 3.42 0 014.438 0 3.42 3.42 0 001.946.806 3.42 3.42 0 013.138 3.138 3.42 3.42 0 00.806 1.946 3.42 3.42 0 010 4.438 3.42 3.42 0 00-.806 1.946 3.42 3.42 0 01-3.138 3.138 3.42 3.42 0 00-1.946.806 3.42 3.42 0 01-4.438 0 3.42 3.42 0 00-1.946-.806 3.42 3.42 0 01-3.138-3.138 3.42 3.42 0 00-.806-1.946 3.42 3.42 0 010-4.438 3.42 3.42 0 00.806-1.946A3.42 3.42 0 017.835 4.697z"
                      />
                    </svg>
                    <p>Select a chain to configure</p>
                    <p class="mt-1 text-xs text-gray-600">or add a provider quickly</p>
                  </div>
                <% end %>
              <% end %>
            </div>
            
    <!-- Action Buttons Panel -->
            <div class="border-gray-700/50 flex items-center justify-between border-t p-3">
              <div class="flex items-center space-x-2">
                <%= if @config_selected_chain && @config_selected_chain != "new_chain" do %>
                  <button
                    phx-click="test_connection"
                    phx-target={@myself}
                    class="rounded bg-blue-600 px-3 py-1.5 text-xs text-white transition-colors hover:bg-blue-500"
                  >
                    Test Connection
                  </button>
                  <button
                    phx-click="delete_chain"
                    phx-target={@myself}
                    class="rounded bg-red-600 px-3 py-1.5 text-xs text-white transition-colors hover:bg-red-500"
                  >
                    Delete Chain
                  </button>
                <% end %>
              </div>
              <div class="flex items-center space-x-2">
                <%= if @config_selected_chain do %>
                  <button
                    phx-click="save_config"
                    phx-target={@myself}
                    class="rounded bg-emerald-600 px-3 py-1.5 text-xs font-medium text-white transition-colors hover:bg-emerald-500"
                  >
                    Save Changes
                  </button>
                <% end %>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # Chain configuration form
  defp chain_form(assigns) do
    ~H"""
    <div class="space-y-4" id="chain-config-form">
      <div class="text-sm font-medium text-gray-300">
        <%= if @selected_chain == "new_chain" do %>
          Create New Chain
        <% else %>
          Configure: <span class="text-purple-300">{String.capitalize(@selected_chain)}</span>
        <% end %>
      </div>
      
    <!-- Basic Chain Information -->
      <div class="grid grid-cols-2 gap-3">
        <div class="col-span-2">
          <label class="text-[11px] mb-1 block font-medium text-gray-400">Chain Name</label>
          <input
            type="text"
            phx-change="update_field"
            phx-value-field="name"
            phx-target={@myself}
            value={Map.get(@form_data, :name, "")}
            phx-debounce="300"
            class="bg-gray-800/80 border-gray-600/70 w-full rounded border px-3 py-2 text-sm text-white placeholder-gray-500 focus:border-purple-500 focus:ring-1 focus:ring-purple-500"
            placeholder="e.g., Ethereum Mainnet"
          />
        </div>
        <div>
          <label class="text-[11px] mb-1 block font-medium text-gray-400">Chain ID</label>
          <input
            type="number"
            phx-change="update_field"
            phx-value-field="chain_id"
            phx-target={@myself}
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
            phx-change="update_field"
            phx-value-field="block_time"
            phx-target={@myself}
            value={Map.get(@form_data, :block_time, 12_000)}
            phx-debounce="300"
            class="bg-gray-800/80 border-gray-600/70 w-full rounded border px-3 py-2 text-sm text-white placeholder-gray-500 focus:border-purple-500 focus:ring-1 focus:ring-purple-500"
            placeholder="12_000"
          />
        </div>
      </div>
      
    <!-- Providers Section -->
      <div class="space-y-2">
        <div class="flex items-center justify-between">
          <label class="text-[11px] block font-medium text-gray-400">RPC Providers</label>
          <button
            type="button"
            phx-click="add_provider"
            phx-target={@myself}
            class="rounded bg-purple-600 px-2 py-1 text-xs text-white transition-colors hover:bg-purple-500"
          >
            + Add Provider
          </button>
        </div>

        <div class="max-h-44 space-y-2 overflow-y-auto pr-1">
          <%= for {provider, idx} <- Enum.with_index(Map.get(@form_data, :providers, [])) do %>
            <div class="bg-gray-800/60 border-gray-700/70 rounded border">
              <div class="flex items-center justify-between px-3 py-2">
                <button
                  type="button"
                  phx-click="toggle_provider"
                  phx-value-index={idx}
                  phx-target={@myself}
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
                  <div class={["ml-2 h-2 w-2 rounded-full", if(provider.url && provider.url != "", do: "bg-emerald-400", else: "bg-red-400")]}>
                  </div>
                </button>
                <button
                  type="button"
                  phx-click="remove_provider"
                  phx-value-index={idx}
                  phx-target={@myself}
                  class="px-2 text-xs text-rose-400 hover:text-rose-300"
                >
                  Remove
                </button>
              </div>
              <%= if MapSet.member?(@expanded, idx) do %>
                <div class="border-gray-700/60 space-y-3 border-t p-3">
                  <div>
                    <label class="text-[10px] mb-1 block text-gray-400">Provider Name</label>
                    <input
                      type="text"
                      phx-change="update_provider"
                      phx-value-index={idx}
                      phx-value-field="name"
                      phx-target={@myself}
                      placeholder="e.g., Alchemy, Infura, etc."
                      value={provider.name || ""}
                      phx-debounce="300"
                      class="bg-gray-900/60 border-gray-600/70 w-full rounded border px-2 py-1.5 text-xs text-white placeholder-gray-500 focus:border-emerald-500 focus:ring-1 focus:ring-emerald-500"
                    />
                  </div>
                  <div>
                    <label class="text-[10px] mb-1 block text-gray-400">HTTP RPC URL</label>
                    <input
                      type="url"
                      phx-change="update_provider"
                      phx-value-index={idx}
                      phx-value-field="url"
                      phx-target={@myself}
                      placeholder="https://rpc.example.com"
                      value={provider.url || ""}
                      phx-debounce="300"
                      class="bg-gray-900/60 border-gray-600/70 w-full rounded border px-2 py-1.5 text-xs text-white placeholder-gray-500 focus:border-sky-500 focus:ring-1 focus:ring-sky-500"
                    />
                  </div>
                  <div>
                    <label class="text-[10px] mb-1 block text-gray-400">
                      WebSocket URL (Optional)
                    </label>
                    <input
                      type="url"
                      phx-change="update_provider"
                      phx-value-index={idx}
                      phx-value-field="ws_url"
                      phx-target={@myself}
                      placeholder="wss://ws.example.com"
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
            <div class="border-gray-700/50 rounded border-2 border-dashed py-4 text-center text-xs text-gray-500">
              No providers configured. Click "Add Provider" above to get started.
            </div>
          <% end %>
        </div>
      </div>
      
    <!-- Validation Errors -->
      <%= if not Enum.empty?(@validation_errors) do %>
        <div class="bg-red-900/20 border-red-600/40 rounded border p-3">
          <div class="mb-1 text-xs font-medium text-red-400">⚠️ Validation Errors:</div>
          <%= for error <- @validation_errors do %>
            <div class="text-xs text-red-300">• {error}</div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # Quick add provider form
  defp quick_add_form(assigns) do
    ~H"""
    <div class="space-y-3" id="quick-add-form">
      <div class="text-sm font-semibold text-gray-300">Quick Add Provider</div>
      <div class="grid grid-cols-2 gap-2">
        <div>
          <label class="text-[11px] mb-1 block text-gray-400">Chain Name</label>
          <input
            type="text"
            phx-change="quick_add_change"
            phx-value-field="name"
            phx-target={@myself}
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
            phx-change="quick_add_change"
            phx-value-field="chain_id"
            phx-target={@myself}
            value={Map.get(@quick_add_data, :chain_id, "")}
            placeholder="42161"
            phx-debounce="300"
            class="bg-gray-800/80 border-gray-600/70 w-full rounded border px-3 py-2 text-sm text-white placeholder-gray-500 focus:border-purple-500 focus:ring-1 focus:ring-purple-500"
          />
        </div>
        <div class="col-span-2">
          <label class="text-[11px] mb-1 block text-gray-400">HTTP RPC URL</label>
          <input
            type="url"
            phx-change="quick_add_change"
            phx-value-field="url"
            phx-target={@myself}
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
            phx-change="quick_add_change"
            phx-value-field="ws_url"
            phx-target={@myself}
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
          phx-target={@myself}
          class="bg-gray-700/80 rounded px-3 py-1.5 text-xs text-gray-200 hover:bg-gray-600"
        >
          Cancel
        </button>
        <button
          phx-click="quick_add_submit"
          phx-target={@myself}
          class="rounded bg-emerald-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-emerald-500"
        >
          Add Provider
        </button>
      </div>
    </div>
    """
  end

  # Event handlers for the component

  @impl true
  def handle_event("toggle_collapsed", _params, socket) do
    {:noreply, update(socket, :chain_config_collapsed, &(!&1))}
  end

  @impl true
  def handle_event("add_new_chain", _params, socket) do
    socket =
      socket
      |> assign(:config_selected_chain, "new_chain")
      |> assign(:config_form_data, %{
        name: "",
        chain_id: nil,
        block_time: 12_000,
        providers: []
      })
      |> assign(:config_validation_errors, [])
      |> assign(:config_expanded_providers, MapSet.new())
      |> assign(:quick_add_open, false)

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_chain", %{"chain" => chain_name}, socket) do
    case ChainConfigManager.get_chain(chain_name) do
      {:ok, config} ->
        form_data = %{
          name: config.name,
          chain_id: config.chain_id,
          block_time: config.block_time,
          providers:
            Enum.map(config.providers, fn provider ->
              %{
                id: provider.id,
                name: provider.name,
                url: provider.url,
                ws_url: provider.ws_url,
                priority: provider.priority,
                type: provider.type,
                api_key_required: provider.api_key_required,
                region: provider.region
              }
            end)
        }

        socket =
          socket
          |> assign(:config_selected_chain, chain_name)
          |> assign(:config_form_data, form_data)
          |> assign(:config_validation_errors, [])
          |> assign(:config_expanded_providers, MapSet.new())
          |> assign(:quick_add_open, false)

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("update_field", %{"field" => field, "value" => value}, socket) do
    current_data = socket.assigns.config_form_data

    updated_value =
      case field do
        "chain_id" ->
          case Integer.parse(value) do
            {v, _} -> v
            _ -> nil
          end

        "block_time" ->
          case Integer.parse(value) do
            {v, _} -> v
            _ -> 12_000
          end

        _ ->
          value
      end

    updated_data = Map.put(current_data, String.to_atom(field), updated_value)

    {:noreply, assign(socket, :config_form_data, updated_data)}
  end

  @impl true
  def handle_event("add_provider", _params, socket) do
    current_providers = Map.get(socket.assigns.config_form_data, :providers, [])

    new_provider = %{
      id: "provider_#{length(current_providers) + 1}",
      name: "",
      url: "",
      ws_url: nil,
      priority: length(current_providers) + 1,
      type: "public",
      api_key_required: false,
      region: nil
    }

    updated_providers = current_providers ++ [new_provider]
    updated_form_data = Map.put(socket.assigns.config_form_data, :providers, updated_providers)

    # Auto-expand the newly added row
    expanded = socket.assigns.config_expanded_providers
    expanded = MapSet.put(expanded, length(updated_providers) - 1)

    socket =
      socket
      |> assign(:config_form_data, updated_form_data)
      |> assign(:config_expanded_providers, expanded)

    {:noreply, socket}
  end

  @impl true
  def handle_event("remove_provider", %{"index" => index}, socket) do
    idx =
      case Integer.parse(index || "") do
        {val, _} -> val
        _ -> -1
      end

    current_providers = Map.get(socket.assigns.config_form_data, :providers, [])

    updated_providers =
      if idx >= 0 and idx < length(current_providers) do
        List.delete_at(current_providers, idx)
      else
        current_providers
      end

    updated_form_data = Map.put(socket.assigns.config_form_data, :providers, updated_providers)

    # Reindex expanded set to keep following rows consistent after deletion
    old_expanded = socket.assigns.config_expanded_providers

    new_expanded =
      old_expanded
      |> Enum.reduce(MapSet.new(), fn i, acc ->
        cond do
          i == idx -> acc
          i > idx -> MapSet.put(acc, i - 1)
          true -> MapSet.put(acc, i)
        end
      end)

    socket =
      socket
      |> assign(:config_form_data, updated_form_data)
      |> assign(:config_expanded_providers, new_expanded)

    {:noreply, socket}
  end

  @impl true
  def handle_event(
        "update_provider",
        %{"index" => index, "field" => field, "value" => value},
        socket
      ) do
    idx =
      case Integer.parse(index || "") do
        {val, _} -> val
        _ -> -1
      end

    current_providers = Map.get(socket.assigns.config_form_data, :providers, [])

    updated_providers =
      if idx >= 0 and idx < length(current_providers) do
        List.update_at(current_providers, idx, fn provider ->
          Map.put(provider, String.to_atom(field), value)
        end)
      else
        current_providers
      end

    updated_form_data = Map.put(socket.assigns.config_form_data, :providers, updated_providers)

    {:noreply, assign(socket, :config_form_data, updated_form_data)}
  end

  @impl true
  def handle_event("toggle_provider", %{"index" => index}, socket) do
    idx =
      case Integer.parse(index || "") do
        {v, _} -> v
        _ -> -1
      end

    expanded = socket.assigns.config_expanded_providers

    new_expanded =
      if idx >= 0 do
        if MapSet.member?(expanded, idx),
          do: MapSet.delete(expanded, idx),
          else: MapSet.put(expanded, idx)
      else
        expanded
      end

    {:noreply, assign(socket, :config_expanded_providers, new_expanded)}
  end

  @impl true
  def handle_event("save_config", _params, socket) do
    chain_name = socket.assigns.config_selected_chain
    form_data = socket.assigns.config_form_data

    # Convert form data to the format expected by ChainConfigManager
    chain_attrs = %{
      "name" => Map.get(form_data, :name, ""),
      "chain_id" => Map.get(form_data, :chain_id),
      "block_time" => Map.get(form_data, :block_time, 12_000),
      "providers" =>
        Enum.map(Map.get(form_data, :providers, []), fn provider ->
          %{
            "id" => provider.id || "",
            "name" => provider.name || "",
            "url" => provider.url || "",
            "ws_url" => provider.ws_url,
            "priority" => provider.priority || 1,
            "type" => provider.type || "public",
            "api_key_required" => provider.api_key_required || false,
            "region" => provider.region
          }
        end)
    }

    result =
      if chain_name == "new_chain" do
        # Create new chain
        actual_chain_name =
          String.downcase(Map.get(form_data, :name, "")) |> String.replace(~r/[^a-z0-9]/, "_")

        ChainConfigManager.create_chain(actual_chain_name, chain_attrs)
      else
        # Update existing chain
        ChainConfigManager.update_chain(chain_name, chain_attrs)
      end

    case result do
      {:ok, _config} ->
        socket =
          socket
          |> load_available_chains()
          |> assign(:config_validation_errors, [])

        # Notify parent of success
        send(socket.parent_pid, {:chain_config_saved, "Configuration saved successfully"})

        {:noreply, socket}

      {:error, reason} ->
        error_message =
          case reason do
            :chain_already_exists -> "Chain already exists"
            {:invalid_chain_config, _} -> "Invalid chain configuration"
            _ -> "Failed to save chain configuration: #{inspect(reason)}"
          end

        socket = assign(socket, :config_validation_errors, [error_message])
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("test_connection", _params, socket) do
    chain_name = socket.assigns.config_selected_chain

    case ChainConfigManager.get_chain(chain_name) do
      {:ok, config} ->
        # Test each provider (simplified version for now)
        test_results =
          Enum.map(config.providers, fn provider ->
            case ConfigValidator.test_provider_connectivity(provider) do
              :ok -> "✓ #{provider.name}: Connected"
              {:error, reason} -> "✗ #{provider.name}: #{inspect(reason)}"
            end
          end)

        # Notify parent to show test results
        send(socket.parent_pid, {:chain_config_test_results, test_results})

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("delete_chain", _params, socket) do
    chain_name = socket.assigns.config_selected_chain

    case ChainConfigManager.delete_chain(chain_name) do
      :ok ->
        socket =
          socket
          |> load_available_chains()
          |> assign(:config_selected_chain, nil)
          |> assign(:config_form_data, %{})

        # Notify parent of success
        send(socket.parent_pid, {:chain_config_deleted, "Chain deleted successfully"})

        {:noreply, socket}

      {:error, reason} ->
        error_message = "Failed to delete chain: #{inspect(reason)}"
        socket = assign(socket, :config_validation_errors, [error_message])
        {:noreply, socket}
    end
  end

  # Quick Add Events

  @impl true
  def handle_event("toggle_quick_add", _params, socket) do
    socket =
      socket
      |> update(:quick_add_open, &(!&1))
      |> assign(:quick_add_data, %{})
      |> assign(:config_validation_errors, [])

    {:noreply, socket}
  end

  @impl true
  def handle_event("quick_add_change", %{"field" => field, "value" => value}, socket) do
    current_data = socket.assigns.quick_add_data

    updated_value =
      case field do
        "chain_id" ->
          case Integer.parse(value) do
            {v, _} -> v
            _ -> nil
          end

        _ ->
          value
      end

    updated_data = Map.put(current_data, String.to_atom(field), updated_value)

    {:noreply, assign(socket, :quick_add_data, updated_data)}
  end

  @impl true
  def handle_event("quick_add_submit", _params, socket) do
    qa_data = socket.assigns.quick_add_data
    name = Map.get(qa_data, :name, "")
    chain_id = Map.get(qa_data, :chain_id)
    url = Map.get(qa_data, :url, "")
    ws_url = Map.get(qa_data, :ws_url)

    # Create chain name from user input
    target_chain = String.downcase(name) |> String.replace(~r/[^a-z0-9]/, "_")

    chain_exists =
      case ChainConfigManager.get_chain(target_chain) do
        {:ok, _} -> true
        _ -> false
      end

    provider = %{
      "id" => "provider_#{System.unique_integer([:positive])}",
      "name" => name <> " RPC",
      "url" => url,
      "ws_url" => ws_url,
      "priority" => 1,
      "type" => "public",
      "api_key_required" => false
    }

    result =
      if chain_exists do
        # Append provider to existing chain
        case ChainConfigManager.get_chain(target_chain) do
          {:ok, cfg} ->
            providers =
              cfg.providers ++
                [provider |> Map.new(fn {k, v} -> {String.to_atom(k), v} end)]

            attrs = %{
              "name" => cfg.name,
              "chain_id" => cfg.chain_id,
              "block_time" => cfg.block_time || 12_000,
              "providers" =>
                Enum.map(providers, fn p ->
                  %{
                    "id" => p[:id] || provider["id"],
                    "name" => p[:name] || provider["name"],
                    "url" => p[:url] || provider["url"],
                    "ws_url" => p[:ws_url] || provider["ws_url"],
                    "priority" => p[:priority] || 1,
                    "type" => p[:type] || "public",
                    "api_key_required" => p[:api_key_required] || false,
                    "region" => p[:region]
                  }
                end)
            }

            ChainConfigManager.update_chain(target_chain, attrs)

          err ->
            err
        end
      else
        # Create new chain with a single provider
        attrs = %{
          "name" => name,
          "chain_id" => chain_id,
          "block_time" => 12_000,
          "providers" => [provider]
        }

        ChainConfigManager.create_chain(target_chain, attrs)
      end

    case result do
      {:ok, _cfg} ->
        socket =
          socket
          |> load_available_chains()
          |> assign(:config_selected_chain, target_chain)
          |> assign(:quick_add_open, false)
          |> assign(:quick_add_data, %{})

        # Notify parent of success
        send(socket.parent_pid, {:chain_config_saved, "Provider added successfully"})

        {:noreply, socket}

      {:error, reason} ->
        socket =
          assign(socket, :config_validation_errors, ["Failed to add provider: #{inspect(reason)}"])

        {:noreply, socket}
    end
  end

  # Note: PubSub messages will be handled by the parent LiveView
  # and passed to this component via update/2 calls

  # Helper functions

  defp load_available_chains(socket) do
    {:ok, chains} = ChainConfigManager.list_chains()

    chain_list =
      Enum.map(chains, fn {name, config} ->
        %{name: name, chain_id: config.chain_id, providers: config.providers}
      end)

    assign(socket, :available_chains, chain_list)
  end
end
