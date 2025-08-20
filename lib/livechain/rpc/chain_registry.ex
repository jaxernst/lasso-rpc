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
  Gets all active connections from all chain supervisors.
  This replaces the old WSSupervisor.list_connections functionality.
  """
  def list_all_connections do
    # Get all configured chains from ConfigStore
    all_chains = ConfigStore.get_all_chains()

    Enum.flat_map(all_chains, fn {chain_name, _chain_config} ->
      case get_chain_pid(chain_name) do
        {:ok, pid} when is_pid(pid) ->
          # Get status from the chain supervisor
          case ChainSupervisor.get_chain_status(chain_name) do
            %{error: _} ->
              []

            status ->
              # Convert chain status to connection format
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
                      last_seen: Map.get(provider, :last_health_check)
                    }
                  end)

                _ ->
                  []
              end
          end

        _ ->
          []
      end
    end)
  end

  @doc """
  Broadcasts connection status updates to all interested LiveViews.
  This replaces the old WSSupervisor.broadcast_connection_status_update functionality.
  """
  def broadcast_connection_status_update do
    connections = list_all_connections()

    Phoenix.PubSub.broadcast(
      Livechain.PubSub,
      "ws_connections",
      {:connection_status_update, connections}
    )
  end

  # Private helper functions

  # Normalize ProviderPool statuses to topology-expected statuses
  defp normalize_provider_status(:healthy), do: :connected
  defp normalize_provider_status(:unhealthy), do: :disconnected
  defp normalize_provider_status(:connecting), do: :connecting
  defp normalize_provider_status(:disconnected), do: :disconnected
  defp normalize_provider_status(:rate_limited), do: :connecting
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
