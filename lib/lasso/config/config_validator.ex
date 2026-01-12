defmodule Lasso.Config.ConfigValidator do
  @moduledoc """
  Enhanced validation for chain configurations.

  Provides comprehensive validation including provider endpoint checks,
  conflict detection, and format validation beyond basic struct validation.
  """

  require Logger
  alias Lasso.Config.ChainConfig

  @http_timeout 5000

  @doc """
  Validates a complete chain configuration with enhanced checks.
  """
  @spec validate_chain_config(ChainConfig.t(), keyword()) :: :ok | {:error, term()}
  def validate_chain_config(chain_config, opts \\ []) do
    skip_connectivity = Keyword.get(opts, :skip_connectivity, false)

    with :ok <- validate_basic_structure(chain_config),
         :ok <- validate_chain_id(chain_config.chain_id),
         :ok <- validate_providers(chain_config.providers, skip_connectivity),
         :ok <- validate_provider_priorities(chain_config.providers),
         :ok <- validate_websocket_settings(chain_config.websocket) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Validates a list of providers for conflicts and completeness.
  """
  @spec validate_providers([ChainConfig.Provider.t()], boolean()) :: :ok | {:error, term()}
  def validate_providers(providers, skip_connectivity \\ true) do
    with :ok <- validate_providers_not_empty(providers),
         :ok <- validate_provider_ids_unique(providers),
         :ok <- validate_provider_urls_unique(providers),
         :ok <- validate_provider_structures(providers) do
      if skip_connectivity do
        :ok
      else
        validate_provider_connectivity(providers)
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Tests connectivity to a provider endpoint.
  """
  @spec test_provider_connectivity(ChainConfig.Provider.t()) :: :ok | {:error, term()}
  def test_provider_connectivity(provider) do
    case make_test_request(provider.url) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, {:connectivity_failed, provider.id, reason}}
    end
  end

  @doc """
  Validates provider URL format and accessibility.
  """
  @spec validate_provider_url(String.t()) :: :ok | {:error, term()}
  def validate_provider_url(url) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      is_nil(uri.scheme) -> {:error, :missing_url_scheme}
      uri.scheme not in ["http", "https", "ws", "wss"] -> {:error, :invalid_url_scheme}
      is_nil(uri.host) -> {:error, :missing_url_host}
      String.length(uri.host) == 0 -> {:error, :empty_url_host}
      true -> :ok
    end
  end

  def validate_provider_url(_), do: {:error, :invalid_url_format}

  @doc """
  Validates chain ID is a positive integer.
  """
  @spec validate_chain_id(pos_integer()) :: :ok | {:error, term()}
  def validate_chain_id(chain_id) when is_integer(chain_id) and chain_id > 0, do: :ok
  def validate_chain_id(_), do: {:error, :invalid_chain_id}

  @doc """
  Validates that provider priorities make sense.
  """
  @spec validate_provider_priorities([ChainConfig.Provider.t()]) :: :ok | {:error, term()}
  def validate_provider_priorities(providers) do
    priorities = Enum.map(providers, & &1.priority)

    cond do
      Enum.any?(priorities, &(&1 < 1)) ->
        {:error, :invalid_priority_range}

      length(Enum.uniq(priorities)) != length(priorities) ->
        {:error, :duplicate_priorities}

      true ->
        :ok
    end
  end

  @doc """
  Validates websocket settings are reasonable.
  """
  @spec validate_websocket_settings(ChainConfig.Websocket.t()) :: :ok | {:error, term()}
  def validate_websocket_settings(websocket) do
    with :ok <- validate_websocket_main(websocket),
         :ok <- validate_websocket_failover(websocket.failover) do
      :ok
    end
  end

  defp validate_websocket_main(websocket) do
    cond do
      not is_boolean(websocket.subscribe_new_heads) ->
        {:error, :invalid_subscribe_new_heads}

      websocket.new_heads_timeout_ms < 5000 ->
        {:error, :new_heads_timeout_too_short}

      websocket.new_heads_timeout_ms > 120_000 ->
        {:error, :new_heads_timeout_too_long}

      true ->
        :ok
    end
  end

  defp validate_websocket_failover(failover) do
    cond do
      failover.max_backfill_blocks < 1 ->
        {:error, :invalid_backfill_blocks}

      failover.max_backfill_blocks > 10_000 ->
        {:error, :backfill_blocks_too_large}

      failover.backfill_timeout_ms < 5000 ->
        {:error, :backfill_timeout_too_short}

      failover.backfill_timeout_ms > 300_000 ->
        {:error, :backfill_timeout_too_long}

      true ->
        :ok
    end
  end

  @doc """
  Provides human-readable error messages for validation errors.
  """
  @spec format_error(term()) :: String.t()
  def format_error(:missing_url_scheme),
    do: "Provider URL must include a scheme (http/https/ws/wss)"

  def format_error(:invalid_url_scheme), do: "Provider URL scheme must be http, https, ws, or wss"
  def format_error(:missing_url_host), do: "Provider URL must include a host"
  def format_error(:empty_url_host), do: "Provider URL host cannot be empty"
  def format_error(:invalid_url_format), do: "Provider URL must be a valid string"
  def format_error(:invalid_chain_id), do: "Chain ID must be a positive integer"
  def format_error(:no_providers), do: "Chain must have at least one provider"
  def format_error(:duplicate_provider_ids), do: "Provider IDs must be unique"
  def format_error(:duplicate_provider_urls), do: "Provider URLs must be unique"
  def format_error(:invalid_provider_structure), do: "Provider must have id, name, and url"
  def format_error(:invalid_priority_range), do: "Provider priorities must be >= 1"
  def format_error(:duplicate_priorities), do: "Provider priorities must be unique"
  def format_error(:invalid_subscribe_new_heads), do: "subscribe_new_heads must be a boolean"
  def format_error(:new_heads_timeout_too_short), do: "new_heads_timeout_ms must be >= 5000ms"
  def format_error(:new_heads_timeout_too_long), do: "new_heads_timeout_ms must be <= 120000ms"
  def format_error(:invalid_backfill_blocks), do: "max_backfill_blocks must be >= 1"
  def format_error(:backfill_blocks_too_large), do: "max_backfill_blocks should be <= 10000"
  def format_error(:backfill_timeout_too_short), do: "backfill_timeout_ms must be >= 5000ms"
  def format_error(:backfill_timeout_too_long), do: "backfill_timeout_ms must be <= 300000ms"

  def format_error({:connectivity_failed, provider_id, reason}),
    do: "Provider #{provider_id} connectivity test failed: #{inspect(reason)}"

  def format_error(error), do: "Validation error: #{inspect(error)}"

  # Private functions

  defp validate_basic_structure(chain_config) do
    required_fields = [:chain_id, :name, :providers, :websocket]

    missing_fields =
      Enum.filter(required_fields, fn field ->
        Map.get(chain_config, field) == nil
      end)

    if Enum.empty?(missing_fields) do
      :ok
    else
      {:error, {:missing_required_fields, missing_fields}}
    end
  end

  defp validate_providers_not_empty([]), do: {:error, :no_providers}
  defp validate_providers_not_empty(_), do: :ok

  defp validate_provider_ids_unique(providers) do
    ids = Enum.map(providers, & &1.id)

    if length(ids) == length(Enum.uniq(ids)) do
      :ok
    else
      {:error, :duplicate_provider_ids}
    end
  end

  defp validate_provider_urls_unique(providers) do
    urls = Enum.map(providers, & &1.url) |> Enum.filter(&(&1 != nil))

    if length(urls) == length(Enum.uniq(urls)) do
      :ok
    else
      {:error, :duplicate_provider_urls}
    end
  end

  defp validate_provider_structures(providers) do
    invalid_provider =
      Enum.find(providers, fn provider ->
        is_nil(provider.id) or is_nil(provider.name) or is_nil(provider.url)
      end)

    if invalid_provider do
      {:error, :invalid_provider_structure}
    else
      # Also validate each URL format
      case Enum.find(providers, fn provider ->
             case validate_provider_url(provider.url) do
               :ok -> false
               _error -> true
             end
           end) do
        nil -> :ok
        _invalid_provider -> {:error, :invalid_provider_url}
      end
    end
  end

  defp validate_provider_connectivity(providers) do
    # Test connectivity to each provider
    results =
      Enum.map(providers, fn provider ->
        {provider.id, test_provider_connectivity(provider)}
      end)

    failed_providers =
      Enum.filter(results, fn {_id, result} ->
        match?({:error, _}, result)
      end)

    if Enum.empty?(failed_providers) do
      :ok
    else
      failed_ids = Enum.map(failed_providers, fn {id, _} -> id end)
      Logger.warning("Providers failed connectivity test: #{Enum.join(failed_ids, ", ")}")
      # Still return :ok as connectivity issues might be temporary
      :ok
    end
  end

  defp make_test_request(url) do
    # Make a simple eth_blockNumber request to test connectivity using Finch
    headers = [{"Content-Type", "application/json"}]

    body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        method: "eth_blockNumber",
        params: [],
        id: 1
      })

    request = Finch.build(:post, url, headers, body)

    case Finch.request(request, Lasso.Finch, receive_timeout: @http_timeout) do
      {:ok, %Finch.Response{status: 200}} ->
        {:ok, :connected}

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, %Mint.TransportError{reason: reason}} ->
        {:error, {:connection_error, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, {:request_exception, error}}
  end
end
