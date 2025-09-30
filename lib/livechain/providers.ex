defmodule Livechain.Providers do
  @moduledoc """
  Public API for dynamic provider management.

  This module provides a clean interface for adding, removing, and managing
  RPC providers at runtime without requiring application restarts or YAML edits.

  ## Usage

  Add a provider dynamically:

      Livechain.Providers.add_provider("ethereum", %{
        id: "alchemy_backup",
        name: "Alchemy Backup",
        url: "https://eth-mainnet.g.alchemy.com/v2/YOUR-KEY",
        ws_url: "wss://eth-mainnet.g.alchemy.com/v2/YOUR-KEY",
        type: "premium",
        priority: 50
      })

  Remove a provider:

      Livechain.Providers.remove_provider("ethereum", "alchemy_backup")

  List all providers for a chain:

      Livechain.Providers.list_providers("ethereum")

  ## Persistence

  By default, providers are added only to the running system. To persist
  changes to the YAML configuration file:

      Livechain.Providers.add_provider("ethereum", provider_config, persist: true)

  ## Architecture

  This module coordinates:
  - `ChainSupervisor` - Runtime lifecycle (WS connections, circuit breakers)
  - `ProviderPool` - Health tracking and availability
  - `TransportRegistry` - Lazy channel opening
  - `ConfigValidator` - Input validation
  - `ChainConfigManager` - Optional persistence to YAML

  The provider becomes immediately available for request routing after `add_provider/3` returns.
  """

  require Logger
  alias Livechain.Config.{ConfigValidator, ChainConfigManager}
  alias Livechain.RPC.{ChainSupervisor, ProviderPool}

  @type provider_config :: %{
          id: String.t(),
          name: String.t(),
          url: String.t(),
          ws_url: String.t() | nil,
          type: String.t(),
          priority: integer(),
          api_key_required: boolean() | nil,
          region: String.t() | nil
        }

  @type provider_summary :: %{
          id: String.t(),
          name: String.t(),
          status: atom(),
          availability: atom(),
          has_http: boolean(),
          has_ws: boolean()
        }

  @doc """
  Adds a provider to a chain dynamically.

  ## Options

  - `:persist` - Whether to save to YAML config file (default: false)
  - `:start_ws` - WebSocket startup policy: `:auto`, `:force`, or `:skip` (default: `:auto`)
  - `:validate` - Whether to validate configuration (default: true)

  ## Returns

  - `{:ok, provider_id}` - Provider successfully added
  - `{:error, reason}` - Validation or startup failed

  ## Example

      # Add provider (runtime only)
      Livechain.Providers.add_provider("ethereum", %{
        id: "new_provider",
        name: "New Provider",
        url: "https://rpc.example.com",
        ws_url: "wss://ws.example.com",
        type: "public",
        priority: 100
      })

      # Add and persist to YAML
      Livechain.Providers.add_provider("ethereum", provider_config, persist: true)
  """
  @spec add_provider(String.t(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def add_provider(chain_name, provider_attrs, opts \\ []) do
    persist? = Keyword.get(opts, :persist, false)
    validate? = Keyword.get(opts, :validate, true)
    start_ws = Keyword.get(opts, :start_ws, :auto)

    provider_config = normalize_provider_config(provider_attrs)
    provider_id = Map.get(provider_config, :id)

    with :ok <- maybe_validate(provider_config, validate?),
         :ok <- check_not_duplicate(chain_name, provider_id),
         :ok <- ChainSupervisor.ensure_provider(chain_name, provider_config, start_ws: start_ws),
         :ok <- maybe_persist_add(chain_name, provider_config, persist?) do
      Logger.info("Successfully added provider #{provider_id} to #{chain_name}")
      {:ok, provider_id}
    else
      {:error, reason} = error ->
        Logger.error("Failed to add provider #{provider_id} to #{chain_name}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Removes a provider from a chain.

  ## Options

  - `:persist` - Whether to remove from YAML config file (default: false)

  ## Returns

  - `:ok` - Provider successfully removed
  - `{:error, reason}` - Provider not found or removal failed

  ## Example

      # Remove provider (runtime only)
      Livechain.Providers.remove_provider("ethereum", "old_provider")

      # Remove and persist to YAML
      Livechain.Providers.remove_provider("ethereum", "old_provider", persist: true)
  """
  @spec remove_provider(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def remove_provider(chain_name, provider_id, opts \\ []) do
    persist? = Keyword.get(opts, :persist, false)

    with :ok <- ChainSupervisor.remove_provider(chain_name, provider_id),
         :ok <- maybe_persist_remove(chain_name, provider_id, persist?) do
      Logger.info("Successfully removed provider #{provider_id} from #{chain_name}")
      :ok
    else
      {:error, reason} = error ->
        Logger.error(
          "Failed to remove provider #{provider_id} from #{chain_name}: #{inspect(reason)}"
        )

        error
    end
  end

  @doc """
  Updates a provider configuration.

  Note: Currently implemented as remove + add to avoid complex state mutations.
  The provider will experience brief downtime during the update.

  ## Options

  - `:persist` - Whether to update in YAML config file (default: false)

  ## Example

      Livechain.Providers.update_provider("ethereum", "my_provider", %{
        url: "https://new-rpc-url.com",
        priority: 200
      })
  """
  @spec update_provider(String.t(), String.t(), map(), keyword()) :: :ok | {:error, term()}
  def update_provider(chain_name, provider_id, updates, opts \\ []) do
    persist? = Keyword.get(opts, :persist, false)

    # Get existing provider config
    with {:ok, existing} <- get_provider(chain_name, provider_id),
         updated_config = Map.merge(existing, normalize_provider_config(updates)),
         :ok <- remove_provider(chain_name, provider_id, persist: false),
         {:ok, _} <- add_provider(chain_name, updated_config, persist: persist?) do
      Logger.info("Successfully updated provider #{provider_id} in #{chain_name}")
      :ok
    else
      {:error, reason} = error ->
        Logger.error(
          "Failed to update provider #{provider_id} in #{chain_name}: #{inspect(reason)}"
        )

        error
    end
  end

  @doc """
  Lists all providers for a chain with their current status.

  ## Returns

  `{:ok, [provider_summary]}` where each summary includes:
  - `:id` - Provider identifier
  - `:name` - Human-readable name
  - `:status` - Health status (`:healthy`, `:unhealthy`, etc.)
  - `:availability` - Routing availability (`:up`, `:down`, `:limited`)
  - `:has_http` - Whether HTTP transport is configured
  - `:has_ws` - Whether WebSocket transport is configured

  ## Example

      {:ok, providers} = Livechain.Providers.list_providers("ethereum")
      Enum.each(providers, fn provider ->
        IO.puts("\#{provider.name}: \#{provider.status} (\#{provider.availability})")
      end)
  """
  @spec list_providers(String.t()) :: {:ok, [provider_summary()]} | {:error, term()}
  def list_providers(chain_name) do
    case ProviderPool.get_status(chain_name) do
      {:ok, status} ->
        summaries =
          Enum.map(status.providers, fn provider ->
            %{
              id: provider.id,
              name: Map.get(provider, :name, provider.id),
              status: provider.status,
              availability: provider.availability,
              has_http: is_binary(get_in(provider, [:config, :url])),
              has_ws: is_binary(get_in(provider, [:config, :ws_url]))
            }
          end)

        {:ok, summaries}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets detailed configuration for a specific provider.

  ## Example

      {:ok, config} = Livechain.Providers.get_provider("ethereum", "alchemy")
      IO.inspect(config.url)
  """
  @spec get_provider(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_provider(chain_name, provider_id) do
    case ProviderPool.get_status(chain_name) do
      {:ok, status} ->
        case Enum.find(status.providers, fn p -> p.id == provider_id end) do
          nil -> {:error, :not_found}
          provider -> {:ok, Map.get(provider, :config, %{})}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private functions

  defp normalize_provider_config(attrs) when is_map(attrs) do
    %{
      id: Map.get(attrs, :id) || Map.get(attrs, "id"),
      name: Map.get(attrs, :name) || Map.get(attrs, "name"),
      url: Map.get(attrs, :url) || Map.get(attrs, "url"),
      ws_url: Map.get(attrs, :ws_url) || Map.get(attrs, "ws_url"),
      type: Map.get(attrs, :type) || Map.get(attrs, "type") || "public",
      priority: Map.get(attrs, :priority) || Map.get(attrs, "priority") || 100,
      api_key_required:
        Map.get(attrs, :api_key_required) || Map.get(attrs, "api_key_required") || false,
      region: Map.get(attrs, :region) || Map.get(attrs, "region") || "global"
    }
  end

  defp maybe_validate(provider_config, true) do
    with :ok <- validate_required_fields(provider_config),
         :ok <- ConfigValidator.validate_provider_url(provider_config.url),
         :ok <- maybe_validate_ws_url(provider_config.ws_url) do
      :ok
    end
  end

  defp maybe_validate(_provider_config, false), do: :ok

  defp validate_required_fields(config) do
    required = [:id, :name, :url]
    missing = Enum.filter(required, fn field -> is_nil(Map.get(config, field)) end)

    if Enum.empty?(missing) do
      :ok
    else
      {:error, {:missing_required_fields, missing}}
    end
  end

  defp maybe_validate_ws_url(nil), do: :ok

  defp maybe_validate_ws_url(ws_url) when is_binary(ws_url) do
    ConfigValidator.validate_provider_url(ws_url)
  end

  defp check_not_duplicate(chain_name, provider_id) do
    case get_provider(chain_name, provider_id) do
      {:ok, _} -> {:error, {:already_exists, provider_id}}
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_persist_add(_chain_name, _provider_config, false), do: :ok

  defp maybe_persist_add(chain_name, provider_config, true) do
    case ChainConfigManager.add_provider_to_chain(chain_name, provider_config) do
      {:ok, _provider} ->
        :ok

      {:error, reason} = error ->
        Logger.error(
          "Failed to persist provider #{provider_config.id} to YAML: #{inspect(reason)}"
        )

        error
    end
  end

  defp maybe_persist_remove(_chain_name, _provider_id, false), do: :ok

  defp maybe_persist_remove(chain_name, provider_id, true) do
    case ChainConfigManager.remove_provider_from_chain(chain_name, provider_id) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.error("Failed to remove provider #{provider_id} from YAML: #{inspect(reason)}")
        error
    end
  end
end
