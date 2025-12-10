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
        {:ok, result, _ctx} = RequestPipeline.execute_via_channels(
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
  def request(provider_config, method, params, opts \\ []) do
    provider_id = Map.get(provider_config, :id)
    is_mock = Map.get(provider_config, :__mock__, false)
    request_id = Keyword.get(opts, :request_id, 1)

    Logger.info(
      "BehaviorHttpClient: provider_id=#{provider_id}, is_mock=#{is_mock}, config_keys=#{inspect(Map.keys(provider_config))}"
    )

    if is_mock do
      # Route to mock provider
      Logger.debug("Routing request to mock HTTP provider: #{provider_id}")

      case MockHTTPProvider.execute_request(provider_id, method, params) do
        {:ok, result} ->
          # Wrap the unwrapped result in JSONRPC format and return as raw bytes
          # This matches the production HttpClient interface: {:ok, {:raw, bytes}}
          response = %{
            "jsonrpc" => "2.0",
            "id" => request_id,
            "result" => result
          }

          {:ok, {:raw, Jason.encode!(response)}}

        {:error, %Lasso.JSONRPC.Error{} = error} ->
          # Return JSONRPC error format as raw bytes
          error_response = %{
            "jsonrpc" => "2.0",
            "id" => request_id,
            "error" => %{
              "code" => error.code,
              "message" => error.message,
              "data" => error.data
            }
          }

          {:ok, {:raw, Jason.encode!(error_response)}}

        {:error, other} ->
          # Convert to connection error
          {:error, {:connection_error, other}}
      end
    else
      # Fall back to real HTTP client for non-mock providers
      # In tests, this typically won't be reached
      Logger.warning("BehaviorHttpClient called with non-mock provider: #{provider_id}")

      # Return a mock response as raw bytes to prevent hanging
      {:ok, {:raw, Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => "0x1"})}}
    end
  end

  @doc """
  Batch request support (routes to mock providers).

  Returns {:ok, {:raw, bytes}} where bytes is JSON array of responses.
  """
  def batch_request(provider_config, requests, opts \\ []) do
    provider_id = Map.get(provider_config, :id)
    is_mock = Map.get(provider_config, :__mock__, false)

    if is_mock do
      # Execute each request individually through the mock
      results =
        requests
        |> Enum.with_index(1)
        |> Enum.map(fn {%{method: method, params: params}, idx} ->
          request_opts = Keyword.put(opts, :request_id, idx)

          case request(provider_config, method, params, request_opts) do
            {:ok, {:raw, bytes}} ->
              # Decode the raw bytes to build the batch array
              Jason.decode!(bytes)

            {:error, error} ->
              %{"jsonrpc" => "2.0", "id" => idx, "error" => %{"code" => -32_000, "message" => inspect(error)}}
          end
        end)

      # Return the batch array as raw bytes
      {:ok, {:raw, Jason.encode!(results)}}
    else
      Logger.warning("BehaviorHttpClient batch called with non-mock provider: #{provider_id}")
      {:ok, {:raw, "[]"}}
    end
  end
end
