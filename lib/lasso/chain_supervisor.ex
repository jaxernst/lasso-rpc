defmodule Lasso.RPC.ChainSupervisor do
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

  # alias Lasso.Config.ChainConfig
  alias Lasso.RPC.{WSConnection, ProviderPool, TransportRegistry}
  alias Lasso.RPC.ProviderSupervisor
  alias Lasso.RPC.{UpstreamSubscriptionPool, ClientSubscriptionRegistry}
  alias Lasso.RPC.ProviderProbe

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

        {:error, :not_found} ->
          # ProviderPool process not found - chain not started
          %{error: :chain_not_started}

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
         :ok <- ProviderPool.register_provider(chain_name, provider_config.id, provider_config),
         :ok <- start_provider_supervisor(chain_name, chain_config, provider_config, opts),
         :ok <-
           TransportRegistry.initialize_provider_channels(
             chain_name,
             provider_config.id,
             provider_config
           ) do
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
    # Stop the per-provider supervisor (cascades WS then circuit breakers)
    case GenServer.whereis(provider_supervisor_via(chain_name, provider_id)) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(provider_supervisors_name(chain_name), pid)
    end

    # Close transport channels (idempotent)
    TransportRegistry.close_channel(chain_name, provider_id, :http)
    TransportRegistry.close_channel(chain_name, provider_id, :ws)

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

      # Per-provider supervisor manager
      {DynamicSupervisor, strategy: :one_for_one, name: provider_supervisors_name(chain_name)},

      # Integrated probe system for provider health and sync monitoring
      {ProviderProbe, chain_name},

      # Start per-chain subscription registry, manager, and pool
      {ClientSubscriptionRegistry, chain_name},
      {Lasso.RPC.UpstreamSubscriptionManager, chain_name},
      {UpstreamSubscriptionPool, chain_name},

      # StreamSupervisor for per-key coordinators
      {Lasso.RPC.StreamSupervisor, chain_name},

      # BlockHeightMonitor for real-time block tracking via WebSocket newHeads
      {Lasso.RPC.BlockHeightMonitor, chain_name},

      # Start provider connections after all other children are initialized
      # This Task runs once and completes (restart: :transient)
      %{
        id: :provider_connection_starter,
        start:
          {Task, :start_link,
           [fn -> start_provider_connections_async(chain_name, chain_config) end]},
        restart: :transient
      }
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp start_provider_connections_async(chain_name, chain_config) do
    Enum.each(chain_config.providers, fn provider ->
      _ = start_provider_supervisor(chain_name, chain_config, provider, [])
    end)

    Logger.info(
      "Started supervisors for #{length(chain_config.providers)} providers in #{chain_name}"
    )
  end

  # Private functions

  defp via_name(chain_name) do
    {:via, Registry, {Lasso.Registry, {:chain_supervisor, chain_name}}}
  end

  defp provider_supervisors_name(chain_name) do
    :"#{chain_name}_provider_supervisors"
  end

  defp provider_supervisor_via(chain_name, provider_id) do
    {:via, Registry, {Lasso.Registry, {:provider_supervisor, chain_name, provider_id}}}
  end

  defp start_provider_supervisor(chain_name, chain_config, provider_config, _opts) do
    case DynamicSupervisor.start_child(
           provider_supervisors_name(chain_name),
           {ProviderSupervisor, {chain_name, chain_config, provider_config}}
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, {:provider_supervisor_start_failed, reason}}
    end
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
    case Lasso.Config.ConfigStore.get_chain(chain_name) do
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
end
