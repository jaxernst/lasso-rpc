defmodule Livechain.Config.ConfigValidator do
  @moduledoc """
  Enhanced validation for chain configurations.

  Provides comprehensive validation including provider endpoint checks,
  conflict detection, and format validation beyond basic struct validation.
  """

  require Logger
  alias Livechain.Config.ChainConfig

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
         :ok <- validate_connection_settings(chain_config.connection),
         :ok <- validate_failover_settings(chain_config.failover) do
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
  Validates connection settings are reasonable.
  """
  @spec validate_connection_settings(ChainConfig.Connection.t()) :: :ok | {:error, term()}
  def validate_connection_settings(connection) do
    cond do
      connection.heartbeat_interval < 1000 ->
        {:error, :heartbeat_too_frequent}

      connection.heartbeat_interval > 300_000 ->
        {:error, :heartbeat_too_infrequent}

      connection.reconnect_interval < 100 ->
        {:error, :reconnect_too_frequent}

      connection.reconnect_interval > 60_000 ->
        {:error, :reconnect_too_infrequent}

      connection.max_reconnect_attempts < 1 ->
        {:error, :invalid_reconnect_attempts}

      connection.max_reconnect_attempts > 100 ->
        {:error, :too_many_reconnect_attempts}

      true ->
        :ok
    end
  end

  @doc """
  Validates failover settings are reasonable.
  """
  @spec validate_failover_settings(ChainConfig.Failover.t()) :: :ok | {:error, term()}
  def validate_failover_settings(failover) do
    cond do
      failover.max_backfill_blocks < 0 ->
        {:error, :invalid_backfill_blocks}

      failover.max_backfill_blocks > 10_000 ->
        {:error, :backfill_blocks_too_large}

      failover.backfill_timeout < 1000 ->
        {:error, :backfill_timeout_too_short}

      failover.backfill_timeout > 300_000 ->
        {:error, :backfill_timeout_too_long}

      not is_boolean(failover.enabled) ->
        {:error, :invalid_failover_enabled}

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
  def format_error(:heartbeat_too_frequent), do: "Heartbeat interval must be >= 1000ms"
  def format_error(:heartbeat_too_infrequent), do: "Heartbeat interval must be <= 300000ms"
  def format_error(:reconnect_too_frequent), do: "Reconnect interval must be >= 100ms"
  def format_error(:reconnect_too_infrequent), do: "Reconnect interval must be <= 60000ms"
  def format_error(:invalid_reconnect_attempts), do: "Max reconnect attempts must be >= 1"
  def format_error(:too_many_reconnect_attempts), do: "Max reconnect attempts must be <= 100"
  def format_error(:cache_size_too_small), do: "Cache size must be >= 100"
  def format_error(:cache_size_too_large), do: "Cache size must be <= 1000000"
  def format_error(:invalid_backfill_blocks), do: "Max backfill blocks must be >= 0"
  def format_error(:backfill_blocks_too_large), do: "Max backfill blocks should be <= 10000"
  def format_error(:backfill_timeout_too_short), do: "Backfill timeout must be >= 1000ms"
  def format_error(:backfill_timeout_too_long), do: "Backfill timeout must be <= 300000ms"
  def format_error(:invalid_failover_enabled), do: "Failover enabled must be a boolean"

  def format_error({:connectivity_failed, provider_id, reason}),
    do: "Provider #{provider_id} connectivity test failed: #{inspect(reason)}"

  def format_error(error), do: "Validation error: #{inspect(error)}"

  # Private functions

  defp validate_basic_structure(chain_config) do
    required_fields = [:chain_id, :name, :providers, :connection, :failover]

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

    case Finch.request(request, Livechain.Finch, receive_timeout: @http_timeout) do
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
