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
      {:error, reason} ->
        {:error, {:network_error, "Request failed: #{inspect(reason)}"}}

      {:error, :timeout} ->
        {:error, {:network_error, "Timeout"}}

      {:error, encode_err} ->
        {:error, {:decode_error, "Failed to encode request: #{inspect(encode_err)}"}}
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
      {:ok, %{"error" => %{"code" => code, "message" => message}}}
      when code in [-32005, -32000] ->
        {:error, {:rate_limit, message || "Rate limit exceeded"}}

      {:ok, decoded} ->
        {:ok, decoded}

      {:error, decode_error} ->
        {:error, {:decode_error, "Failed to decode response: #{inspect(decode_error)}"}}
    end
  end

  defp handle_response(429, body), do: {:error, {:rate_limit, "HTTP 429: #{body}"}}

  defp handle_response(status, body) when status >= 500,
    do: {:error, {:server_error, "HTTP #{status}: #{body}"}}

  defp handle_response(status, body), do: {:error, {:client_error, "HTTP #{status}: #{body}"}}

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
