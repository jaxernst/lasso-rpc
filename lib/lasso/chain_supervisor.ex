defmodule Lasso.RPC.ChainSupervisor do
  @moduledoc """
  Profile-scoped supervisor for RPC provider connections on a single blockchain.

  Manages profile-scoped runtime for a specific (profile, chain_id) pair.
  Multiple profiles can use the same chain with independent policy/selection
  and shared provider infrastructure.

  ## Architecture

  ```
  ChainSupervisor {profile, chain_id}
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

  @spec start_link({String.t(), pos_integer(), map()}) :: Supervisor.on_start()
  def start_link({profile, chain_id, chain_config})
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    Supervisor.start_link(__MODULE__, {profile, chain_id, chain_config},
      name: via_name(profile, chain_id)
    )
  end

  @doc """
  Gets the status of all providers for a chain from ETS.
  """
  @spec get_chain_status(String.t(), pos_integer()) :: map()
  def get_chain_status(profile, chain_id)
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    profile_providers = Catalog.get_profile_providers(profile, chain_id)

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
          name: pp[:name] || pp.provider_id,
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

    ws_connections = collect_ws_connection_status(profile, chain_id, providers)

    %{
      chain_id: chain_id,
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
  @spec get_active_providers(String.t(), pos_integer()) :: [String.t()]
  def get_active_providers(profile, chain_id)
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    Catalog.get_profile_providers(profile, chain_id)
    |> Enum.map(& &1.provider_id)
  end

  @doc """
  Dynamically adds a provider to a running chain supervisor.
  """
  @spec ensure_provider(String.t(), pos_integer(), map(), keyword()) :: :ok | {:error, term()}
  def ensure_provider(profile, chain_id, provider_config, _opts \\ [])
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    case TransportRegistry.initialize_provider_channels(
           profile,
           chain_id,
           provider_config.id,
           provider_config
         ) do
      :ok ->
        Catalog.build_from_config()
        instance_id = Catalog.lookup_instance_id(profile, chain_id, provider_config.id)

        if instance_id do
          start_instance_supervisor(instance_id)
          BlockSync.Supervisor.start_worker(chain_id, instance_id)
          Lasso.Providers.ProbeCoordinator.reload_instances(chain_id)
        end

        :ok

      {:error, reason} = error ->
        Logger.error(
          "Failed to add provider #{provider_config.id} to chain #{chain_id}: #{inspect(reason)}"
        )

        error
    end
  end

  @doc """
  Removes a provider from a running chain supervisor.
  """
  @spec remove_provider(String.t(), pos_integer(), String.t()) :: :ok | {:error, term()}
  def remove_provider(profile, chain_id, provider_id)
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    remove_provider(
      profile,
      chain_id,
      provider_id,
      Catalog.lookup_instance_id(profile, chain_id, provider_id)
    )
  end

  @spec remove_provider(String.t(), pos_integer(), String.t(), String.t() | nil) ::
          :ok | {:error, term()}
  def remove_provider(profile, chain_id, provider_id, instance_id)
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    TransportRegistry.close_channel(profile, chain_id, provider_id, :http)
    TransportRegistry.close_channel(profile, chain_id, provider_id, :ws)

    # The ConfigStore mutation has already completed. Rebuilding now makes the
    # removed provider unavailable to routing before shared-instance cleanup
    # decides whether its physical state is still referenced by another profile.
    Catalog.build_from_config()

    if instance_id && Catalog.get_instance_refs(instance_id) == [] do
      BlockSync.Supervisor.stop_worker(chain_id, instance_id)
      stop_instance_supervisor(instance_id)
      InstanceState.clear(instance_id)
    end

    Lasso.Providers.ProbeCoordinator.reload_instances(chain_id)

    Logger.info("Successfully removed provider #{provider_id} from chain #{chain_id}")
    :ok
  end

  # Supervisor callbacks

  @impl true
  def init({profile, chain_id, chain_config}) do
    children = [
      {TransportRegistry, {profile, chain_id, chain_config}},
      {ClientSubscriptionRegistry, {profile, chain_id}},
      {UpstreamSubscriptionPool, {profile, chain_id}},
      {Lasso.Core.Streaming.StreamSupervisor, {profile, chain_id}}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Private functions

  defp via_name(profile, chain_id) do
    {:via, Registry, {Lasso.Registry, {:chain_supervisor, profile, chain_id}}}
  end

  defp stop_instance_supervisor(instance_id) do
    case GenServer.whereis(Lasso.Providers.InstanceSupervisor.via_name(instance_id)) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(Lasso.Providers.InstanceDynamicSupervisor, pid)
    end
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

  defp collect_ws_connection_status(profile, chain_id, providers) when is_list(providers) do
    Enum.map(providers, fn provider ->
      try do
        instance_id = Catalog.lookup_instance_id(profile, chain_id, provider.id)
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
