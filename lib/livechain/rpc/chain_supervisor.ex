defmodule Livechain.RPC.ChainSupervisor do
  @moduledoc """
  Supervises multiple RPC provider connections for a single blockchain.

  This supervisor manages multiple WSConnection processes for redundancy,
  failover, and performance optimization. It coordinates with ProviderPool
  for intelligent provider selection based on real performance metrics.

  Architecture:
  ChainSupervisor
  ├── WSConnection (Provider 1 - Priority 1)
  ├── WSConnection (Provider 2 - Priority 2)
  ├── WSConnection (Provider 3 - Priority 3)
  ├── ProviderPool (Health & Performance Tracking)
  └── CircuitBreaker (Failure Protection)
  """

  use Supervisor
  require Logger

  alias Livechain.Config.ChainConfig
  alias Livechain.RPC.{WSConnection, WSEndpoint, ProviderPool, CircuitBreaker, ProviderRegistry}
  alias Livechain.RPC.ProviderHealthMonitor
  alias Livechain.RPC.{UpstreamSubscriptionPool, ClientSubscriptionRegistry}

  @doc """
  Starts a ChainSupervisor for a specific blockchain.
  """
  def start_link({chain_name, chain_config}) do
    Supervisor.start_link(__MODULE__, {chain_name, chain_config}, name: via_name(chain_name))
  end

  @doc """
  Gets the status of all providers for a chain, including WebSocket connection information.
  """
  def get_chain_status(chain_name) do
    try do
      case ProviderPool.get_status(chain_name) do
        {:ok, status} ->
          # Collect WebSocket connection status from WSConnection processes
          ws_connections = collect_ws_connection_status(status.providers)
          Map.put(status, :ws_connections, ws_connections)

        {:error, reason} ->
          Logger.error("Failed to get chain status for #{chain_name}: #{reason}")
          %{error: reason}
      end
    catch
      :exit, {:noproc, _} -> %{error: :chain_not_started}
    end
  end

  @doc """
  Gets active provider connections for a chain.
  """
  def get_active_providers(chain_name) do
    ProviderPool.get_active_providers(chain_name)
  end

  # Supervisor callbacks

  @impl true
  def init({chain_name, chain_config}) do
    children = [
      # Start ProviderPool for health monitoring and performance tracking
      {ProviderPool, {chain_name, chain_config}},

      # Start ProviderRegistry for transport-agnostic channel management
      {ProviderRegistry, {chain_name, chain_config}},

      # Start dynamic supervisor to manage WS connections
      {DynamicSupervisor, strategy: :one_for_one, name: connection_supervisor_name(chain_name)},

      # Start dynamic supervisor to manage circuit breakers
      {DynamicSupervisor,
       strategy: :one_for_one, name: circuit_breaker_supervisor_name(chain_name)},

      # Start per-chain health monitor (HTTP checks + typed events)
      {ProviderHealthMonitor, chain_name},

      # Start per-chain subscription registry and pool
      {ClientSubscriptionRegistry, chain_name},
      {UpstreamSubscriptionPool, chain_name},

      # StreamSupervisor for per-key coordinators
      {Livechain.RPC.StreamSupervisor, chain_name},

      # Start connection manager after dependencies
      {Task, fn -> start_provider_connections_async(chain_name, chain_config) end}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  # Start provider connections after dependencies are ready
  defp start_provider_connections_async(chain_name, chain_config) do
    # Start circuit breakers per transport for ALL providers (HTTP and WS)
    Enum.each(chain_config.providers, fn provider ->
      {:ok, _} = start_circuit_breaker(chain_name, provider, :http)

      if is_binary(provider.ws_url),
        do: {:ok, _} = start_circuit_breaker(chain_name, provider, :ws)
    end)

    Enum.each(chain_config.providers, fn provider ->
      ProviderPool.register_provider(chain_name, provider.id, provider)
    end)

    # Start WebSocket connections for all providers that support them
    ws_providers = ChainConfig.get_ws_providers(chain_config)

    Enum.each(ws_providers, fn provider ->
      # Start provider connection (circuit breaker already started above)
      start_provider_connection(chain_name, provider, chain_config)
    end)

    Logger.info("Started #{length(ws_providers)} WebSocket connections for #{chain_name}")

    Logger.info(
      "Started circuit breakers for #{length(chain_config.providers)} providers for #{chain_name}"
    )

    Logger.info(
      "Registered #{length(chain_config.providers)} providers (HTTP + WebSocket) with ProviderPool for #{chain_name}"
    )
  end

  # Private functions

  defp start_provider_connection(chain_name, provider, chain_config) do
    # Convert provider config to WSEndpoint - URLs are already resolved by ChainConfig
    endpoint = %WSEndpoint{
      id: provider.id,
      name: provider.name,
      ws_url: provider.ws_url,
      chain_id: chain_config.chain_id,
      chain_name: chain_name,
      heartbeat_interval: chain_config.connection.heartbeat_interval,
      reconnect_interval: chain_config.connection.reconnect_interval,
      max_reconnect_attempts: chain_config.connection.max_reconnect_attempts
    }

    # Start the connection under the dynamic supervisor
    case DynamicSupervisor.start_child(
           connection_supervisor_name(chain_name),
           {WSConnection, endpoint}
         ) do
      {:ok, pid} ->
        Logger.info("Started WSConnection for #{provider.name} (#{provider.id})")
        # Attach the actual WSConnection pid
        ProviderPool.attach_ws_connection(chain_name, provider.id, pid)

      {:error, {:already_started, pid}} ->
        Logger.info(
          "WSConnection for #{provider.name} (#{provider.id}) already exists, using existing connection"
        )

        # Attach the existing WSConnection pid
        ProviderPool.attach_ws_connection(chain_name, provider.id, pid)

      {:error, reason} ->
        Logger.error("Failed to start WSConnection for #{provider.name}: #{inspect(reason)}")
    end
  end

  defp start_circuit_breaker(chain_name, provider, transport) do
    # Circuit breaker configuration
    circuit_config = %{
      failure_threshold: 5,
      recovery_timeout: 60_000,
      success_threshold: 2
    }

    DynamicSupervisor.start_child(
      circuit_breaker_supervisor_name(chain_name),
      {CircuitBreaker, {{provider.id, transport}, circuit_config}}
    )
  end

  defp via_name(chain_name) do
    {:via, Registry, {Livechain.Registry, {:chain_supervisor, chain_name}}}
  end

  defp connection_supervisor_name(chain_name) do
    :"#{chain_name}_connection_supervisor"
  end

  defp circuit_breaker_supervisor_name(chain_name) do
    :"#{chain_name}_circuit_breaker_supervisor"
  end

  # Collects WebSocket connection status from WSConnection processes
  defp collect_ws_connection_status(providers) when is_list(providers) do
    Enum.map(providers, fn provider ->
      try do
        case WSConnection.status(provider.id) do
          status when is_map(status) ->
            %{
              id: provider.id,
              connected: Map.get(status, :connected, false),
              reconnect_attempts: Map.get(status, :reconnect_attempts, 0),
              subscriptions: Map.get(status, :subscriptions, 0),
              pending_messages: Map.get(status, :pending_messages, 0)
            }

          _ ->
            # WSConnection process not found or error occurred
            %{
              id: provider.id,
              connected: false,
              reconnect_attempts: 0,
              subscriptions: 0,
              pending_messages: 0
            }
        end
      catch
        :exit, {:noproc, _} ->
          # WSConnection process doesn't exist (likely HTTP-only provider)
          %{
            id: provider.id,
            connected: false,
            reconnect_attempts: 0,
            subscriptions: 0,
            pending_messages: 0
          }

        _ ->
          # Any other error
          %{
            id: provider.id,
            connected: false,
            reconnect_attempts: 0,
            subscriptions: 0,
            pending_messages: 0
          }
      end
    end)
  end

  defp collect_ws_connection_status(_), do: []
end
