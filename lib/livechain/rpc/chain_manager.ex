defmodule Livechain.RPC.ChainManager do
  @moduledoc """
  Top-level manager for all blockchain connections.

  This module orchestrates multiple ChainSupervisors, each managing
  a single blockchain with multiple provider connections. It provides
  a unified interface for:

  - Loading chain configurations
  - Starting/stopping chain supervisors
  - Health monitoring across all chains
  - Global statistics and status reporting
  """

  use GenServer
  require Logger

  alias Livechain.Config.ChainConfig
  alias Livechain.RPC.ChainSupervisor

  defstruct [
    :config,
    :chain_supervisors,
    :global_stats
  ]

  defmodule GlobalStats do
    @derive Jason.Encoder
    defstruct total_chains: 0,
              active_chains: 0,
              total_providers: 0,
              healthy_providers: 0,
              total_messages: 0,
              messages_per_second: 0,
              uptime: 0,
              started_at: nil
  end

  @doc """
  Starts the ChainManager.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Loads configuration and starts all chain supervisors.
  """
  def start_all_chains(config_path \\ "config/chains.yml") do
    GenServer.call(__MODULE__, {:start_all_chains, config_path})
  end

  @doc """
  Ensures configuration is loaded for the manager.
  """
  def ensure_loaded do
    GenServer.call(__MODULE__, :ensure_loaded)
  end

  @doc """
  Starts a specific chain supervisor, loading config on demand if needed.
  """
  def start_chain(chain_name) do
    GenServer.call(__MODULE__, {:start_chain, chain_name})
  end

  @doc """
  Stops a specific chain supervisor.
  """
  def stop_chain(chain_name) do
    GenServer.call(__MODULE__, {:stop_chain, chain_name})
  end

  @doc """
  Gets the status of all chains.
  """
  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  @doc """
  Gets detailed status for a specific chain.
  """
  def get_chain_status(chain_name) do
    case GenServer.call(__MODULE__, {:get_chain_status, chain_name}) do
      {:ok, status} -> status
      {:error, reason} -> %{error: reason}
    end
  end

  @doc """
  Sends a message to the best provider for a chain.
  """
  def send_message(chain_name, message) do
    ChainSupervisor.send_message(chain_name, message)
  end

  @doc """
  Subscribes to events on all providers for a chain.
  """
  def subscribe_to_events(chain_name, topic) do
    ChainSupervisor.subscribe_to_events(chain_name, topic)
  end

  @doc """
  Gets global statistics across all chains.
  """
  def get_global_stats do
    GenServer.call(__MODULE__, :get_global_stats)
  end

  @doc """
  Gets logs for a specific chain with filter.
  """
  def get_logs(chain_name, filter) do
    # Fallback to first available provider
    with {:ok, [provider_id | _]} <- get_available_providers(chain_name),
         {:ok, result} <- forward_rpc_request(chain_name, provider_id, "eth_getLogs", [filter]) do
      {:ok, result}
    else
      {:ok, []} -> {:error, :no_providers_available}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Gets block by number for a specific chain.
  """
  def get_block_by_number(chain_name, block_number, include_transactions) do
    with {:ok, [provider_id | _]} <- get_available_providers(chain_name),
         {:ok, result} <-
           forward_rpc_request(chain_name, provider_id, "eth_getBlockByNumber", [
             block_number,
             include_transactions
           ]) do
      {:ok, result}
    else
      {:ok, []} -> {:error, :no_providers_available}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Gets the latest block number for a specific chain.
  """
  def get_block_number(chain_name) do
    with {:ok, [provider_id | _]} <- get_available_providers(chain_name),
         {:ok, result} <- forward_rpc_request(chain_name, provider_id, "eth_blockNumber", []) do
      {:ok, result}
    else
      {:ok, []} -> {:error, :no_providers_available}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Gets balance for an address on a specific chain.
  """
  def get_balance(chain_name, address, block) do
    with {:ok, [provider_id | _]} <- get_available_providers(chain_name),
         {:ok, result} <-
           forward_rpc_request(chain_name, provider_id, "eth_getBalance", [address, block]) do
      {:ok, result}
    else
      {:ok, []} -> {:error, :no_providers_available}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Forwards an RPC request to a specific provider on a chain.
  This is the core function for HTTP RPC forwarding with provider selection.
  """
  def forward_rpc_request(chain_name, provider_id, method, params) do
    case ChainSupervisor.forward_rpc_request(chain_name, provider_id, method, params) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Gets all available providers for a specific chain.
  Returns a list of provider IDs that are currently available.
  """
  def get_available_providers(chain_name) do
    case ChainSupervisor.get_active_providers(chain_name) do
      providers when is_list(providers) -> {:ok, providers}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :failed_to_get_providers}
    end
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    Logger.info("Starting ChainManager")

    state = %__MODULE__{
      config: nil,
      chain_supervisors: %{},
      global_stats: %GlobalStats{started_at: System.monotonic_time(:millisecond)}
    }

    # Schedule periodic stats collection
    schedule_stats_update()

    {:ok, state}
  end

  @impl true
  def handle_call({:start_all_chains, config_path}, _from, state) do
    case ChainConfig.load_config(config_path) do
      {:ok, config} ->
        Logger.info("Loaded configuration for #{map_size(config.chains)} chains")

        new_state = %{state | config: config}

        # Start chain supervisors for each configured chain
        results =
          Enum.map(config.chains, fn {chain_name, chain_config} ->
            case start_chain_supervisor(new_state, chain_name, chain_config) do
              {:ok, pid} = result ->
                Logger.info("✓ Chain supervisor started successfully: #{chain_name}")
                {chain_name, result}

              {:error, reason} = result ->
                Logger.error(
                  "✗ Chain supervisor failed to start: #{chain_name} - #{inspect(reason)}"
                )

                {chain_name, result}
            end
          end)

        # Build the chain_supervisors map from successful starts
        successful_supervisors =
          results
          |> Enum.filter(fn {_, result} -> match?({:ok, _}, result) end)
          |> Enum.into(%{}, fn {chain_name, {:ok, pid}} -> {chain_name, pid} end)

        successful_starts = map_size(successful_supervisors)
        failed_starts = Enum.count(results, fn {_, result} -> match?({:error, _}, result) end)

        if failed_starts > 0 do
          failed_chains =
            results
            |> Enum.filter(fn {_, result} -> match?({:error, _}, result) end)
            |> Enum.map(fn {chain_name, _} -> chain_name end)

          Logger.error("Failed chains: #{Enum.join(failed_chains, ", ")}")
        end

        Logger.info(
          "Chain supervisor startup complete: #{successful_starts}/#{map_size(config.chains)} successful, #{failed_starts} failed"
        )

        # Update state with both config and successful chain supervisors
        final_state = %{new_state | chain_supervisors: successful_supervisors}
        {:reply, {:ok, successful_starts}, final_state}

      {:error, reason} ->
        Logger.error("Failed to load chain configuration: #{reason}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:ensure_loaded, _from, state) do
    case state.config do
      nil ->
        case ChainConfig.load_config() do
          {:ok, config} -> {:reply, :ok, %{state | config: config}}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      _ ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:start_chain, chain_name}, _from, state) do
    # Ensure config is loaded
    state =
      case state.config do
        nil ->
          case ChainConfig.load_config() do
            {:ok, config} -> %{state | config: config}
            {:error, _} -> state
          end

        _ ->
          state
      end

    case get_chain_config(state, chain_name) do
      {:ok, chain_config} ->
        case start_chain_supervisor(state, chain_name, chain_config) do
          {:ok, pid} ->
            new_supervisors = Map.put(state.chain_supervisors, chain_name, pid)
            new_state = %{state | chain_supervisors: new_supervisors}
            {:reply, {:ok, pid}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:stop_chain, chain_name}, _from, state) do
    case Map.get(state.chain_supervisors, chain_name) do
      nil ->
        {:reply, {:error, :chain_not_running}, state}

      pid ->
        Supervisor.stop(pid)
        new_supervisors = Map.delete(state.chain_supervisors, chain_name)
        new_state = %{state | chain_supervisors: new_supervisors}
        Logger.info("Stopped chain supervisor for #{chain_name}")
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      total_chains: if(state.config, do: map_size(state.config.chains), else: 0),
      active_chains: map_size(state.chain_supervisors),
      chains: collect_chain_statuses(state),
      global_stats: state.global_stats
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call({:get_chain_status, chain_name}, _from, state) do
    case Map.get(state.chain_supervisors, chain_name) do
      nil ->
        {:reply, {:error, :chain_not_running}, state}

      _pid ->
        status = ChainSupervisor.get_chain_status(chain_name)
        {:reply, {:ok, status}, state}
    end
  end

  @impl true
  def handle_call(:get_global_stats, _from, state) do
    {:reply, state.global_stats, state}
  end

  @impl true
  def handle_info(:update_stats, state) do
    new_stats = calculate_global_stats(state)
    new_state = %{state | global_stats: new_stats}

    schedule_stats_update()
    {:noreply, new_state}
  end

  # Private functions

  defp start_chain_supervisor(_state, chain_name, chain_config) do
    case ChainConfig.validate_chain_config(chain_config) do
      :ok ->
        spec = {ChainSupervisor, {chain_name, chain_config}}

        case DynamicSupervisor.start_child(Livechain.RPC.Supervisor, spec) do
          {:ok, pid} ->
            Logger.info("Started ChainSupervisor for #{chain_name}")
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            Logger.info("ChainSupervisor for #{chain_name} already running")
            {:ok, pid}

          {:error, reason} ->
            Logger.error("Failed to start ChainSupervisor for #{chain_name}: #{reason}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Invalid configuration for #{chain_name}: #{reason}")
        {:error, reason}
    end
  end

  defp get_chain_config(state, chain_name) do
    case state.config do
      nil -> {:error, :no_config_loaded}
      config -> ChainConfig.get_chain_config(config, chain_name)
    end
  end

  defp collect_chain_statuses(state) do
    Enum.map(state.chain_supervisors, fn {chain_name, _pid} ->
      %{
        name: chain_name,
        status: ChainSupervisor.get_chain_status(chain_name)
      }
    end)
  end

  defp calculate_global_stats(state) do
    current_time = System.monotonic_time(:millisecond)
    uptime = current_time - state.global_stats.started_at

    # Collect stats from all chain supervisors
    chain_stats =
      state.chain_supervisors
      |> Enum.map(fn {chain_name, _pid} ->
        ChainSupervisor.get_chain_status(chain_name)
      end)
      |> Enum.filter(&is_map/1)

    total_providers =
      chain_stats
      |> Enum.map(&Map.get(&1, :total_providers, 0))
      |> Enum.sum()

    healthy_providers =
      chain_stats
      |> Enum.map(&Map.get(&1, :healthy_providers, 0))
      |> Enum.sum()

    %{
      state.global_stats
      | total_chains: if(state.config, do: map_size(state.config.chains), else: 0),
        active_chains: map_size(state.chain_supervisors),
        total_providers: total_providers,
        healthy_providers: healthy_providers,
        uptime: uptime
    }
  end

  defp schedule_stats_update do
    # Update every 10 seconds
    Process.send_after(self(), :update_stats, 10_000)
  end
end
