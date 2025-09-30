defmodule Livechain.Config.ConfigStore do
  @moduledoc """
  Centralized configuration store that caches chain and provider configurations
  in ETS tables for fast, hot-path access. Eliminates the need to load YAML
  files during request processing.

  This module provides:
  - One-time configuration loading at startup
  - Fast ETS-based lookups for chains and providers
  - Runtime configuration reload capability
  - Typed struct storage (ChainConfig, ProviderConfig)
  """

  use GenServer
  require Logger

  alias Livechain.Config.ChainConfig
  alias Livechain.Config.ChainConfig.Provider

  @config_table :livechain_config_store
  @chains_key :chains
  @chain_ids_key :chain_ids

  ## Public API

  @doc """
  Starts the ConfigStore GenServer and loads initial configuration.
  """
  def start_link(config_path) do
    GenServer.start_link(__MODULE__, config_path, name: __MODULE__)
  end

  @doc """
  Gets configuration for a specific chain.
  Returns cached config or {:error, :not_found}.
  """
  @spec get_chain(String.t()) :: {:ok, ChainConfig.t()} | {:error, :not_found}
  def get_chain(chain_name) do
    case :ets.lookup(@config_table, @chains_key) do
      [{@chains_key, chains}] ->
        case Map.get(chains, chain_name) do
          nil -> {:error, :not_found}
          chain_config -> {:ok, chain_config}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Lists all available chain names.
  """
  @spec list_chains() :: [String.t()]
  def list_chains do
    case :ets.lookup(@config_table, @chains_key) do
      [{@chains_key, chains}] -> Map.keys(chains)
      [] -> []
    end
  end

  @doc """
  Gets provider configuration for a specific provider within a chain.
  """
  @spec get_provider(String.t(), String.t()) :: {:ok, ProviderConfig.t()} | {:error, :not_found}
  def get_provider(chain_name, provider_id) do
    with {:ok, chain_config} <- get_chain(chain_name) do
      case Enum.find(chain_config.providers, &(&1.id == provider_id)) do
        nil -> {:error, :not_found}
        provider -> {:ok, provider}
      end
    end
  end

  @doc """
  Gets all providers for a specific chain.
  """
  @spec get_providers(String.t()) :: {:ok, [ProviderConfig.t()]} | {:error, :not_found}
  def get_providers(chain_name) do
    case get_chain(chain_name) do
      {:ok, chain_config} -> {:ok, chain_config.providers}
      error -> error
    end
  end

  @doc """
  Gets all chains as a map.
  """
  @spec get_all_chains() :: %{String.t() => ChainConfig.t()}
  def get_all_chains do
    case :ets.lookup(@config_table, @chains_key) do
      [{@chains_key, chains}] -> chains
      [] -> %{}
    end
  end

  @doc """
  Gets a chain configuration by chain name or chain ID.

  Accepts either a chain name (string) or a chain ID (integer or numeric string).
  Returns the normalized chain name along with the chain configuration.
  """
  @spec get_chain_by_name_or_id(String.t() | integer()) ::
          {:ok, {String.t(), ChainConfig.t()}} | {:error, :not_found | :invalid_format}
  def get_chain_by_name_or_id(chain_id) when is_integer(chain_id) do
    find_chain_by_id(chain_id)
  end

  def get_chain_by_name_or_id(chain_name) when is_binary(chain_name) do
    case :ets.lookup(@config_table, @chains_key) do
      [{@chains_key, chains}] ->
        case Map.get(chains, chain_name) do
          nil ->
            # Not found by name, try parsing as numeric chain ID
            case Integer.parse(chain_name) do
              {chain_id, ""} -> find_chain_by_id(chain_id)
              _ -> {:error, :invalid_format}
            end

          chain_config ->
            {:ok, {chain_name, chain_config}}
        end

      [] ->
        {:error, :not_found}
    end
  end

  # Private helper to find chain by numeric ID using O(1) index lookup
  defp find_chain_by_id(chain_id) do
    case :ets.lookup(@config_table, @chain_ids_key) do
      [{@chain_ids_key, id_index}] ->
        case Map.get(id_index, chain_id) do
          nil ->
            {:error, :not_found}

          chain_name ->
            # Get the actual config using the chain name
            case get_chain(chain_name) do
              {:ok, chain_config} -> {:ok, {chain_name, chain_config}}
              error -> error
            end
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Registers a provider configuration in-memory (runtime only, not persisted to YAML).

  This allows dynamically added providers to be found by TransportRegistry and other
  components that query ConfigStore. The provider is added to the chain's provider list.

  ## Example

      ConfigStore.register_provider_runtime("ethereum", %{
        id: "dynamic_provider",
        name: "Dynamic Provider",
        url: "https://rpc.example.com",
        type: "test",
        priority: 100
      })

  ## Returns

  `:ok` on success, `{:error, reason}` if chain not found or provider ID already exists.
  """
  @spec register_provider_runtime(String.t(), map()) :: :ok | {:error, term()}
  def register_provider_runtime(chain_name, provider_attrs) do
    GenServer.call(__MODULE__, {:register_provider_runtime, chain_name, provider_attrs})
  end

  @doc """
  Unregisters a provider from in-memory configuration (runtime only).

  Removes the provider from the chain's provider list in ConfigStore.
  """
  @spec unregister_provider_runtime(String.t(), String.t()) :: :ok | {:error, term()}
  def unregister_provider_runtime(chain_name, provider_id) do
    GenServer.call(__MODULE__, {:unregister_provider_runtime, chain_name, provider_id})
  end

  @doc """
  Reloads configuration from the configured path.
  This atomically swaps the stored configuration.
  """
  @spec reload() :: :ok | {:error, term()}
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  @doc """
  Reloads configuration from a specific path.
  """
  @spec reload(String.t()) :: :ok | {:error, term()}
  def reload(config_path) do
    GenServer.call(__MODULE__, {:reload, config_path})
  end

  @doc """
  Gets the current configuration status.
  """
  @spec status() :: %{
          chains_loaded: non_neg_integer(),
          total_providers: non_neg_integer(),
          last_loaded: DateTime.t() | nil
        }
  def status do
    GenServer.call(__MODULE__, :status)
  end

  ## GenServer Implementation

  @impl true
  def init(config_path) do
    # Create ETS table for configuration storage
    :ets.new(@config_table, [:set, :protected, :named_table, read_concurrency: true])

    # Load initial configuration
    case load_and_store_config(config_path) do
      :ok ->
        state = %{
          config_path: config_path,
          last_loaded: DateTime.utc_now()
        }

        {:ok, state}

      {:error, reason} ->
        Logger.error("Failed to initialize ConfigStore: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:register_provider_runtime, chain_name, provider_attrs}, _from, state) do
    case get_chain(chain_name) do
      {:ok, chain_config} ->
        provider_config = normalize_provider_config(provider_attrs)
        provider_id = Map.get(provider_config, :id)

        # Check if provider already exists
        if Enum.any?(chain_config.providers, &(&1.id == provider_id)) do
          {:reply, {:error, {:already_exists, provider_id}}, state}
        else
          # Add provider to chain config
          updated_providers = chain_config.providers ++ [provider_config]
          updated_chain = %{chain_config | providers: updated_providers}

          # Update ETS
          [{@chains_key, chains}] = :ets.lookup(@config_table, @chains_key)
          updated_chains = Map.put(chains, chain_name, updated_chain)
          :ets.insert(@config_table, {@chains_key, updated_chains})

          Logger.debug("Registered provider #{provider_id} for #{chain_name} in ConfigStore (runtime)")
          {:reply, :ok, state}
        end

      {:error, :not_found} ->
        {:reply, {:error, :chain_not_found}, state}
    end
  end

  @impl true
  def handle_call({:unregister_provider_runtime, chain_name, provider_id}, _from, state) do
    case get_chain(chain_name) do
      {:ok, chain_config} ->
        updated_providers = Enum.reject(chain_config.providers, &(&1.id == provider_id))

        if length(updated_providers) == length(chain_config.providers) do
          {:reply, {:error, :provider_not_found}, state}
        else
          updated_chain = %{chain_config | providers: updated_providers}

          # Update ETS
          [{@chains_key, chains}] = :ets.lookup(@config_table, @chains_key)
          updated_chains = Map.put(chains, chain_name, updated_chain)
          :ets.insert(@config_table, {@chains_key, updated_chains})

          Logger.debug("Unregistered provider #{provider_id} from #{chain_name} in ConfigStore (runtime)")
          {:reply, :ok, state}
        end

      {:error, :not_found} ->
        {:reply, {:error, :chain_not_found}, state}
    end
  end

  @impl true
  def handle_call(:reload, _from, state) do
    case load_and_store_config(state.config_path) do
      :ok ->
        new_state = %{state | last_loaded: DateTime.utc_now()}
        Logger.info("Configuration reloaded successfully")
        {:reply, :ok, new_state}

      {:error, reason} = error ->
        Logger.error("Failed to reload configuration: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:reload, config_path}, _from, state) do
    case load_and_store_config(config_path) do
      :ok ->
        new_state = %{
          state
          | config_path: config_path,
            last_loaded: DateTime.utc_now()
        }

        Logger.info("Configuration reloaded from #{config_path}")
        {:reply, :ok, new_state}

      {:error, reason} = error ->
        Logger.error("Failed to reload configuration from #{config_path}: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    chains = get_all_chains()

    total_providers =
      chains
      |> Map.values()
      |> Enum.map(&length(&1.providers))
      |> Enum.sum()

    status = %{
      chains_loaded: map_size(chains),
      total_providers: total_providers,
      last_loaded: state.last_loaded
    }

    {:reply, status, state}
  end

  ## Private Functions

  defp load_and_store_config(config_path) do
    case ChainConfig.load_config(config_path) do
      {:ok, config} ->
        # Build chain_id -> chain_name index for O(1) ID lookups
        chain_id_index =
          Enum.reduce(config.chains, %{}, fn {chain_name, chain_config}, acc ->
            case Map.get(chain_config, :chain_id) do
              chain_id when is_integer(chain_id) ->
                Map.put(acc, chain_id, chain_name)

              _ ->
                acc
            end
          end)

        # Store both chains and ID index atomically
        :ets.insert(@config_table, [
          {@chains_key, config.chains},
          {@chain_ids_key, chain_id_index}
        ])

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_provider_config(attrs) when is_map(attrs) do
    # Convert to Provider struct
    %Provider{
      id: Map.get(attrs, :id) || Map.get(attrs, "id"),
      name: Map.get(attrs, :name) || Map.get(attrs, "name"),
      url: Map.get(attrs, :url) || Map.get(attrs, "url"),
      ws_url: Map.get(attrs, :ws_url) || Map.get(attrs, "ws_url"),
      type: Map.get(attrs, :type) || Map.get(attrs, "type") || "public",
      priority: Map.get(attrs, :priority) || Map.get(attrs, "priority") || 100,
      api_key_required: Map.get(attrs, :api_key_required) || Map.get(attrs, "api_key_required") || false,
      region: Map.get(attrs, :region) || Map.get(attrs, "region") || "global"
    }
  end
end
