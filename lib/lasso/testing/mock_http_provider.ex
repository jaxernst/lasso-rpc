defmodule Lasso.Testing.MockHTTPProvider do
  @moduledoc """
  Behavior-based mock HTTP provider for integration testing.

  Integrates with MockProviderBehavior to simulate rich failure scenarios
  like degraded performance, intermittent failures, rate limiting, etc.

  ## Features

  - ✅ Behavior-based responses (healthy, failing, degraded, etc.)
  - ✅ Stateful behaviors (call counting, time-based transitions)
  - ✅ Integrates with ProviderPool and CircuitBreaker
  - ✅ Automatic cleanup on test exit

  ## Usage

      test "circuit breaker failover" do
        setup_providers([
          %{id: "primary", behavior: :healthy},
          %{id: "backup", behavior: :always_fail}
        ])

        # Requests are routed to mock providers based on behavior
        {:ok, result} = RequestPipeline.execute_via_channels(
          chain, "eth_blockNumber", []
        )
      end
  """

  use GenServer
  require Logger

  alias Lasso.Testing.MockProviderBehavior

  @doc """
  Starts a mock HTTP provider and registers it with the chain.

  Options:
  - `:id` (required) - Provider identifier
  - `:behavior` - Behavior specification (default: :healthy)
  - `:priority` - Provider priority (default: 100)
  """
  def start_mock(chain, spec) when is_map(spec) do
    provider_id = Map.get(spec, :id) || raise "Mock HTTP provider requires :id field"

    # Start the GenServer
    {:ok, pid} =
      GenServer.start_link(
        __MODULE__,
        {chain, spec},
        name: {:via, Registry, {Lasso.Registry, {:http_provider, provider_id}}}
      )

    # Create provider config
    provider_config = %{
      id: provider_id,
      name: "Mock HTTP Provider #{provider_id}",
      url: "http://mock-#{provider_id}.test",
      # Fake WS URL to pass protocol filter
      ws_url: "ws://mock-#{provider_id}.test/ws",
      type: "test",
      priority: Map.get(spec, :priority, 100),
      # Mark as mock for routing
      __mock__: true
    }

    # Ensure chain exists and register provider
    with :ok <- ensure_chain_exists(chain),
         :ok <- Lasso.Config.ConfigStore.register_provider_runtime(chain, provider_config),
         :ok <- Lasso.RPC.ProviderPool.register_provider(chain, provider_id, provider_config) do
      Logger.info("MockHTTPProvider: registered #{provider_id}, initializing channels...")

      result =
        Lasso.RPC.TransportRegistry.initialize_provider_channels(
          chain,
          provider_id,
          provider_config
        )

      Logger.info("MockHTTPProvider: initialize_provider_channels returned: #{inspect(result)}")

      case result do
        :ok ->
          # Ensure circuit breaker exists for HTTP transport
          ensure_circuit_breaker(chain, provider_id, :http)

          # Mark as healthy so it can be selected
          Lasso.RPC.ProviderPool.report_success(chain, provider_id)

          # Give report_success (async cast) time to complete
          Process.sleep(50)

          # Set up cleanup monitor
          setup_cleanup_monitor(chain, provider_id, pid)

          Logger.debug("Started mock HTTP provider #{provider_id} for #{chain}")
          {:ok, provider_id}

        error ->
          GenServer.stop(pid)
          {:error, {:channel_initialization_failed, error}}
      end
    else
      {:error, reason} ->
        GenServer.stop(pid)
        {:error, {:registration_failed, reason}}
    end
  end

  @doc """
  Executes an RPC request against a mock provider using its configured behavior.

  This is called by the test HTTP client to route requests to the mock.
  """
  def execute_request(provider_id, method, params) do
    case Registry.lookup(Lasso.Registry, {:http_provider, provider_id}) do
      [{pid, _}] ->
        GenServer.call(pid, {:execute_request, method, params}, 60_000)

      [] ->
        {:error, :provider_not_found}
    end
  end

  @doc """
  Stops a mock HTTP provider.
  """
  def stop_mock(chain, provider_id) do
    # Remove from ConfigStore
    Lasso.Config.ConfigStore.unregister_provider_runtime(chain, provider_id)

    # Stop the GenServer
    case Registry.lookup(Lasso.Registry, {:http_provider, provider_id}) do
      [{pid, _}] ->
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid)
          catch
            _, _ -> :ok
          end
        else
          :ok
        end

      [] ->
        :ok
    end

    :ok
  end

  # Private helper to ensure chain exists (auto-create if needed)
  defp ensure_chain_exists(chain_name) do
    case Lasso.Config.ConfigStore.get_chain(chain_name) do
      {:ok, _chain_config} ->
        :ok

      {:error, :not_found} ->
        # Create chain with default config
        Logger.info("Chain '#{chain_name}' not found, creating for mock provider")

        default_config = %{
          chain_id: nil,
          name: chain_name,
          providers: [],
          connection: %{
            heartbeat_interval: 30_000,
            reconnect_interval: 5_000,
            max_reconnect_attempts: 5
          },
          failover: %{
            enabled: false,
            max_backfill_blocks: 100,
            backfill_timeout: 30_000
          }
        }

        with :ok <-
               Lasso.Config.ConfigStore.register_chain_runtime(chain_name, default_config),
             {:ok, chain_config} <- Lasso.Config.ConfigStore.get_chain(chain_name),
             {:ok, _pid} <-
               DynamicSupervisor.start_child(
                 Lasso.RPC.Supervisor,
                 {Lasso.RPC.ChainSupervisor, {chain_name, chain_config}}
               ) do
          Logger.info("Successfully started chain supervisor for '#{chain_name}'")
          :ok
        else
          {:error, reason} = error ->
            Logger.error("Failed to start chain '#{chain_name}': #{inspect(reason)}")
            error
        end
    end
  end

  # Private helper to ensure circuit breaker exists
  defp ensure_circuit_breaker(chain, provider_id, transport) do
    breaker_id = {chain, provider_id, transport}

    try do
      case Lasso.RPC.CircuitBreaker.get_state(breaker_id) do
        %{} ->
          # Circuit breaker already exists
          :ok

        _ ->
          # Circuit breaker doesn't exist, create it
          start_circuit_breaker(breaker_id)
      end
    catch
      :exit, _ ->
        # Circuit breaker doesn't exist, create it
        start_circuit_breaker(breaker_id)
    end
  end

  defp start_circuit_breaker(breaker_id) do
    case Lasso.RPC.CircuitBreaker.start_link({breaker_id, %{}}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      _ -> :ok
    end
  end

  # GenServer callbacks

  @impl true
  def init({_chain, spec}) do
    behavior = Map.get(spec, :behavior, :healthy)
    provider_id = Map.get(spec, :id)

    state = %{
      provider_id: provider_id,
      behavior: behavior,
      call_count: 0,
      start_time: System.monotonic_time(:millisecond)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:execute_request, method, params}, _from, state) do
    # Increment call count
    state = %{state | call_count: state.call_count + 1}

    # Execute the behavior
    request_state = %{
      call_count: state.call_count,
      start_time: state.start_time
    }

    Logger.debug(
      "MockHTTPProvider[#{state.provider_id}]: executing behavior #{inspect(state.behavior)} for #{method}"
    )

    result =
      MockProviderBehavior.execute_behavior(
        state.behavior,
        method,
        params,
        request_state
      )

    Logger.debug("MockHTTPProvider[#{state.provider_id}]: behavior result: #{inspect(result)}")

    # Convert to JSONRPC response format
    response =
      case result do
        {:ok, unwrapped_result} ->
          # MockProviderBehavior returns unwrapped values (e.g., "0x1", [], %{...})
          # BehaviorHttpClient will wrap these in JSONRPC format
          {:ok, unwrapped_result}

        {:error, %Lasso.JSONRPC.Error{} = error} ->
          # Return as error tuple for the client to handle
          {:error, error}

        {:error, other} ->
          # Convert other errors to JSONRPC errors
          {:error,
           %Lasso.JSONRPC.Error{
             code: -32_000,
             message: "Mock provider error: #{inspect(other)}",
             category: :provider_error,
             retriable?: true
           }}
      end

    {:reply, response, state}
  end

  defp setup_cleanup_monitor(chain, provider_id, _pid) do
    test_pid = self()

    spawn(fn ->
      ref = Process.monitor(test_pid)

      receive do
        {:DOWN, ^ref, :process, ^test_pid, _reason} ->
          Logger.debug("Test process exited, cleaning up mock HTTP provider #{provider_id}")
          stop_mock(chain, provider_id)
      end
    end)
  end
end
