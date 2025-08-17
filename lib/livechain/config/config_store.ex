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
  
  alias Livechain.Config.{ChainConfig, ProviderConfig}
  
  @config_table :livechain_config_store
  @chains_key :chains
  
  ## Public API
  
  @doc """
  Starts the ConfigStore GenServer and loads initial configuration.
  """
  def start_link(opts \\ []) do
    config_path = Keyword.get(opts, :config_path, "config/chains.yml")
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
        Logger.info("ConfigStore initialized with configuration from #{config_path}")
        {:ok, state}
        
      {:error, reason} ->
        Logger.error("Failed to initialize ConfigStore: #{inspect(reason)}")
        {:stop, reason}
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
          state | 
          config_path: config_path,
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
      |> Enum.map(& length(&1.providers))
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
        # Store chains configuration atomically
        :ets.insert(@config_table, {@chains_key, config.chains})
        :ok
        
      {:error, reason} ->
        {:error, reason}
    end
  end
end