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
    # Get all configured chains from ConfigStore
    all_chains = ConfigStore.get_all_chains()

    Enum.flat_map(all_chains, fn {chain_name, chain_config} ->
      Enum.map(chain_config.providers, fn provider ->
        # Determine provider type based on available URLs
        provider_type = determine_provider_type(provider)
        
        # Get status information
        provider_status = determine_provider_status(chain_name, provider)
        
        # Get WebSocket connection info if applicable
        ws_info = 
          if provider_type in [:websocket, :both] do
            case get_chain_pid(chain_name) do
              {:ok, _pid} ->
                ws_status = ChainSupervisor.get_chain_status(chain_name)
                ws_connections = Map.get(ws_status, :ws_connections, [])
                Enum.find(ws_connections, &(&1.id == provider.id))
              _ ->
                nil
            end
          else
            nil
          end
        
        %{
          id: provider.id,
          name: provider.name,
          chain: chain_name,
          type: provider_type,
          status: provider_status,
          # WebSocket specific fields (nil for HTTP-only)
          ws_connected: if(ws_info, do: Map.get(ws_info, :connected, false), else: nil),
          reconnect_attempts: if(ws_info, do: Map.get(ws_info, :reconnect_attempts, 0), else: 0),
          subscriptions: if(ws_info, do: Map.get(ws_info, :subscriptions, 0), else: 0),
          pending_messages: if(ws_info, do: Map.get(ws_info, :pending_messages, 0), else: 0),
          # Provider configuration info
          priority: Map.get(provider, :priority, 999),
          url: provider.url,
          ws_url: Map.get(provider, :ws_url),
          last_seen: System.system_time(:millisecond)
        }
      end)
    end)
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
              Logger.debug("ChainRegistry: Successfully got comprehensive status for #{chain_name}, #{length(pool_status.providers)} providers")
              # Get WebSocket connection info from chain supervisor  
              ws_status = ChainSupervisor.get_chain_status(chain_name)
              ws_connections = Map.get(ws_status, :ws_connections, [])
              
              # Merge provider pool data with WS connection data
              Enum.map(pool_status.providers, fn provider ->
                # Debug log provider data from ProviderPool
                require Logger
                Logger.debug("ChainRegistry: Provider #{provider.id} from ProviderPool - health_status: #{inspect(provider.status)}, last_health_check: #{inspect(provider.last_health_check)}, circuit_state: #{inspect(provider.circuit_state)}")
                
                # Find matching WS connection data
                ws_connection = Enum.find(ws_connections, &(&1.id == provider.id))
                
                # Safely extract WebSocket connection data with nil checks
                reconnect_attempts = if ws_connection, do: Map.get(ws_connection, :reconnect_attempts, 0), else: 0
                subscriptions = if ws_connection, do: Map.get(ws_connection, :subscriptions, 0), else: 0
                ws_connected = if ws_connection, do: Map.get(ws_connection, :connected, false), else: false
                pending_messages = if ws_connection, do: Map.get(ws_connection, :pending_messages, 0), else: 0
                
                # Get provider name from config
                provider_name = Map.get(provider, :name) || provider.id
                
                result = %{
                  id: provider.id,
                  name: provider_name,
                  # Use the actual health status from ProviderPool for UI display
                  status: normalize_provider_status(provider.status),
                  health_status: provider.status,  # Use the actual status from ProviderPool
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
                
                Logger.debug("ChainRegistry: Final provider data for #{provider.id} - status: #{inspect(result.status)}, health_status: #{inspect(result.health_status)}")
                result
              end)

            {:error, error} ->
              # Fallback to old method if comprehensive status fails
              Logger.debug("ChainRegistry: Failed to get comprehensive status for #{chain_name}: #{inspect(error)}")
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
                          status: normalize_provider_status(Map.get(provider, :status, :unknown)),
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
    # Get all configured chains from ConfigStore
    all_chains = ConfigStore.get_all_chains()

    Enum.flat_map(all_chains, fn {chain_name, chain_config} ->
      # Get health check data from ProviderPool if available
      pool_providers_map = case get_chain_pid(chain_name) do
        {:ok, pid} when is_pid(pid) ->
          case ProviderPool.get_comprehensive_status(chain_name) do
            {:ok, pool_status} ->
              # Convert to map for easy lookup
              pool_status.providers
              |> Enum.map(&{&1.id, &1})
              |> Enum.into(%{})
            {:error, _} ->
              %{}
          end
        _ ->
          %{}
      end
      
      # Get WebSocket connection info if chain is running
      ws_connections_map = case get_chain_pid(chain_name) do
        {:ok, pid} when is_pid(pid) ->
          ws_status = ChainSupervisor.get_chain_status(chain_name)
          ws_connections = Map.get(ws_status, :ws_connections, [])
          ws_connections
          |> Enum.map(&{&1.id, &1})
          |> Enum.into(%{})
        _ ->
          %{}
      end
      
      # Show ALL providers from config, enriched with runtime data
      Enum.map(chain_config.providers, fn config_provider ->
        provider_type = determine_provider_type(config_provider)
        
        # Get health check data from ProviderPool if available
        pool_provider = Map.get(pool_providers_map, config_provider.id)
        
        # Get WebSocket connection data if available  
        ws_connection = Map.get(ws_connections_map, config_provider.id)
        
        # Safely extract WebSocket connection data
        reconnect_attempts = if ws_connection, do: Map.get(ws_connection, :reconnect_attempts, 0), else: 0
        subscriptions = if ws_connection, do: Map.get(ws_connection, :subscriptions, 0), else: 0
        ws_connected = if ws_connection, do: Map.get(ws_connection, :connected, false), else: false
        pending_messages = if ws_connection, do: Map.get(ws_connection, :pending_messages, 0), else: 0
        
        if pool_provider do
          # Provider has health check data from ProviderPool
          %{
            id: pool_provider.id,
            name: pool_provider.name || config_provider.name || config_provider.id,
            type: provider_type,  # Add missing type field
            status: normalize_provider_status(pool_provider.status),
            health_status: pool_provider.status,
            circuit_state: pool_provider.circuit_state,
            chain: chain_name,
            reconnect_attempts: reconnect_attempts,
            subscriptions: subscriptions,
            last_seen: pool_provider.last_health_check,
            consecutive_failures: pool_provider.consecutive_failures,
            consecutive_successes: pool_provider.consecutive_successes,
            last_error: pool_provider.last_error,
            is_in_cooldown: pool_provider.is_in_cooldown,
            cooldown_until: pool_provider.cooldown_until,
            cooldown_count: pool_provider.cooldown_count,
            ws_connected: ws_connected,
            pending_messages: pending_messages
          }
        else
          # Provider not in ProviderPool - use config and WS data
          status = case provider_type do
            :http -> :connecting  # HTTP-only providers show as connecting by default
            :websocket -> if ws_connected, do: :connected, else: :disconnected
            :both -> if ws_connected, do: :connected, else: :connecting
            _ -> :unknown
          end
          
          %{
            id: config_provider.id,
            name: config_provider.name || config_provider.id,
            type: provider_type,  # Add missing type field
            status: normalize_provider_status(status),
            health_status: :unknown,  # No health check data available
            circuit_state: :closed,
            chain: chain_name,
            reconnect_attempts: reconnect_attempts,
            subscriptions: subscriptions,
            last_seen: nil,
            consecutive_failures: 0,
            consecutive_successes: 0,
            last_error: nil,
            is_in_cooldown: false,
            cooldown_until: nil,
            cooldown_count: 0,
            ws_connected: ws_connected,
            pending_messages: pending_messages
          }
        end
      end)
    end)
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

  # Private helper functions

  # Helper function to determine provider type based on available URLs
  defp determine_provider_type(provider) do
    has_http = is_binary(provider.url) and String.length(provider.url) > 0
    has_ws = is_binary(Map.get(provider, :ws_url)) and String.length(Map.get(provider, :ws_url, "")) > 0
    
    case {has_http, has_ws} do
      {true, true} -> :both
      {true, false} -> :http
      {false, true} -> :websocket  # Unlikely but possible
      {false, false} -> :unknown   # Invalid configuration
    end
  end

  # Helper function to determine provider status 
  defp determine_provider_status(chain_name, provider) do
    provider_type = determine_provider_type(provider)
    
    case provider_type do
      :both ->
        # For providers with both HTTP and WebSocket, check WebSocket first, then health status
        ws_status = get_ws_status(chain_name, provider.id)
        health_status = get_provider_health_status(chain_name, provider.id)
        
        cond do
          # If WebSocket is connected, provider is connected
          ws_status == true -> :connected
          # If WebSocket is disconnected but HTTP health check passes, show connecting
          ws_status == false and health_status == :connected -> :connecting
          # If both are unavailable, disconnected
          true -> :disconnected
        end
        
      :websocket ->
        # WebSocket-only provider - depends entirely on WebSocket status
        case get_ws_status(chain_name, provider.id) do
          true -> :connected
          false -> :connecting  # WebSocket is trying to connect
          nil -> :disconnected  # WebSocket connection not started
        end
        
      :http ->
        # HTTP-only provider - use health check status from ProviderPool
        get_provider_health_status(chain_name, provider.id)
        
      :unknown ->
        :disconnected
    end
  end

  defp get_ws_status(chain_name, provider_id) do
    case get_chain_pid(chain_name) do
      {:ok, _pid} ->
        ws_status = ChainSupervisor.get_chain_status(chain_name)
        ws_connections = Map.get(ws_status, :ws_connections, [])
        case Enum.find(ws_connections, &(&1.id == provider_id)) do
          nil -> nil
          connection -> Map.get(connection, :connected, false)
        end
      _ ->
        nil
    end
  end

  defp get_provider_health_status(chain_name, provider_id) do
    # Get the actual health check status from ProviderPool
    try do
      case ProviderPool.get_comprehensive_status(chain_name) do
        {:ok, pool_status} ->
          # Find the specific provider in the pool status
          case Enum.find(pool_status.providers, &(&1.id == provider_id)) do
            %{status: :healthy} -> :connected
            %{status: :unhealthy} -> :disconnected
            %{status: :connecting} -> :connecting
            %{status: :rate_limited} -> :connecting
            _ -> :connecting  # Default for unknown status
          end
        {:error, _} ->
          # Fallback to circuit breaker status if ProviderPool is not available
          get_circuit_breaker_status(provider_id)
      end
    catch
      :exit, {:noproc, _} -> 
        # ProviderPool not started yet, fallback to circuit breaker
        get_circuit_breaker_status(provider_id)
      _ -> 
        :connecting
    end
  end

  defp get_circuit_breaker_status(provider_id) do
    try do
      case Livechain.RPC.CircuitBreaker.get_state(provider_id) do
        %{state: :closed} -> :connected
        %{state: :half_open} -> :connecting  
        %{state: :open} -> :disconnected
        _ -> :connected  # Default - assume providers are available
      end
    catch
      :exit, {:noproc, _} -> :connected  # Circuit breaker not started yet
      _ -> :connected
    end
  end

  # Normalize ProviderPool statuses to topology-expected statuses
  defp normalize_provider_status(:healthy), do: :connected
  defp normalize_provider_status(:unhealthy), do: :disconnected
  defp normalize_provider_status(:connecting), do: :connecting
  defp normalize_provider_status(:disconnected), do: :disconnected
  # Expose rate limiting distinctly in the UI
  defp normalize_provider_status(:rate_limited), do: :rate_limited
  defp normalize_provider_status(_), do: :disconnected

  ## GenServer Implementation

  @impl true
  def init(_opts) do
    Logger.info("Starting ChainRegistry")

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

    Logger.info("Starting supervisors for #{map_size(all_chains)} configured chains")

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
      "Chain supervisor startup complete: #{successful_starts}/#{map_size(all_chains)} successful, #{failed_starts} failed"
    )

    new_state = %{state | chain_supervisors: successful_supervisors}
    {:reply, {:ok, successful_starts}, new_state}
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
    case Livechain.Config.ChainConfig.validate_chain_config(chain_config) do
      :ok ->
        case DynamicSupervisor.start_child(
               Livechain.RPC.Supervisor,
               {ChainSupervisor, {chain_name, chain_config}}
             ) do
          {:ok, pid} ->
            Logger.info("Started ChainSupervisor for #{chain_name}")
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            Logger.info("ChainSupervisor for #{chain_name} already running")
            {:ok, pid}

          {:error, reason} ->
            Logger.error("Failed to start ChainSupervisor for #{chain_name}: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Invalid configuration for #{chain_name}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
