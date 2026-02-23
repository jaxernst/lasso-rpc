defmodule Lasso.RPC.ChainSupervisor do
  @moduledoc """
  Profile-scoped supervisor for RPC provider connections on a single blockchain.

  Manages profile-scoped runtime for a specific (profile, chain) pair.
  Multiple profiles can use the same chain with independent policy/selection
  and shared provider infrastructure.

  ## Architecture

  ```
  ChainSupervisor {profile, chain}
  ├── TransportRegistry (Transport Channel Management)
  ├── ClientSubscriptionRegistry
  ├── UpstreamSubscriptionPool
  └── StreamSupervisor
  ```

  BlockSync workers, health probing, circuit breakers, and subscription managers
  are handled by shared infrastructure (InstanceSupervisor, BlockSync.DynamicSupervisor,
  ProbeCoordinator) outside this supervisor tree.
  """

  use Supervisor
  require Logger

  alias Lasso.BlockSync
  alias Lasso.Core.Streaming.{ClientSubscriptionRegistry, UpstreamSubscriptionPool}
  alias Lasso.Providers.{Catalog, InstanceState}
  alias Lasso.RPC.Transport.WebSocket.Connection, as: WSConnection
  alias Lasso.RPC.TransportRegistry

  @spec start_link({String.t(), String.t(), map()}) :: Supervisor.on_start()
  def start_link({profile, chain_name, chain_config}) do
    Supervisor.start_link(__MODULE__, {profile, chain_name, chain_config},
      name: via_name(profile, chain_name)
    )
  end

  @doc """
  Gets the status of all providers for a chain from ETS.
  """
  @spec get_chain_status(String.t(), String.t()) :: map()
  def get_chain_status(profile, chain_name) do
    profile_providers = Catalog.get_profile_providers(profile, chain_name)

    providers =
      Enum.map(profile_providers, fn pp ->
        instance_id = pp.instance_id

        instance_config =
          case Catalog.get_instance(instance_id) do
            {:ok, config} -> config
            _ -> %{}
          end

        health = InstanceState.read_health(instance_id)
        ws_status = InstanceState.read_ws_status(instance_id)
        http_cb = InstanceState.read_circuit(instance_id, :http)
        ws_cb = InstanceState.read_circuit(instance_id, :ws)

        %{
          id: pp.provider_id,
          name: get_in(instance_config, [:canonical_config, :name]) || pp.provider_id,
          config: instance_config,
          status: health.status,
          http_status: health.http_status,
          ws_status: ws_status.status,
          http_cb_state: http_cb.state,
          ws_cb_state: ws_cb.state,
          consecutive_failures: health.consecutive_failures,
          consecutive_successes: health.consecutive_successes,
          last_error: health.last_error,
          last_health_check: health.last_health_check
        }
      end)

    healthy_count = Enum.count(providers, &(&1.status == :healthy))

    ws_connections = collect_ws_connection_status(profile, chain_name, providers)

    %{
      chain_name: chain_name,
      total_providers: length(providers),
      healthy_providers: healthy_count,
      active_providers: length(providers),
      providers: providers,
      ws_connections: ws_connections
    }
  end

  @doc """
  Gets active provider connections for a chain.
  """
  @spec get_active_providers(String.t(), String.t()) :: [String.t()]
  def get_active_providers(profile, chain_name) do
    Catalog.get_profile_providers(profile, chain_name)
    |> Enum.map(& &1.provider_id)
  end

  @doc """
  Dynamically adds a provider to a running chain supervisor.
  """
  @spec ensure_provider(String.t(), String.t(), map(), keyword()) :: :ok | {:error, term()}
  def ensure_provider(profile, chain_name, provider_config, _opts \\ []) do
    case TransportRegistry.initialize_provider_channels(
           profile,
           chain_name,
           provider_config.id,
           provider_config
         ) do
      :ok ->
        Catalog.build_from_config()
        instance_id = Catalog.lookup_instance_id(profile, chain_name, provider_config.id)

        if instance_id do
          start_instance_supervisor(instance_id)
          BlockSync.Supervisor.start_worker(chain_name, instance_id)
          Lasso.Providers.ProbeCoordinator.reload_instances(chain_name)
        end

        :ok

      {:error, reason} = error ->
        Logger.error(
          "Failed to add provider #{provider_config.id} to #{chain_name}: #{inspect(reason)}"
        )

        error
    end
  end

  @doc """
  Removes a provider from a running chain supervisor.
  """
  @spec remove_provider(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def remove_provider(profile, chain_name, provider_id) do
    # Resolve instance_id BEFORE rebuilding catalog
    instance_id = Catalog.lookup_instance_id(profile, chain_name, provider_id)

    TransportRegistry.close_channel(profile, chain_name, provider_id, :http)
    TransportRegistry.close_channel(profile, chain_name, provider_id, :ws)

    Catalog.build_from_config()

    if instance_id do
      remaining_refs = Catalog.get_instance_refs(instance_id)

      if remaining_refs == [] do
        BlockSync.Supervisor.stop_worker(chain_name, instance_id)
      end
    end

    Lasso.Providers.ProbeCoordinator.reload_instances(chain_name)

    Logger.info("Successfully removed provider #{provider_id} from #{chain_name}")
    :ok
  end

  # Supervisor callbacks

  @impl true
  def init({profile, chain_name, chain_config}) do
    children = [
      {TransportRegistry, {profile, chain_name, chain_config}},
      {ClientSubscriptionRegistry, {profile, chain_name}},
      {UpstreamSubscriptionPool, {profile, chain_name}},
      {Lasso.Core.Streaming.StreamSupervisor, {profile, chain_name}}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Private functions

  defp via_name(profile, chain_name) do
    {:via, Registry, {Lasso.Registry, {:chain_supervisor, profile, chain_name}}}
  end

  defp start_instance_supervisor(instance_id) do
    case DynamicSupervisor.start_child(
           Lasso.Providers.InstanceDynamicSupervisor,
           {Lasso.Providers.InstanceSupervisor, instance_id}
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> Logger.warning("Failed to start InstanceSupervisor: #{inspect(reason)}")
    end
  end

  defp collect_ws_connection_status(profile, chain, providers) when is_list(providers) do
    Enum.map(providers, fn provider ->
      try do
        instance_id = Catalog.lookup_instance_id(profile, chain, provider.id)
        status = if instance_id, do: WSConnection.status(instance_id), else: %{connected: false}

        %{
          id: provider.id,
          connected: Map.get(status, :connected, false),
          reconnect_attempts: Map.get(status, :reconnect_attempts, 0),
          subscriptions: Map.get(status, :subscriptions, 0),
          pending_messages: Map.get(status, :pending_messages, 0)
        }
      catch
        :exit, _ ->
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
end
