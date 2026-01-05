defmodule Lasso.RPC.Transport.HTTP.Client do
  @moduledoc """
  Behaviour for HTTP JSON-RPC clients used to contact upstream RPC providers.

  Implementations must perform a single JSON-RPC HTTP request with a
  per-call timeout and return either a decoded JSON map or a typed error.

  This module also provides a small facade for dispatching to the configured
  adapter. Configure with:

      config :lasso, :http_client, Lasso.RPC.Transport.HTTP.Client.Finch
  """

  @type provider_config :: %{required(:url) => String.t(), optional(:api_key) => String.t()}
  @type json_map :: map()
  @type method :: String.t()
  @type params :: list()

  @type opts :: keyword()
  @type error_payload :: String.t() | map()
  @type error_reason ::
          {:rate_limit, error_payload}
          | {:server_error, error_payload}
          | {:client_error, error_payload}
          | {:network_error, error_payload}
          | {:encode_error, String.t()}
          | {:response_decode_error, String.t()}

  # Raw bytes response
  @type raw_response :: {:raw, binary()}

  @callback request(provider_config, method, params, opts) ::
              {:ok, raw_response()} | {:error, error_reason}

  # Facade to configured adapter
  @spec request(provider_config, method, params, opts) ::
          {:ok, raw_response()} | {:error, error_reason}
  def request(provider_config, method, params, opts \\ []) do
    adapter()
    |> apply(:request, [provider_config, method, params, opts])
  end

  @doc """
  Makes an HTTP request and decodes the JSON response.

  This is for cold-path callers (discovery, probes, etc.) that need
  decoded JSON maps rather than raw passthrough bytes.
  """
  @spec request_decoded(provider_config, method, params, opts) ::
          {:ok, json_map()} | {:error, error_reason}
  def request_decoded(provider_config, method, params, opts \\ []) do
    case request(provider_config, method, params, opts) do
      {:ok, {:raw, bytes}} ->
        case Jason.decode(bytes) do
          {:ok, json} -> {:ok, json}
          {:error, reason} -> {:error, {:response_decode_error, inspect(reason)}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp adapter do
    Application.get_env(:lasso, :http_client, Lasso.RPC.Transport.HTTP.Client.Finch)
  end
end
