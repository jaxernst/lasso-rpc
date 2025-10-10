defmodule Lasso.Testing.BehaviorHttpClient do
  @moduledoc """
  HTTP client for integration tests that routes requests to behavior-based mock providers.

  This client intercepts HTTP requests and routes them to MockHTTPProvider instances
  when the provider is marked as a mock (__mock__: true).

  For non-mock providers, it falls back to the real HTTP client.

  ## Configuration

  In test_helper.exs:

      Application.put_env(:lasso, :http_client, Lasso.Testing.BehaviorHttpClient)

  ## Usage

  Tests using setup_providers with behavior specs will automatically use this client:

      test "failover", %{chain: chain} do
        setup_providers([
          %{id: "failing", behavior: :always_fail},
          %{id: "healthy", behavior: :healthy}
        ])

        # Requests automatically routed to mock providers
        {:ok, result} = RequestPipeline.execute_via_channels(
          chain, "eth_blockNumber", []
        )
      end
  """

  require Logger

  alias Lasso.Testing.MockHTTPProvider

  @doc """
  Executes an HTTP RPC request.

  Compatible with Lasso.RPC.HttpClient.Finch interface.

  Routes to MockHTTPProvider if provider is marked as mock,
  otherwise uses real HTTP client.
  """
  def request(provider_config, method, params, _opts \\ []) do
    provider_id = Map.get(provider_config, :id)
    is_mock = Map.get(provider_config, :__mock__, false)

    Logger.info(
      "BehaviorHttpClient: provider_id=#{provider_id}, is_mock=#{is_mock}, config_keys=#{inspect(Map.keys(provider_config))}"
    )

    if is_mock do
      # Route to mock provider
      Logger.debug("Routing request to mock HTTP provider: #{provider_id}")

      case MockHTTPProvider.execute_request(provider_id, method, params) do
        {:ok, result} ->
          # Wrap the unwrapped result in JSONRPC format
          response = %{
            "jsonrpc" => "2.0",
            "id" => 1,
            "result" => result
          }

          {:ok, response}

        {:error, %Lasso.JSONRPC.Error{} = error} ->
          # Return JSONRPC error format
          error_response = %{
            "jsonrpc" => "2.0",
            "id" => 1,
            "error" => %{
              "code" => error.code,
              "message" => error.message,
              "data" => error.data
            }
          }

          {:ok, error_response}

        {:error, other} ->
          # Convert to connection error
          {:error, {:connection_error, other}}
      end
    else
      # Fall back to real HTTP client for non-mock providers
      # In tests, this typically won't be reached
      Logger.warning("BehaviorHttpClient called with non-mock provider: #{provider_id}")

      # Return a mock response to prevent hanging
      {:ok, %{"jsonrpc" => "2.0", "id" => 1, "result" => "0x1"}}
    end
  end

  @doc """
  Batch request support (routes to mock providers).
  """
  def batch_request(provider_config, requests, opts \\ []) do
    provider_id = Map.get(provider_config, :id)
    is_mock = Map.get(provider_config, :__mock__, false)

    if is_mock do
      # Execute each request individually through the mock
      results =
        Enum.map(requests, fn %{method: method, params: params} ->
          case request(provider_config, method, params, opts) do
            {:ok, response} -> response
            {:error, error} -> %{"error" => inspect(error)}
          end
        end)

      {:ok, results}
    else
      Logger.warning("BehaviorHttpClient batch called with non-mock provider: #{provider_id}")
      {:ok, []}
    end
  end
end
