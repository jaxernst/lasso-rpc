defmodule Livechain.RPC.ProviderPool do
  @moduledoc """
  Manages health monitoring, failover, and load balancing for RPC providers.

  This GenServer tracks the health of all providers for a chain and determines
  which providers should be active based on:
  - Connection health and latency
  - Provider priority and reliability scores
  - Rate limiting and error rates
  - Automatic failover on provider failures
  """

  use GenServer
  require Logger

  alias Livechain.Config.ChainConfig

  defstruct [
    :chain_name,
    :chain_config,
    :providers,
    :active_providers,
    :health_checks,
    :stats
  ]

  defmodule ProviderState do
    defstruct [
      :id,
      :config,
      :pid,
      # :healthy, :unhealthy, :connecting, :disconnected
      :status,
      :last_health_check,
      :consecutive_failures,
      :consecutive_successes,
      :avg_latency,
      :error_rate,
      :last_error,
      # Cooldown fields for rate limit handling
      :cooldown_until,
      :cooldown_count,
      :base_cooldown_ms
    ]
  end

  defmodule PoolStats do
    defstruct total_providers: 0,
              healthy_providers: 0,
              active_providers: 0,
              total_requests: 0,
              failed_requests: 0,
              avg_response_time: 0,
              last_failover: nil
  end

  @doc """
  Starts the ProviderPool for a chain.
  """
  def start_link({chain_name, chain_config}) do
    GenServer.start_link(__MODULE__, {chain_name, chain_config}, name: via_name(chain_name))
  end

  @doc """
  Registers a new provider with the pool.
  """
  def register_provider(chain_name, provider_id, pid, provider_config) do
    GenServer.call(via_name(chain_name), {:register_provider, provider_id, pid, provider_config})
  end

  @doc """
  Gets the best available provider based on health and latency.
  """
  def get_best_provider(chain_name) do
    GenServer.call(via_name(chain_name), :get_best_provider)
  end

  @doc """
  Gets all currently active providers.
  """
  def get_active_providers(chain_name) do
    GenServer.call(via_name(chain_name), :get_active_providers)
  end

  @doc """
  Gets the health status of all providers.
  """
  def get_status(chain_name) do
    GenServer.call(via_name(chain_name), :get_status)
  end

  @doc """
  Triggers manual failover from a specific provider.
  """
  def trigger_failover(chain_name, provider_id) do
    GenServer.cast(via_name(chain_name), {:trigger_failover, provider_id})
  end

  @doc """
  Reports a successful operation for latency tracking.
  """
  def report_success(chain_name, provider_id, latency_ms) do
    GenServer.cast(via_name(chain_name), {:report_success, provider_id, latency_ms})
  end

  @doc """
  Reports a failure for error rate tracking.
  """
  def report_failure(chain_name, provider_id, error) do
    GenServer.cast(via_name(chain_name), {:report_failure, provider_id, error})
  end

  # GenServer callbacks

  @impl true
  def init({chain_name, chain_config}) do
    Logger.info("Starting ProviderPool for #{chain_name}")

    state = %__MODULE__{
      chain_name: chain_name,
      chain_config: chain_config,
      providers: %{},
      active_providers: [],
      health_checks: %{},
      stats: %PoolStats{}
    }

    # Schedule periodic health checks
    schedule_health_check()

    {:ok, state}
  end

  @impl true
  def handle_call({:register_provider, provider_id, pid, provider_config}, _from, state) do
    provider_state = %ProviderState{
      id: provider_id,
      config: provider_config,
      pid: pid,
      status: :connecting,
      last_health_check: System.monotonic_time(:millisecond),
      consecutive_failures: 0,
      consecutive_successes: 0,
      avg_latency: provider_config.latency_target,
      error_rate: 0.0,
      last_error: nil,
      cooldown_until: nil,
      cooldown_count: 0,
      base_cooldown_ms: 1000  # Start with 1 second base cooldown
    }

    new_providers = Map.put(state.providers, provider_id, provider_state)
    new_state = %{state | providers: new_providers}

    # Monitor the process
    Process.monitor(pid)

    # Update active providers list
    new_state = update_active_providers(new_state)

    Logger.info("Registered provider #{provider_id} for #{state.chain_name}")
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:get_best_provider, _from, state) do
    case select_best_provider(state) do
      nil ->
        {:reply, {:error, :no_providers_available}, state}

      provider_id ->
        {:reply, {:ok, provider_id}, state}
    end
  end

  @impl true
  def handle_call(:get_active_providers, _from, state) do
    {:reply, state.active_providers, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      chain_name: state.chain_name,
      total_providers: map_size(state.providers),
      active_providers: length(state.active_providers),
      providers:
        Enum.map(state.providers, fn {id, provider} ->
          %{
            id: id,
            name: provider.config.name,
            status: provider.status,
            latency: provider.avg_latency,
            error_rate: provider.error_rate,
            consecutive_failures: provider.consecutive_failures,
            last_health_check: provider.last_health_check
          }
        end),
      stats: state.stats
    }

    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_cast({:trigger_failover, provider_id}, state) do
    case Map.get(state.providers, provider_id) do
      nil ->
        Logger.warning("Cannot failover unknown provider #{provider_id}")
        {:noreply, state}

      provider ->
        Logger.info("Manual failover triggered for provider #{provider_id}")
        new_provider = %{provider | status: :unhealthy, consecutive_failures: 999}
        new_providers = Map.put(state.providers, provider_id, new_provider)
        new_state = %{state | providers: new_providers}
        new_state = update_active_providers(new_state)
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_cast({:report_success, provider_id, latency_ms}, state) do
    new_state = update_provider_success(state, provider_id, latency_ms)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:report_failure, provider_id, error}, state) do
    new_state = update_provider_failure(state, provider_id, error)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:health_check, state) do
    new_state = perform_health_checks(state)
    schedule_health_check()
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    # Find the provider that went down
    case Enum.find(state.providers, fn {_id, provider} -> provider.pid == pid end) do
      {provider_id, provider} ->
        Logger.warning("Provider #{provider_id} process died: #{inspect(reason)}")

        new_provider = %{
          provider
          | status: :disconnected,
            consecutive_failures: provider.consecutive_failures + 1
        }

        new_providers = Map.put(state.providers, provider_id, new_provider)
        new_state = %{state | providers: new_providers}
        new_state = update_active_providers(new_state)
        {:noreply, new_state}

      nil ->
        Logger.debug("Unknown process died: #{inspect(pid)}")
        {:noreply, state}
    end
  end

  # Private functions

  defp select_best_provider(state) do
    current_time = System.monotonic_time(:millisecond)
    
    healthy_providers =
      state.active_providers
      |> Enum.map(&Map.get(state.providers, &1))
      |> Enum.filter(&(&1.status == :healthy))
      |> Enum.filter(&(is_nil(&1.cooldown_until) or &1.cooldown_until <= current_time))

    case healthy_providers do
      [] ->
        # No healthy providers, try any connected provider as last resort
        fallback_providers =
          state.active_providers
          |> Enum.map(&Map.get(state.providers, &1))
          |> Enum.filter(&(&1.status in [:connecting, :unhealthy]))

        case fallback_providers do
          [] -> nil
          [provider | _] -> provider.id
        end

      providers ->
        # Select based on load balancing strategy
        case state.chain_config.global.provider_management.load_balancing do
          "priority" ->
            providers
            |> Enum.sort_by(& &1.config.priority)
            |> List.first()
            |> Map.get(:id)

          "latency_based" ->
            # Filter providers by minimum success rate threshold (95%)
            min_success_rate = 0.95
            eligible_providers = 
              providers
              |> Enum.filter(fn provider ->
                success_rate = 1.0 - provider.error_rate
                success_rate >= min_success_rate
              end)
            
            case eligible_providers do
              [] ->
                # No providers meet success threshold, fallback to best available
                providers
                |> Enum.sort_by(& &1.avg_latency)
                |> List.first()
                |> Map.get(:id)
              
              qualified_providers ->
                # Select lowest latency among qualified providers
                qualified_providers
                |> Enum.sort_by(& &1.avg_latency)
                |> List.first()
                |> Map.get(:id)
            end

          "round_robin" ->
            # Simple round robin based on request count
            providers
            |> Enum.sort_by(& &1.id)
            |> Enum.at(rem(state.stats.total_requests, length(providers)))
            |> Map.get(:id)

          _ ->
            # Default to priority
            providers
            |> Enum.sort_by(& &1.config.priority)
            |> List.first()
            |> Map.get(:id)
        end
    end
  end

  defp update_active_providers(state) do
    available_providers = ChainConfig.get_available_providers(state.chain_config)
    max_providers = state.chain_config.aggregation.max_providers

    # Get providers that are registered and not completely failed
    viable_providers =
      available_providers
      |> Enum.filter(fn provider ->
        case Map.get(state.providers, provider.id) do
          nil -> false
          %{status: :disconnected, consecutive_failures: failures} when failures > 10 -> false
          _ -> true
        end
      end)
      |> Enum.take(max_providers)
      |> Enum.map(& &1.id)

    %{state | active_providers: viable_providers}
  end

  defp update_provider_success(state, provider_id, latency_ms) do
    case Map.get(state.providers, provider_id) do
      nil ->
        state

      provider ->
        # Update latency with exponential moving average
        new_latency = provider.avg_latency * 0.8 + latency_ms * 0.2
        
        # Update error rate with exponential moving average (success = 0 error)
        new_error_rate = provider.error_rate * 0.9 + 0.0 * 0.1

        new_provider = %{
          provider
          | status: :healthy,
            consecutive_successes: provider.consecutive_successes + 1,
            consecutive_failures: 0,
            avg_latency: new_latency,
            error_rate: new_error_rate,
            last_health_check: System.monotonic_time(:millisecond),
            # Reset cooldown state on success
            cooldown_until: nil,
            cooldown_count: 0
        }

        new_providers = Map.put(state.providers, provider_id, new_provider)
        new_stats = %{state.stats | total_requests: state.stats.total_requests + 1}

        %{state | providers: new_providers, stats: new_stats}
    end
  end

  defp update_provider_failure(state, provider_id, error) do
    case Map.get(state.providers, provider_id) do
      nil ->
        state

      provider ->
        # Check if this is a rate limit error
        {is_rate_limit, updated_provider} = 
          case error do
            {:rate_limit, _message} ->
              # Calculate exponential backoff
              new_cooldown_count = provider.cooldown_count + 1
              cooldown_ms = provider.base_cooldown_ms * :math.pow(2, new_cooldown_count)
              max_cooldown = 300_000  # 5 minutes max
              actual_cooldown = min(cooldown_ms, max_cooldown)
              cooldown_until = System.monotonic_time(:millisecond) + trunc(actual_cooldown)
              
              Logger.warning("Provider #{provider_id} rate limited, cooling down for #{trunc(actual_cooldown)}ms")
              
              # Update error rate for rate limit (treat as error)
              new_error_rate = provider.error_rate * 0.9 + 1.0 * 0.1
              
              updated = %{
                provider
                | cooldown_until: cooldown_until,
                  cooldown_count: new_cooldown_count,
                  status: :rate_limited,
                  error_rate: new_error_rate,
                  last_error: error,
                  last_health_check: System.monotonic_time(:millisecond)
              }
              {true, updated}
              
            _ ->
              # Regular failure handling
              new_consecutive_failures = provider.consecutive_failures + 1
              failure_threshold = state.chain_config.global.health_check.failure_threshold

              new_status =
                if new_consecutive_failures >= failure_threshold do
                  :unhealthy
                else
                  provider.status
                end

              # Update error rate for regular failure
              new_error_rate = provider.error_rate * 0.9 + 1.0 * 0.1

              updated = %{
                provider
                | status: new_status,
                  consecutive_failures: new_consecutive_failures,
                  consecutive_successes: 0,
                  error_rate: new_error_rate,
                  last_error: error,
                  last_health_check: System.monotonic_time(:millisecond)
              }
              {false, updated}
          end

        new_providers = Map.put(state.providers, provider_id, updated_provider)

        new_stats = %{
          state.stats
          | total_requests: state.stats.total_requests + 1,
            failed_requests: state.stats.failed_requests + 1
        }

        new_state = %{state | providers: new_providers, stats: new_stats}

        # Log status change for non-rate-limit errors
        if not is_rate_limit and updated_provider.status == :unhealthy and provider.status != :unhealthy do
          Logger.warning(
            "Provider #{provider_id} marked as unhealthy after #{updated_provider.consecutive_failures} failures"
          )

          new_state = update_active_providers(new_state)

          %{
            new_state
            | stats: %{new_state.stats | last_failover: System.monotonic_time(:millisecond)}
          }
        else
          new_state
        end
    end
  end

  defp perform_health_checks(state) do
    recovery_threshold = state.chain_config.global.health_check.recovery_threshold

    # Perform active health checks for all providers
    new_providers = 
      Enum.reduce(state.providers, state.providers, fn {provider_id, provider}, acc ->
        # Perform active health check
        updated_provider = perform_provider_health_check(provider_id, provider, state)
        
        # Check if unhealthy providers should be marked as recovering  
        final_provider = 
          if updated_provider.status == :unhealthy and updated_provider.consecutive_successes >= recovery_threshold do
            Logger.info(
              "Provider #{provider_id} recovered after #{updated_provider.consecutive_successes} successes"
            )
            %{updated_provider | status: :healthy}
          else
            updated_provider
          end
          
        Map.put(acc, provider_id, final_provider)
      end)

    new_state = %{state | providers: new_providers}
    update_active_providers(new_state)
  end

  defp perform_provider_health_check(provider_id, provider, state) do
    # Skip health check if provider is in cooldown
    current_time = System.monotonic_time(:millisecond)
    if provider.cooldown_until && provider.cooldown_until > current_time do
      provider
    else
      # Perform health check using eth_chainId (lightweight method)
      start_time = System.monotonic_time(:millisecond)
      
      case send_health_check_request(provider.config) do
        {:ok, _response} ->
          duration_ms = System.monotonic_time(:millisecond) - start_time
          
          # Update provider with successful health check
          new_latency = provider.avg_latency * 0.8 + duration_ms * 0.2
          new_error_rate = provider.error_rate * 0.9 + 0.0 * 0.1
          
          Logger.debug("Health check succeeded for #{provider_id} in #{duration_ms}ms")
          
          %{
            provider
            | avg_latency: new_latency,
              error_rate: new_error_rate,
              consecutive_successes: provider.consecutive_successes + 1,
              consecutive_failures: 0,
              last_health_check: current_time
          }
        
        {:error, reason} ->
          duration_ms = System.monotonic_time(:millisecond) - start_time
          new_error_rate = provider.error_rate * 0.9 + 1.0 * 0.1
          
          Logger.debug("Health check failed for #{provider_id}: #{inspect(reason)}")
          
          %{
            provider
            | error_rate: new_error_rate,
              consecutive_failures: provider.consecutive_failures + 1,
              consecutive_successes: 0,
              last_error: reason,
              last_health_check: current_time
          }
      end
    end
  end

  defp send_health_check_request(provider_config) do
    # Use eth_chainId as a lightweight health check method
    endpoint = %{
      url: provider_config.url,
      api_key: provider_config.api_key
    }
    
    Livechain.RPC.WSConnection.health_check_request(endpoint, "eth_chainId", [])
  end

  defp schedule_health_check do
    # Health check every 30 seconds by default
    Process.send_after(self(), :health_check, 30_000)
  end

  def via_name(chain_name) do
    {:via, :global, {:provider_pool, chain_name}}
  end
end
