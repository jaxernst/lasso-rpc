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
  alias Livechain.RPC.{WSConnection, WSEndpoint, ProviderPool, CircuitBreaker, TransportRegistry}
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

  @doc """
  Dynamically adds a provider to a running chain supervisor.

  This function:
  - Starts circuit breakers for HTTP and WebSocket transports
  - Registers the provider with ProviderPool
  - Starts a WebSocket connection if ws_url is present

  The provider becomes immediately available for request routing.

  ## Options
  - `:start_ws` - Whether to start WebSocket connection (:auto | :force | :skip). Default: :auto

  ## Example
      ensure_provider("ethereum", %{
        id: "new_provider",
        name: "New Provider",
        url: "https://rpc.example.com",
        ws_url: "wss://ws.example.com",
        type: "premium",
        priority: 100
      })
  """
  @spec ensure_provider(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def ensure_provider(chain_name, provider_config, opts \\ []) do
    with {:ok, chain_config} <- get_chain_config(chain_name),
         :ok <- start_circuit_breakers_for_provider(chain_name, provider_config),
         :ok <- ProviderPool.register_provider(chain_name, provider_config.id, provider_config),
         :ok <- maybe_start_ws_connection(chain_name, provider_config, chain_config, opts) do
      :ok
    else
      {:error, reason} = error ->
        Logger.error(
          "Failed to add provider #{provider_config.id} to #{chain_name}: #{inspect(reason)}"
        )

        error
    end
  end

  @doc """
  Removes a provider from a running chain supervisor.

  This function:
  - Closes all transport channels (HTTP and WebSocket)
  - Stops WebSocket connection process if running
  - Terminates circuit breakers
  - Unregisters provider from ProviderPool

  The provider is immediately removed from request routing.

  ## Example
      remove_provider("ethereum", "old_provider")
  """
  @spec remove_provider(String.t(), String.t()) :: :ok | {:error, term()}
  def remove_provider(chain_name, provider_id) do
    # Close transport channels
    TransportRegistry.close_channel(chain_name, provider_id, :http)
    TransportRegistry.close_channel(chain_name, provider_id, :ws)

    # Stop WebSocket connection if running (use brutal_kill if normal shutdown fails)
    case GenServer.whereis({:via, Registry, {Livechain.Registry, {:ws_conn, provider_id}}}) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid, :normal, 1_000)
        catch
          :exit, _ ->
            # Force kill if graceful shutdown fails
            Process.exit(pid, :kill)
            :ok
        end
    end

    # Stop circuit breakers
    stop_circuit_breakers_for_provider(chain_name, provider_id)

    # Unregister from pool
    :ok = ProviderPool.unregister_provider(chain_name, provider_id)

    Logger.info("Successfully removed provider #{provider_id} from #{chain_name}")
    :ok
  end

  # Supervisor callbacks

  @impl true
  def init({chain_name, chain_config}) do
    children = [
      # Start ProviderPool for health monitoring and performance tracking
      {ProviderPool, {chain_name, chain_config}},

      # Start TransportRegistry for transport-agnostic channel management
      {TransportRegistry, {chain_name, chain_config}},

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

  # Dynamic provider management helpers

  defp get_chain_config(chain_name) do
    case Livechain.Config.ConfigStore.get_chain(chain_name) do
      {:ok, config} ->
        {:ok, config}

      {:error, :not_found} ->
        # For dynamic chains or test scenarios, use minimal config
        {:ok,
         %{
           chain_id: 0,
           connection: %{
             heartbeat_interval: 30_000,
             reconnect_interval: 5_000,
             max_reconnect_attempts: 10
           }
         }}
    end
  end

  defp start_circuit_breakers_for_provider(chain_name, provider_config) do
    # Start HTTP circuit breaker
    case start_circuit_breaker(chain_name, provider_config, :http) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> {:error, {:circuit_breaker_start_failed, :http, reason}}
    end
    |> case do
      :ok ->
        # Start WS circuit breaker if ws_url present
        if is_binary(Map.get(provider_config, :ws_url)) do
          case start_circuit_breaker(chain_name, provider_config, :ws) do
            {:ok, _} -> :ok
            {:error, {:already_started, _}} -> :ok
            {:error, reason} -> {:error, {:circuit_breaker_start_failed, :ws, reason}}
          end
        else
          :ok
        end

      error ->
        error
    end
  end

  defp maybe_start_ws_connection(chain_name, provider_config, chain_config, opts) do
    start_ws = Keyword.get(opts, :start_ws, :auto)
    ws_url = Map.get(provider_config, :ws_url)

    should_start_ws? =
      case start_ws do
        :force -> true
        :skip -> false
        :auto -> is_binary(ws_url)
      end

    if should_start_ws? do
      case ws_url do
        nil ->
          {:error, :no_ws_url}

        url when is_binary(url) ->
          start_provider_connection(chain_name, provider_config, chain_config)
          :ok
      end
    else
      :ok
    end
  end

  defp stop_circuit_breakers_for_provider(chain_name, provider_id) do
    # Try to stop both HTTP and WS circuit breakers
    for transport <- [:http, :ws] do
      cb_name =
        {:via, Registry, {Livechain.Registry, {:circuit_breaker, "#{provider_id}:#{transport}"}}}

      case GenServer.whereis(cb_name) do
        nil ->
          :ok

        pid ->
          DynamicSupervisor.terminate_child(circuit_breaker_supervisor_name(chain_name), pid)
      end
    end

    :ok
  end
end
