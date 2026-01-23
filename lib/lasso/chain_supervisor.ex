defmodule Lasso.RPC.ChainSupervisor do
  @moduledoc """
  Profile-scoped supervisor for RPC provider connections on a single blockchain.

  This supervisor manages provider connections for a specific (profile, chain) pair.
  Multiple profiles can use the same chain, each with independent provider pools,
  transport registries, and block sync/health probe workers.

  ## Architecture

  ```
  ChainSupervisor {profile, chain}
  ├── ProviderPool (Health & Performance Tracking)
  ├── TransportRegistry (Transport Channel Management)
  ├── BlockSync.Supervisor (Block Height Tracking)
  ├── HealthProbe.Supervisor (Provider Health Probing)
  ├── DynamicSupervisor (Per-Provider Supervisors)
  │   ├── ProviderSupervisor (Provider 1)
  │   └── ProviderSupervisor (Provider 2)
  ├── ClientSubscriptionRegistry
  ├── UpstreamSubscriptionManager
  ├── UpstreamSubscriptionPool
  └── StreamSupervisor
  ```

  BlockSync and HealthProbe supervisors are profile-scoped children of this
  supervisor, ensuring proper restart semantics and eliminating cross-tree
  coordination complexity.
  """

  use Supervisor
  require Logger

  alias Lasso.BlockSync
  alias Lasso.Core.Streaming.{ClientSubscriptionRegistry, UpstreamSubscriptionPool}
  alias Lasso.HealthProbe
  alias Lasso.RPC.ProviderSupervisor
  alias Lasso.RPC.Transport.WebSocket.Connection, as: WSConnection
  alias Lasso.RPC.{ProviderPool, TransportRegistry}

  @doc """
  Starts a ChainSupervisor for a specific profile and blockchain.

  The `profile` parameter isolates this chain's components from other profiles
  using the same blockchain. Registry keys include the profile for isolation.
  """
  @spec start_link({String.t(), String.t(), map()}) :: Supervisor.on_start()
  def start_link({profile, chain_name, chain_config}) do
    Supervisor.start_link(__MODULE__, {profile, chain_name, chain_config},
      name: via_name(profile, chain_name)
    )
  end

  @doc """
  Gets the status of all providers for a chain, including WebSocket connection information.
  """
  @spec get_chain_status(String.t(), String.t()) :: map()
  def get_chain_status(profile, chain_name) do
    case ProviderPool.get_status(profile, chain_name) do
      {:ok, status} ->
        # Collect WebSocket connection status from WSConnection processes
        ws_connections = collect_ws_connection_status(profile, chain_name, status.providers)
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

  @doc """
  Gets active provider connections for a chain.
  """
  @spec get_active_providers(String.t(), String.t()) :: [String.t()]
  def get_active_providers(profile, chain_name) do
    ProviderPool.get_active_providers(profile, chain_name)
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
      ensure_provider("default", "ethereum", %{
        id: "new_provider",
        name: "New Provider",
        url: "https://rpc.example.com",
        ws_url: "wss://ws.example.com",
        type: "premium",
        priority: 100
      })
  """
  @spec ensure_provider(String.t(), String.t(), map(), keyword()) :: :ok | {:error, term()}
  def ensure_provider(profile, chain_name, provider_config, opts \\ []) do
    with {:ok, chain_config} <- get_chain_config(profile, chain_name),
         :ok <-
           ProviderPool.register_provider(
             profile,
             chain_name,
             provider_config.id,
             provider_config
           ),
         :ok <-
           start_provider_supervisor(profile, chain_name, chain_config, provider_config, opts),
         :ok <-
           TransportRegistry.initialize_provider_channels(
             profile,
             chain_name,
             provider_config.id,
             provider_config
           ) do
      # Start BlockSync and HealthProbe workers for the new provider
      # Supervisors are siblings in the tree - guaranteed to be up
      BlockSync.Supervisor.start_worker(profile, chain_name, provider_config.id)
      HealthProbe.Supervisor.start_worker(profile, chain_name, provider_config.id)

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
      remove_provider("default", "ethereum", "old_provider")
  """
  @spec remove_provider(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def remove_provider(profile, chain_name, provider_id) do
    with :ok <- BlockSync.Supervisor.stop_worker(profile, chain_name, provider_id),
         :ok <- HealthProbe.Supervisor.stop_worker(profile, chain_name, provider_id),
         :ok <- stop_provider_supervisor(profile, chain_name, provider_id) do
      # Close transport channels (idempotent)
      TransportRegistry.close_channel(profile, chain_name, provider_id, :http)
      TransportRegistry.close_channel(profile, chain_name, provider_id, :ws)

      # Unregister from pool
      :ok = ProviderPool.unregister_provider(profile, chain_name, provider_id)

      Logger.info("Successfully removed provider #{provider_id} from #{chain_name}")
      :ok
    end
  end

  defp stop_provider_supervisor(profile, chain_name, provider_id) do
    case GenServer.whereis(provider_supervisor_via(profile, chain_name, provider_id)) do
      nil ->
        :ok

      pid ->
        case DynamicSupervisor.terminate_child(
               provider_supervisors_name(profile, chain_name),
               pid
             ) do
          :ok -> :ok
          {:error, _} = error -> error
        end
    end
  end

  # Supervisor callbacks

  @impl true
  def init({profile, chain_name, chain_config}) do
    children = [
      # Start ProviderPool for health monitoring and performance tracking
      {ProviderPool, {profile, chain_name, chain_config}},

      # Start TransportRegistry for transport-agnostic channel management
      {TransportRegistry, {profile, chain_name, chain_config}},

      # Profile-scoped BlockSync and HealthProbe supervisors
      {BlockSync.Supervisor, {profile, chain_name}},
      {HealthProbe.Supervisor, {profile, chain_name}},

      # Per-provider supervisor manager (Registry-based name for profile isolation)
      {DynamicSupervisor,
       strategy: :one_for_one, name: provider_supervisors_name(profile, chain_name)},

      # Start per-profile subscription registry, manager, and pool
      {ClientSubscriptionRegistry, {profile, chain_name}},
      {Lasso.Core.Streaming.UpstreamSubscriptionManager, {profile, chain_name}},
      {UpstreamSubscriptionPool, {profile, chain_name}},

      # StreamSupervisor for per-key coordinators
      {Lasso.Core.Streaming.StreamSupervisor, {profile, chain_name}},

      # Start provider connections after all other children are initialized
      # This Task runs once and completes (restart: :transient)
      %{
        id: :provider_connection_starter,
        start:
          {Task, :start_link,
           [fn -> start_provider_connections_async(profile, chain_name, chain_config) end]},
        restart: :transient
      }
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp start_provider_connections_async(profile, chain_name, chain_config) do
    # Start provider supervisors (circuit breakers, WS connections)
    Enum.each(chain_config.providers, fn provider ->
      _ = start_provider_supervisor(profile, chain_name, chain_config, provider, [])
    end)

    Logger.info("Started #{length(chain_config.providers)} provider supervisors",
      profile: profile,
      chain: chain_name
    )

    # Start BlockSync and HealthProbe workers for this profile's providers
    # These supervisors are siblings in the supervision tree (guaranteed to be up)
    provider_ids = Enum.map(chain_config.providers, & &1.id)
    BlockSync.Supervisor.start_all_workers(profile, chain_name, provider_ids)
    HealthProbe.Supervisor.start_all_workers(profile, chain_name, provider_ids)
  end

  # Private functions

  defp via_name(profile, chain_name) do
    {:via, Registry, {Lasso.Registry, {:chain_supervisor, profile, chain_name}}}
  end

  defp provider_supervisors_name(profile, chain_name) do
    {:via, Registry, {Lasso.Registry, {:provider_supervisors, profile, chain_name}}}
  end

  defp provider_supervisor_via(profile, chain_name, provider_id) do
    {:via, Registry, {Lasso.Registry, {:provider_supervisor, profile, chain_name, provider_id}}}
  end

  defp start_provider_supervisor(profile, chain_name, chain_config, provider_config, _opts) do
    case DynamicSupervisor.start_child(
           provider_supervisors_name(profile, chain_name),
           {ProviderSupervisor, {profile, chain_name, chain_config, provider_config}}
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, {:provider_supervisor_start_failed, reason}}
    end
  end

  # Collects WebSocket connection status from WSConnection processes
  defp collect_ws_connection_status(profile, chain, providers) when is_list(providers) do
    Enum.map(providers, fn provider ->
      try do
        case WSConnection.status(profile, chain, provider.id) do
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

  defp collect_ws_connection_status(_profile, _chain, _), do: []

  # Dynamic provider management helpers

  defp get_chain_config(profile, chain_name) do
    case Lasso.Config.ConfigStore.get_chain(profile, chain_name) do
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
