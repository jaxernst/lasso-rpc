defmodule Livechain.RPC.HttpClient.Finch do
  @moduledoc """
  Finch-based implementation of `Livechain.RPC.HttpClient`.
  """

  @behaviour Livechain.RPC.HttpClient

  @impl true
  def request(%{url: url} = provider, method, params, timeout_ms) do
    request_id = generate_id()

    body = %{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => params,
      "id" => request_id
    }

    with {:ok, json} <- Jason.encode(body),
         headers <- base_headers(provider),
         req <- Finch.build(:post, url, headers, json),
         {:ok, %Finch.Response{status: status, body: resp_body}} <-
           Finch.request(req, Livechain.Finch, receive_timeout: timeout_ms) do
      handle_response(status, resp_body)
    else
      {:error, :timeout} ->
        {:error, {:network_error, "Timeout"}}

      {:error, %Mint.TransportError{reason: :timeout}} ->
        {:error, {:network_error, "Connection timeout"}}

      {:error, reason} ->
        {:error, {:network_error, "Request failed: #{inspect(reason)}"}}
    end
  end

  defp base_headers(%{api_key: api_key}) when is_binary(api_key) and byte_size(api_key) > 0 do
    [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]
  end

  defp base_headers(_), do: [{"content-type", "application/json"}, {"accept", "application/json"}]

  defp handle_response(status, body) when status in 200..299 do
    case Jason.decode(body) do
      # JSON-RPC error response in successful HTTP response
      {:ok, %{"error" => error} = response} when is_map(error) ->
        # Return the full response so it can be properly normalized upstream
        # This preserves the error structure for consistent handling
        {:ok, response}

      # Successful JSON-RPC response
      {:ok, %{"result" => _} = response} ->
        {:ok, response}

      # Valid JSON but not JSON-RPC format: treat as invalid provider response (infra)
      {:ok, decoded} ->
        {:error, {:response_decode_error, "Invalid JSON-RPC response shape: #{inspect(decoded)}"}}

      {:error, decode_error} ->
        {:error, {:response_decode_error, "Failed to decode response: #{inspect(decode_error)}"}}
    end
  end

  defp handle_response(429, body), do: {:error, {:rate_limit, %{status: 429, body: body}}}

  # Treat 408 Request Timeout as retriable infrastructure failure
  defp handle_response(408, body), do: {:error, {:server_error, %{status: 408, body: body}}}

  defp handle_response(status, body) when status >= 500,
    do: {:error, {:server_error, %{status: status, body: body}}}

  defp handle_response(status, body), do: {:error, {:client_error, %{status: status, body: body}}}

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
