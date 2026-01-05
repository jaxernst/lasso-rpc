defmodule Lasso.RPC.Transport.HTTP.Client.Finch do
  @moduledoc """
  Finch-based implementation of `Lasso.RPC.Transport.HTTP.Client`.
  """

  @behaviour Lasso.RPC.Transport.HTTP.Client
  require Logger

  @impl true
  def request(%{url: url} = provider, method, params, opts) do
    # Extract options with defaults
    request_id = Keyword.get(opts, :request_id) || generate_id()
    timeout_ms = Keyword.get(opts, :timeout, 30_000)

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
           Finch.request(req, Lasso.Finch, receive_timeout: timeout_ms) do
      handle_response(status, resp_body)
    else
      {:error, %Mint.TransportError{reason: :timeout}} ->
        {:error, {:network_error, "Connection timeout"}}

      # Handle NimblePool checkout errors specifically
      {:error, {:exit, {{:shutdown, :idle_timeout}, {NimblePool, :checkout, _}}}} ->
        Logger.warning("Finch connection pool idle timeout",
          provider_url: url,
          request_id: request_id
        )

        # Emit telemetry for monitoring
        :telemetry.execute(
          [:lasso, :finch, :pool_idle_timeout],
          %{count: 1},
          %{provider_url: url, request_id: request_id}
        )

        {:error, {:network_error, "Connection pool idle timeout"}}

      # Handle other NimblePool errors
      {:error, {:exit, {{:shutdown, reason}, {NimblePool, :checkout, _}}}} ->
        Logger.warning("Finch connection pool checkout failed",
          provider_url: url,
          request_id: request_id,
          shutdown_reason: reason
        )

        # Emit telemetry for monitoring
        :telemetry.execute(
          [:lasso, :finch, :pool_checkout_failed],
          %{count: 1},
          %{provider_url: url, request_id: request_id, reason: reason}
        )

        {:error, {:network_error, "Connection pool checkout failed: #{reason}"}}

      {:error, %Mint.TransportError{reason: reason}} ->
        Logger.debug("Finch request failed - Mint transport error",
          provider_url: url,
          request_id: request_id,
          reason: reason
        )

        message =
          case reason do
            :timeout -> "Connection timeout"
            :closed -> "Connection closed"
            :econnrefused -> "Connection refused"
            {:error, :nxdomain} -> "DNS resolution failed"
            {:error, reason} when is_atom(reason) -> "Connection error: #{reason}"
            _ -> "Connection error"
          end

        {:error, {:network_error, message}}

      {:error, reason} ->
        Logger.debug("Finch request failed",
          provider_url: url,
          request_id: request_id,
          error: inspect(reason)
        )

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
    # Return raw bytes for passthrough optimization
    # The caller (HTTP transport) will parse using Response.from_bytes/1
    {:ok, {:raw, body}}
  end

  defp handle_response(429, body), do: {:error, {:rate_limit, %{status: 429, body: body}}}

  # Treat 408 Request Timeout as retriable infrastructure failure
  defp handle_response(408, body), do: {:error, {:server_error, %{status: 408, body: body}}}

  defp handle_response(status, body) when status >= 500,
    do: {:error, {:server_error, %{status: status, body: body}}}

  defp handle_response(status, body), do: {:error, {:client_error, %{status: status, body: body}}}

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
