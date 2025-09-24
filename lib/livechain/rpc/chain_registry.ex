defmodule Livechain.RPC.ChainRegistry do
  @moduledoc """
  Thin registry and lifecycle manager for blockchain chain supervisors.

  This module is responsible ONLY for:
  - Loading configuration once at startup
  - Starting and stopping per-chain supervisors
  - Maintaining a registry of running chain PIDs
  - Providing status information about chain lifecycle

  It does NOT:
  - Handle request-time logic or hot path operations
  - Load configuration during request processing
  - Contain business logic for provider selection or RPC forwarding
  - Manage individual provider connections (delegated to ChainSupervisor)
  """

  use GenServer
  require Logger

  alias Livechain.Config.ConfigStore
  alias Livechain.RPC.ChainSupervisor
  alias Livechain.RPC.ProviderPool
  alias Livechain.RPC.StatusAggregator

  defstruct [
    :chain_supervisors,
    :started_at
  ]

  ## Public API

  @doc """
  Starts the ChainRegistry.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Ensures configuration is loaded and starts all configured chains.
  """
  def start_all_chains do
    GenServer.call(__MODULE__, :start_all_chains)
  end

  @doc """
  Starts a specific chain supervisor.
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
  Lists all running chains.
  """
  def list_chains do
    GenServer.call(__MODULE__, :list_chains)
  end

  @doc """
  Gets the PID of a specific chain supervisor.
  """
  def get_chain_pid(chain_name) do
    GenServer.call(__MODULE__, {:get_chain_pid, chain_name})
  end

  @doc """
  Gets the status of all chains (lifecycle information only).
  """
  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  @doc """
  Gets all configured providers from all chains, regardless of connection type.
  Shows both WebSocket and HTTP-only providers with proper status indicators.
  """
  def list_all_providers do
    StatusAggregator.list_all_providers_comprehensive()
  end

  @doc """
  Gets all active connections from all chain supervisors.
  This replaces the old WSSupervisor.list_connections functionality.
  """
  def list_all_connections do
    # Get all configured chains from ConfigStore
    all_chains = ConfigStore.get_all_chains()

    Enum.flat_map(all_chains, fn {chain_name, _chain_config} ->
      case get_chain_pid(chain_name) do
        {:ok, pid} when is_pid(pid) ->
          # Get comprehensive status from provider pool
          Logger.debug("ChainRegistry: Attempting to get comprehensive status for #{chain_name}")

          case ProviderPool.get_comprehensive_status(chain_name) do
            {:ok, pool_status} ->
              Logger.debug(
                "ChainRegistry: Successfully got comprehensive status for #{chain_name}, #{length(pool_status.providers)} providers"
              )

              # Get WebSocket connection info from chain supervisor
              ws_status = ChainSupervisor.get_chain_status(chain_name)
              ws_connections = Map.get(ws_status, :ws_connections, [])

              # Merge provider pool data with WS connection data
              Enum.map(pool_status.providers, fn provider ->
                # Debug log provider data from ProviderPool
                require Logger

                Logger.debug(
                  "ChainRegistry: Provider #{provider.id} from ProviderPool - health_status: #{inspect(provider.status)}, last_health_check: #{inspect(provider.last_health_check)}, circuit_state: #{inspect(provider.circuit_state)}"
                )

                # Find matching WS connection data
                ws_connection = Enum.find(ws_connections, &(&1.id == provider.id))

                # Safely extract WebSocket connection data with nil checks
                reconnect_attempts =
                  if ws_connection, do: Map.get(ws_connection, :reconnect_attempts, 0), else: 0

                subscriptions =
                  if ws_connection, do: Map.get(ws_connection, :subscriptions, 0), else: 0

                ws_connected =
                  if ws_connection, do: Map.get(ws_connection, :connected, false), else: false

                pending_messages =
                  if ws_connection, do: Map.get(ws_connection, :pending_messages, 0), else: 0

                # Get provider name from config
                provider_name = Map.get(provider, :name) || provider.id

                result = %{
                  id: provider.id,
                  name: provider_name,
                  # Use the actual health status from ProviderPool for UI display
                  status: provider.status,
                  # Use the actual status from ProviderPool
                  health_status: provider.status,
                  circuit_state: provider.circuit_state,
                  chain: chain_name,
                  reconnect_attempts: reconnect_attempts,
                  subscriptions: subscriptions,
                  last_seen: provider.last_health_check,
                  # Enhanced status data
                  consecutive_failures: provider.consecutive_failures,
                  consecutive_successes: provider.consecutive_successes,
                  last_error: provider.last_error,
                  is_in_cooldown: provider.is_in_cooldown,
                  cooldown_until: provider.cooldown_until,
                  cooldown_count: provider.cooldown_count,
                  # Connection state from WebSocket
                  ws_connected: ws_connected,
                  pending_messages: pending_messages
                }

                Logger.debug(
                  "ChainRegistry: Final provider data for #{provider.id} - status: #{inspect(result.status)}, health_status: #{inspect(result.health_status)}"
                )

                result
              end)

            {:error, error} ->
              # Fallback to old method if comprehensive status fails
              Logger.debug(
                "ChainRegistry: Failed to get comprehensive status for #{chain_name}: #{inspect(error)}"
              )

              case ChainSupervisor.get_chain_status(chain_name) do
                %{error: _} ->
                  []

                status ->
                  case Map.get(status, :providers, []) do
                    providers when is_list(providers) ->
                      Enum.map(providers, fn provider ->
                        %{
                          id: provider.id,
                          name: provider.name,
                          status: Map.get(provider, :status, :unknown),
                          chain: chain_name,
                          reconnect_attempts: Map.get(provider, :consecutive_failures, 0),
                          subscriptions: Map.get(provider, :subscriptions, 0),
                          last_seen: Map.get(provider, :last_health_check),
                          # Default values for enhanced fields
                          health_status: :unknown,
                          circuit_state: :closed,
                          consecutive_failures: 0,
                          consecutive_successes: 0,
                          last_error: nil,
                          is_in_cooldown: false,
                          cooldown_until: nil,
                          cooldown_count: 0,
                          ws_connected: false,
                          pending_messages: 0
                        }
                      end)

                    _ ->
                      []
                  end
              end
          end

        {:error, error} ->
          Logger.debug("ChainRegistry: Chain #{chain_name} not running: #{inspect(error)}")
          []

        _ ->
          Logger.debug("ChainRegistry: Unexpected response for chain #{chain_name}")
          []
      end
    end)
  end

  @doc """
  Lists ALL providers with comprehensive status, including HTTP-only providers.
  This shows every provider from config regardless of connection type.
  """
  def list_all_providers_comprehensive do
    StatusAggregator.list_all_providers_comprehensive()
  end

  @doc """
  Broadcasts connection status updates to all interested LiveViews.
  This replaces the old WSSupervisor.broadcast_connection_status_update functionality.
  """
  def broadcast_connection_status_update do
    connections = list_all_providers_comprehensive()

    Phoenix.PubSub.broadcast(
      Livechain.PubSub,
      "ws_connections",
      {:connection_status_update, connections}
    )
  end

  # Private helper functions removed; StatusAggregator is the authority for UI status.

  ## GenServer Implementation

  @impl true
  def init(_opts) do
    state = %__MODULE__{
      chain_supervisors: %{},
      started_at: System.monotonic_time(:millisecond)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:start_all_chains, _from, state) do
    # Get all configured chains from ConfigStore
    all_chains = ConfigStore.get_all_chains()

    # Start chain supervisors for each configured chain
    results =
      Enum.map(all_chains, fn {chain_name, chain_config} ->
        case start_chain_supervisor(chain_name, chain_config) do
          {:ok, _pid} = result ->
            Logger.info("✓ Chain supervisor started successfully: #{chain_name}")
            {chain_name, result}

          {:error, reason} = result ->
            Logger.error("✗ Chain supervisor failed to start: #{chain_name} - #{inspect(reason)}")
            {chain_name, result}
        end
      end)

    # Build the chain_supervisors map from successful starts
    successful_supervisors =
      results
      |> Enum.filter(fn {_, result} -> match?({:ok, _}, result) end)
      |> Enum.into(%{}, fn {chain_name, {:ok, pid}} -> {chain_name, pid} end)

    new_state = %{state | chain_supervisors: successful_supervisors}
    {:reply, {:ok, map_size(successful_supervisors)}, new_state}
  end

  @impl true
  def handle_call({:start_chain, chain_name}, _from, state) do
    case ConfigStore.get_chain(chain_name) do
      {:ok, chain_config} ->
        case start_chain_supervisor(chain_name, chain_config) do
          {:ok, pid} ->
            new_supervisors = Map.put(state.chain_supervisors, chain_name, pid)
            new_state = %{state | chain_supervisors: new_supervisors}
            {:reply, {:ok, pid}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, :not_found} ->
        {:reply, {:error, :chain_not_configured}, state}
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
  def handle_call(:list_chains, _from, state) do
    chains = Map.keys(state.chain_supervisors)
    {:reply, chains, state}
  end

  @impl true
  def handle_call({:get_chain_pid, chain_name}, _from, state) do
    case Map.get(state.chain_supervisors, chain_name) do
      nil -> {:reply, {:error, :not_running}, state}
      pid -> {:reply, {:ok, pid}, state}
    end
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    configured_chains = ConfigStore.list_chains()

    status = %{
      total_configured_chains: length(configured_chains),
      running_chains: map_size(state.chain_supervisors),
      configured_chains: configured_chains,
      running_chains_list: Map.keys(state.chain_supervisors),
      uptime_ms: System.monotonic_time(:millisecond) - state.started_at
    }

    {:reply, status, state}
  end

  ## Private Functions

  defp start_chain_supervisor(chain_name, chain_config) do
    :ok = Livechain.Config.ChainConfig.validate_chain_config(chain_config)

    DynamicSupervisor.start_child(
      Livechain.RPC.Supervisor,
      {ChainSupervisor, {chain_name, chain_config}}
    )
  end
end
