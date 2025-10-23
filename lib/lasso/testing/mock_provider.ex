defmodule Lasso.Testing.MockProvider do
  @moduledoc """
  Lightweight mock RPC provider for integration and battle testing.

  Creates real HTTP servers that integrate with Lasso's provider infrastructure
  via `Lasso.Providers.add_provider/3`. Responses are realistic and deterministic.

  ## Key Features

  - ✅ **Real HTTP server** - Uses actual network stack (no process mocking)
  - ✅ **Integrates with Providers API** - Works with existing ChainSupervisor/ProviderPool
  - ✅ **Configurable behavior** - Set latency, reliability, custom responses
  - ✅ **Automatic cleanup** - Servers stop when test process exits
  - ✅ **Deterministic responses** - Predictable block numbers for assertions

  ## Quick Start

      test "my test" do
        # Start 2 mock providers
        {:ok, _providers} = MockProvider.start_mocks("ethereum", [
          %{id: "mock_fast", latency: 10, reliability: 1.0},
          %{id: "mock_slow", latency: 100, reliability: 0.95}
        ])

        # Providers are now available for routing
        {:ok, result} = RequestPipeline.execute_via_channels(
          "ethereum", "eth_blockNumber", [], %Lasso.RPC.RequestOptions{strategy: :round_robin, timeout_ms: 30_000}
        )

        assert result == "0x1000"
      end

  ## Configuration Options

  - `:id` (required) - Provider identifier
  - `:latency` - Response delay in milliseconds (default: 0)
  - `:reliability` - Success probability 0.0-1.0 (default: 1.0)
  - `:block_number` - Fixed block number to return (default: 4096 = 0x1000)
  - `:port` - HTTP port (default: auto-assigned)
  - `:response_fn` - Custom response generator `fn(request) -> response end`

  ## Supported Methods

  All standard Ethereum JSON-RPC methods return realistic mock data:
  - `eth_blockNumber` → `"0x1000"`
  - `eth_getBalance` → Random balance
  - `eth_gasPrice` → Random gas price
  - `eth_call` → `"0x0000...0001"`
  - All other methods → `"0x0"`

  ## Architecture

  Each mock provider:
  1. Starts a Cowboy HTTP server on random available port
  2. Registers itself via `Providers.add_provider/3`
  3. Becomes immediately available for request routing
  4. Automatically cleans up when test process exits (via monitor)

  ## Limitations

  - HTTP only (no WebSocket subscriptions)
  - Basic JSON-RPC validation
  - Not suitable for testing WebSocket-specific behavior
  """

  use Plug.Router
  require Logger

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:dispatch)

  # POST endpoint for JSON-RPC
  post "/" do
    config = conn.private[:mock_config]

    # Simulate latency
    latency = Map.get(config, :latency, 0)
    if latency > 0, do: Process.sleep(latency)

    # Simulate reliability
    reliability = Map.get(config, :reliability, 1.0)

    if :rand.uniform() <= reliability do
      request = conn.body_params
      response = generate_response(request, config)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(response))
    else
      conn
      |> send_resp(500, "Internal Server Error")
    end
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end

  @doc """
  Starts multiple mock providers and registers them with a chain.

  ## Arguments

  - `chain` - Chain identifier (e.g., "ethereum")
  - `specs` - List of provider configurations

  ## Returns

  `{:ok, provider_ids}` - List of successfully started provider IDs

  ## Example

      {:ok, providers} = MockProvider.start_mocks("ethereum", [
        %{id: "mock_a", latency: 50},
        %{id: "mock_b", latency: 100, reliability: 0.9}
      ])
      # => {:ok, ["mock_a", "mock_b"]}
  """
  def start_mocks(chain, specs) when is_list(specs) do
    results =
      Enum.map(specs, fn spec ->
        case start_mock(chain, spec) do
          {:ok, provider_id} -> provider_id
          {:error, reason} -> {:error, reason}
        end
      end)

    errors = Enum.filter(results, fn result -> match?({:error, _}, result) end)

    if Enum.empty?(errors) do
      {:ok, results}
    else
      {:error, {:partial_failure, errors}}
    end
  end

  @doc """
  Starts a single mock provider and registers it with a chain.

  ## Example

      {:ok, "mock_provider"} = MockProvider.start_mock("ethereum", %{
        id: "mock_provider",
        latency: 50,
        reliability: 1.0
      })
  """
  def start_mock(chain, spec) when is_map(spec) do
    provider_id = Map.get(spec, :id) || raise "Mock provider requires :id field"
    port = Map.get(spec, :port, find_free_port())

    config = %{
      latency: Map.get(spec, :latency, 0),
      reliability: Map.get(spec, :reliability, 1.0),
      block_number: Map.get(spec, :block_number, 0x1000),
      response_fn: Map.get(spec, :response_fn),
      provider_id: provider_id
    }

    # Start HTTP server with config passed to Plug
    case Plug.Cowboy.http(__MODULE__, [mock_config: config],
           port: port,
           ref: provider_id
         ) do
      {:ok, pid} ->
        url = "http://localhost:#{port}"

        # Register with Providers API (integrates with ChainSupervisor)
        provider_config = %{
          id: provider_id,
          name: "Mock Provider #{provider_id}",
          url: url,
          type: "test",
          priority: Map.get(spec, :priority, 100)
        }

        # Register with ConfigStore first (required for TransportRegistry)
        case Lasso.Config.ConfigStore.register_provider_runtime(chain, provider_config) do
          :ok ->
            # Now register with ChainSupervisor/ProviderPool
            case Lasso.Providers.add_provider(chain, provider_config) do
              {:ok, ^provider_id} ->
                # Monitor the test process - cleanup on exit
                setup_cleanup_monitor(chain, provider_id, pid)

                # Eagerly initialize HTTP channel for deterministic testing
                case Lasso.RPC.TransportRegistry.get_channel(chain, provider_id, :http) do
                  {:ok, _channel} ->
                    Logger.debug("Started mock provider #{provider_id} at #{url} (channel ready)")
                    {:ok, provider_id}

                  {:error, reason} ->
                    Logger.warning(
                      "Mock provider #{provider_id} started but channel initialization failed: #{inspect(reason)}"
                    )

                    # Still return success - channel will be created on first use
                    {:ok, provider_id}
                end

              {:error, reason} ->
                # Failed to register with ChainSupervisor - cleanup ConfigStore
                Lasso.Config.ConfigStore.unregister_provider_runtime(chain, provider_id)
                Plug.Cowboy.shutdown(provider_id)
                {:error, {:registration_failed, reason}}
            end

          {:error, reason} ->
            # Failed to register with ConfigStore
            Plug.Cowboy.shutdown(provider_id)
            {:error, {:config_store_registration_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:http_server_failed, reason}}
    end
  end

  @doc """
  Stops mock providers and removes them from the chain.

  ## Example

      MockProvider.stop_mocks("ethereum", ["mock_a", "mock_b"])
  """
  def stop_mocks(chain, provider_ids) when is_list(provider_ids) do
    Enum.each(provider_ids, fn provider_id ->
      stop_mock(chain, provider_id)
    end)

    :ok
  end

  def stop_mock(chain, provider_id) do
    # Remove from Providers (ChainSupervisor/ProviderPool)
    Lasso.Providers.remove_provider(chain, provider_id)

    # Remove from ConfigStore
    Lasso.Config.ConfigStore.unregister_provider_runtime(chain, provider_id)

    # Stop HTTP server
    try do
      Plug.Cowboy.shutdown(provider_id)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  # Private functions

  defp generate_response(request, config) do
    case Map.get(config, :response_fn) do
      nil -> default_response(request, config)
      response_fn -> response_fn.(request)
    end
  end

  defp default_response(%{"method" => "eth_blockNumber"} = request, config) do
    block_number = Map.get(config, :block_number, 0x1000)

    %{
      "jsonrpc" => "2.0",
      "id" => Map.get(request, "id", 1),
      "result" => "0x" <> Integer.to_string(block_number, 16)
    }
  end

  defp default_response(%{"method" => "eth_chainId"} = request, _config) do
    %{
      "jsonrpc" => "2.0",
      "id" => Map.get(request, "id", 1),
      "result" => "0x1"
    }
  end

  defp default_response(%{"method" => "eth_getBalance"} = request, _config) do
    %{
      "jsonrpc" => "2.0",
      "id" => Map.get(request, "id", 1),
      "result" => "0x" <> Integer.to_string(:rand.uniform(1_000_000_000_000_000_000), 16)
    }
  end

  defp default_response(%{"method" => "eth_gasPrice"} = request, _config) do
    %{
      "jsonrpc" => "2.0",
      "id" => Map.get(request, "id", 1),
      "result" => "0x" <> Integer.to_string(:rand.uniform(100_000_000_000), 16)
    }
  end

  defp default_response(%{"method" => "eth_call"} = request, _config) do
    %{
      "jsonrpc" => "2.0",
      "id" => Map.get(request, "id", 1),
      "result" => "0x0000000000000000000000000000000000000000000000000000000000000001"
    }
  end

  defp default_response(%{"method" => "eth_getLogs"} = request, _config) do
    %{
      "jsonrpc" => "2.0",
      "id" => Map.get(request, "id", 1),
      "result" => []
    }
  end

  defp default_response(%{"method" => _method} = request, _config) do
    %{
      "jsonrpc" => "2.0",
      "id" => Map.get(request, "id", 1),
      "result" => "0x0"
    }
  end

  defp default_response(request, _config) do
    %{
      "jsonrpc" => "2.0",
      "id" => Map.get(request, "id"),
      "error" => %{
        "code" => -32_600,
        "message" => "Invalid Request"
      }
    }
  end

  defp find_free_port do
    # Use :gen_tcp to find truly available port
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp setup_cleanup_monitor(chain, provider_id, _server_pid) do
    # Monitor the calling test process
    test_pid = self()

    spawn(fn ->
      ref = Process.monitor(test_pid)

      receive do
        {:DOWN, ^ref, :process, ^test_pid, _reason} ->
          # Test process exited - cleanup mock
          Logger.debug("Test process exited, cleaning up mock provider #{provider_id}")
          stop_mock(chain, provider_id)
      end
    end)
  end

  # Plug.Router callbacks
  def init(opts) do
    # Store mock_config for use in call/2
    opts
  end

  def call(conn, opts) do
    config = Keyword.get(opts, :mock_config, %{})
    conn = put_private(conn, :mock_config, config)
    super(conn, opts)
  end
end
