defmodule Livechain.Battle.MockProvider do
  @moduledoc """
  Mock RPC provider for battle testing.

  ⚠️  **NOT RECOMMENDED** - Use real providers with SetupHelper instead.

  This module provides a minimal HTTP-only mock provider for advanced scenarios.
  For most battle tests, use SetupHelper.setup_providers() with real external providers.

  Simulates an RPC provider with configurable:
  - Latency (fixed delay before responding)
  - Reliability (probability of success vs failure)
  - Response data (customizable JSON-RPC responses)

  Limitations:
  - HTTP only (no WebSocket support)
  - Does not integrate with ConfigStore
  - Not representative of real provider behavior
  """

  use Plug.Router
  require Logger

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:dispatch)

  # State stored in process dictionary for simplicity
  # In production, you'd use an Agent or GenServer

  post "/" do
    config = Process.get(:mock_provider_config, %{})

    # Simulate latency
    latency = Map.get(config, :latency, 0)
    if latency > 0, do: Process.sleep(latency)

    # Simulate reliability
    reliability = Map.get(config, :reliability, 1.0)
    should_succeed? = :rand.uniform() <= reliability

    if should_succeed? do
      # Parse request
      request = conn.body_params

      # Generate response
      response = generate_response(request, config)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(response))
    else
      # Simulate provider failure
      conn
      |> send_resp(500, "Internal Server Error")
    end
  end

  @doc """
  Starts mock providers and registers them in ConfigStore.

  ## Options

  - `:latency` - Fixed delay in milliseconds (default: 0)
  - `:reliability` - Success probability 0.0-1.0 (default: 1.0)
  - `:url` - Override URL (default: auto-generated from port)
  - `:response_fn` - Custom response generator function

  ## Example

      MockProvider.start_providers([
        {:provider_a, latency: 50, reliability: 1.0},
        {:provider_b, latency: 100, reliability: 0.95}
      ])
      # => [{:provider_a, 8080}, {:provider_b, 8081}]
  """
  def start_providers(specs) do
    Enum.map(specs, fn {provider_id, opts} ->
      port = Keyword.get(opts, :port, find_free_port())

      # Store config in persistent storage (could use ETS or Agent)
      config = %{
        latency: Keyword.get(opts, :latency, 0),
        reliability: Keyword.get(opts, :reliability, 1.0),
        response_fn: Keyword.get(opts, :response_fn),
        provider_id: provider_id
      }

      # Start HTTP server
      {:ok, _pid} =
        Plug.Cowboy.http(__MODULE__, config,
          port: port,
          ref: provider_id,
          dispatch: [
            {:_,
             [
               {"/", __MODULE__, config}
             ]}
          ]
        )

      url = "http://localhost:#{port}"
      ws_url = "ws://localhost:#{port}/ws"

      # Register provider in ConfigStore
      register_provider_in_config_store(provider_id, url, ws_url, opts)

      Logger.debug("Started mock provider #{provider_id} on port #{port}")

      {provider_id, port}
    end)
  end

  @doc """
  Stops mock providers by provider ID.
  """
  def stop_providers(provider_ids) do
    Enum.each(provider_ids, fn provider_id ->
      try do
        Plug.Cowboy.shutdown(provider_id)
      catch
        :exit, _ -> :ok
      end
    end)
  end

  # Private helpers

  defp generate_response(request, config) do
    case Map.get(config, :response_fn) do
      nil -> default_response(request)
      response_fn -> response_fn.(request)
    end
  end

  defp default_response(%{"method" => "eth_blockNumber"}) do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "result" => "0x" <> Integer.to_string(:rand.uniform(10_000_000), 16)
    }
  end

  defp default_response(%{"method" => "eth_getBalance"}) do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "result" => "0x" <> Integer.to_string(:rand.uniform(1_000_000_000_000_000_000), 16)
    }
  end

  defp default_response(%{"method" => "eth_gasPrice"}) do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "result" => "0x" <> Integer.to_string(:rand.uniform(100_000_000_000), 16)
    }
  end

  defp default_response(%{"method" => "eth_call"}) do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "result" => "0x0000000000000000000000000000000000000000000000000000000000000001"
    }
  end

  defp default_response(%{"method" => _method}) do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "result" => "0x0"
    }
  end

  defp default_response(_) do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "error" => %{
        "code" => -32600,
        "message" => "Invalid Request"
      }
    }
  end

  defp find_free_port do
    # Simple port finder: start from 9000 and increment
    # In production, use :gen_tcp to find truly free port
    base_port = 9000
    offset = :rand.uniform(5000)
    base_port + offset
  end

  defp register_provider_in_config_store(provider_id, url, _ws_url, opts) do
    # NOTE: ConfigStore doesn't support dynamic updates.
    # MockProvider is NOT RECOMMENDED for battle testing.
    # Use SetupHelper.setup_providers() with real providers instead.

    Logger.debug(
      "Mock provider #{provider_id} started (url: #{url}) - NOT registered in ConfigStore"
    )

    # Return minimal info for logging
    {opts[:chain] || "mockchain", nil}
  end

  # Plug.Cowboy callback
  def init(options, config) do
    # Store config in process dictionary for this worker
    Process.put(:mock_provider_config, config)
    {:ok, options}
  end

  def call(conn, opts) do
    # Store config in process dictionary
    Process.put(:mock_provider_config, opts)
    super(conn, opts)
  end
end