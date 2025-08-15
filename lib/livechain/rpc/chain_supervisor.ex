defmodule Livechain.RPC.ChainSupervisor do
  @moduledoc """
  Supervises multiple RPC provider connections for a single blockchain.

  This supervisor manages multiple WSConnection processes for redundancy,
  failover, and speed optimization. It coordinates with MessageAggregator
  to deduplicate messages and always forwards the fastest response.

  Architecture:
  ChainSupervisor
  ├── WSConnection (Provider 1 - Priority 1)
  ├── WSConnection (Provider 2 - Priority 2)
  ├── WSConnection (Provider 3 - Priority 3)
  ├── MessageAggregator (Deduplication & Speed)
  └── ProviderPool (Health & Failover)
  """

  use Supervisor
  require Logger

  alias Livechain.Config.ChainConfig
  alias Livechain.RPC.{WSConnection, WSEndpoint, MessageAggregator, ProviderPool, CircuitBreaker}

  @doc """
  Starts a ChainSupervisor for a specific blockchain.
  """
  def start_link({chain_name, chain_config}) do
    Supervisor.start_link(__MODULE__, {chain_name, chain_config}, name: via_name(chain_name))
  end

  @doc """
  Gets the status of all providers for a chain.
  """
  def get_chain_status(chain_name) do
    try do
      case ProviderPool.get_status(chain_name) do
        {:ok, status} ->
          status

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
  Manually triggers failover to next available provider.
  """
  def trigger_failover(chain_name, provider_id) do
    ProviderPool.trigger_failover(chain_name, provider_id)
  end

  @doc """
  Sends a message to the best available provider for a chain.
  """
  def send_message(chain_name, message) do
    case ProviderPool.get_best_provider(chain_name) do
      {:ok, provider_id} ->
        WSConnection.send_message(provider_id, message)

      {:error, :no_providers_available} ->
        Logger.error("No providers available for chain #{chain_name}")
        {:error, :no_providers_available}
    end
  end

  @doc """
  Forwards an RPC request to a specific provider on this chain.
  This is the core function for HTTP RPC forwarding with provider selection.
  """
  @spec forward_rpc_request(String.t(), String.t(), String.t(), list()) ::
          {:ok, any()} | {:error, term()}
  def forward_rpc_request(chain_name, provider_id, method, params) do
    # Build minimal provider config for HTTP client
    with {:ok, config} <- Livechain.Config.ChainConfig.load_config(),
         {:ok, chain_config} <- Livechain.Config.ChainConfig.get_chain_config(config, chain_name),
         provider <- Enum.find(chain_config.providers, &(&1.id == provider_id)),
         true <- not is_nil(provider) do
      http_provider = %{url: provider.url, api_key: nil}
      timeout_ms = Livechain.Config.MethodPolicy.timeout_for(method)

      CircuitBreaker.call(
        provider_id,
        fn ->
          Livechain.RPC.HttpClient.request(http_provider, method, params, timeout_ms)
        end,
        timeout_ms + 1_000
      )
      |> normalize_breaker_result()
    else
      _ -> {:error, {:client_error, "Provider not found or chain config missing"}}
    end
  end

  # Supervisor callbacks

  @impl true
  def init({chain_name, chain_config}) do
    Logger.info(
      "Starting ChainSupervisor for #{chain_name} with #{length(chain_config.providers)} providers"
    )

    children = [
      # Start MessageAggregator first
      {MessageAggregator, {chain_name, chain_config}},

      # Start ProviderPool for health monitoring
      {ProviderPool, {chain_name, chain_config}},

      # Start dynamic supervisor to manage WS connections
      {DynamicSupervisor, strategy: :one_for_one, name: connection_supervisor_name(chain_name)}
    ]

    # Start WSConnection for each available provider
    with {:ok, supervisor_pid} <- Supervisor.init(children, strategy: :one_for_one) do
      # Start provider connections after supervisor is ready
      spawn_link(fn -> start_provider_connections(chain_name, chain_config) end)
      {:ok, supervisor_pid}
    end
  end

  # Private functions

  defp start_provider_connections(chain_name, chain_config) do
    # Wait for supervisor to be fully started
    Process.sleep(100)

    available_providers = ChainConfig.get_available_providers(chain_config)
    max_providers = chain_config.aggregation.max_providers

    # Start up to max_providers connections, prioritizing by priority
    providers_to_start = Enum.take(available_providers, max_providers)

    Enum.each(providers_to_start, fn provider ->
      # Start circuit breaker for this provider
      start_circuit_breaker(provider)

      # Start provider connection
      start_provider_connection(chain_name, provider, chain_config)
    end)

    Logger.info("Started #{length(providers_to_start)} provider connections for #{chain_name}")
  end

  defp start_provider_connection(chain_name, provider, chain_config) do
    # Convert provider config to WSEndpoint - URLs are already resolved by ChainConfig
    endpoint = %WSEndpoint{
      id: provider.id,
      name: provider.name,
      url: provider.url,
      ws_url: provider.ws_url,
      chain_id: chain_config.chain_id,
      heartbeat_interval: chain_config.connection.heartbeat_interval,
      reconnect_interval: chain_config.connection.reconnect_interval,
      max_reconnect_attempts: chain_config.connection.max_reconnect_attempts,
      subscription_topics: Map.get(chain_config.connection, :subscription_topics, ["newHeads"])
    }

    # Start the connection under the dynamic supervisor
    case DynamicSupervisor.start_child(
           connection_supervisor_name(chain_name),
           {WSConnection, endpoint}
         ) do
      {:ok, pid} ->
        Logger.info("Started WSConnection for #{provider.name} (#{provider.id})")
        # Register with ProviderPool
        ProviderPool.register_provider(chain_name, provider.id, pid, provider)

      {:error, {:already_started, pid}} ->
        Logger.info(
          "WSConnection for #{provider.name} (#{provider.id}) already exists, using existing connection"
        )

        # Register with ProviderPool using existing pid
        ProviderPool.register_provider(chain_name, provider.id, pid, provider)

      {:error, reason} ->
        Logger.error("Failed to start WSConnection for #{provider.name}: #{reason}")
    end
  end

  defp start_circuit_breaker(provider) do
    # Circuit breaker configuration
    circuit_config = %{
      failure_threshold: 5,
      recovery_timeout: 60_000,
      success_threshold: 2
    }

    case CircuitBreaker.start_link({provider.id, circuit_config}) do
      {:ok, _pid} ->
        Logger.info("Started circuit breaker for provider #{provider.id}")

      {:error, {:already_started, _pid}} ->
        Logger.debug("Circuit breaker for #{provider.id} already running")

      {:error, reason} ->
        Logger.error("Failed to start circuit breaker for #{provider.id}: #{reason}")
    end
  end

  defp via_name(chain_name) do
    {:via, Registry, {Livechain.Registry, {:chain_supervisor, chain_name}}}
  end

  defp connection_supervisor_name(chain_name) do
    :"#{chain_name}_connection_supervisor"
  end

  defp normalize_breaker_result({:ok, {:ok, result}}), do: {:ok, result}
  defp normalize_breaker_result({:ok, {:error, reason}}), do: {:error, reason}
  defp normalize_breaker_result({:error, reason}), do: {:error, reason}
  defp normalize_breaker_result({:reply, {:ok, result}, _state}), do: {:ok, result}
  defp normalize_breaker_result({:reply, {:error, reason}, _state}), do: {:error, reason}
  defp normalize_breaker_result({:reply, other, _state}), do: {:error, other}
end
