defmodule Livechain.Config.ChainConfig do
  @moduledoc """
  Configuration loader and validator for multi-provider blockchain configurations.

  Loads YAML configuration files defining multiple RPC providers per blockchain,
  with support for failover, load balancing, and message deduplication.
  """

  require Logger

  @type t :: %__MODULE__{
          chain_id: non_neg_integer(),
          name: String.t(),
          providers: [Provider.t()],
          connection: Connection.t(),
          failover: Failover.t()
        }

  defstruct [
    :chain_id,
    :name,
    :providers,
    :connection,
    :failover
  ]

  defmodule Config do
    @type t :: %__MODULE__{
            chains: %{String.t() => ChainConfig.t()}
          }

    defstruct [
      :chains
    ]
  end

  defmodule Provider do
    @derive Jason.Encoder
    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            priority: non_neg_integer(),
            # "paid" | "public" | "dedicated"
            type: String.t(),
            url: String.t(),
            ws_url: String.t() | nil,
            api_key_required: boolean(),
            region: String.t() | nil
          }

    defstruct [
      :id,
      :name,
      :priority,
      :type,
      :url,
      :ws_url,
      :api_key_required,
      :region
    ]
  end

  defmodule Connection do
    @type t :: %__MODULE__{
            # milliseconds
            heartbeat_interval: non_neg_integer(),
            # milliseconds
            reconnect_interval: non_neg_integer(),
            max_reconnect_attempts: non_neg_integer()
          }

    defstruct [
      :heartbeat_interval,
      :reconnect_interval,
      :max_reconnect_attempts
    ]
  end

  defmodule Failover do
    @type t :: %__MODULE__{
            # max blocks to backfill on failover
            max_backfill_blocks: non_neg_integer(),
            # max time to spend backfilling (ms)
            backfill_timeout: non_neg_integer(),
            # enable/disable backfill feature
            enabled: boolean()
          }

    defstruct max_backfill_blocks: 100,
              backfill_timeout: 30_000,
              enabled: true
  end

  @doc """
  Loads and parses the chain configuration from a YAML file.

  ## Examples

      iex> {:ok, config} = Livechain.Config.ChainConfig.load_config("config/chains.yml")
      iex> Map.keys(config.chains)
      ["ethereum", "base", "polygon", "arbitrum"]
  """
  def load_config(config_path \\ "config/chains.yml") do
    with {:ok, content} <- File.read(config_path),
         {:ok, yaml_data} <- YamlElixir.read_from_string(content),
         {:ok, config} <- parse_config(yaml_data) do
      Logger.info("Loaded chain configuration with #{map_size(config.chains)} chains")
      {:ok, config}
    else
      {:error, :enoent} ->
        Logger.error("Configuration file not found: #{config_path}")
        {:error, :config_file_not_found}

      {:error, reason} when is_binary(reason) ->
        Logger.error("Failed to parse YAML configuration: #{reason}")
        {:error, :invalid_yaml}

      {:error, reason} ->
        Logger.error("Configuration error: #{inspect(reason)}")
        {:error, :invalid_config}
    end
  end

  @doc """
  Gets configuration for a specific chain by name or chain_id.
  """
  def get_chain_config(config, chain_identifier) do
    chain_key =
      if is_binary(chain_identifier) do
        chain_identifier
      else
        # Find chain by chain_id
        Enum.find_value(config.chains, fn {key, chain_config} ->
          if chain_config.chain_id == chain_identifier, do: key
        end)
      end

    case Map.get(config.chains, chain_key) do
      nil -> {:error, :chain_not_found}
      chain_config -> {:ok, chain_config}
    end
  end

  @doc """
  Gets providers for a chain sorted by priority.
  """
  def get_providers_by_priority(chain_config) do
    chain_config.providers
    |> Enum.sort_by(& &1.priority)
  end

  @doc """
  Gets available providers (those with API keys if required).
  """
  def get_available_providers(chain_config) do
    chain_config.providers
    |> Enum.filter(&provider_available?/1)
    |> Enum.sort_by(& &1.priority)
  end

  @doc """
  Gets providers that support WebSocket connections.
  """
  def get_ws_providers(chain_config) do
    chain_config.providers
    |> Enum.filter(fn provider ->
      provider_available?(provider) and not is_nil(provider.ws_url)
    end)
    |> Enum.sort_by(& &1.priority)
  end

  @doc """
  Gets a specific provider by ID.
  """
  def get_provider_by_id(chain_config, provider_id) do
    case Enum.find(chain_config.providers, &(&1.id == provider_id)) do
      nil -> {:error, :provider_not_found}
      provider -> {:ok, provider}
    end
  end

  defp provider_available?(%Provider{api_key_required: false}), do: true

  defp provider_available?(%Provider{api_key_required: true, url: url}) do
    # Check if API key is available in the URL
    not String.contains?(url, "${") or System.get_env("INFURA_API_KEY") != nil or
      System.get_env("ALCHEMY_API_KEY") != nil
  end

  # Handle WSEndpoint structs (used in tests) - always available for testing
  defp provider_available?(%Livechain.RPC.WSEndpoint{}), do: true

  # Fallback for unknown provider types
  defp provider_available?(_), do: false

  defp parse_config(yaml_data) do
    with {:ok, chains} <- parse_chains(yaml_data["chains"]) do
      config = %Config{
        chains: chains
      }

      {:ok, config}
    end
  end

  defp parse_chains(chains_data) when is_map(chains_data) do
    chains =
      chains_data
      |> Enum.map(fn {chain_name, chain_data} ->
        {chain_name, parse_chain_config(chain_data)}
      end)
      |> Enum.into(%{})

    {:ok, chains}
  end

  defp parse_chains(_), do: {:error, :invalid_chains_format}

  defp parse_chain_config(chain_data) do
    %__MODULE__{
      chain_id: chain_data["chain_id"],
      name: chain_data["name"],
      providers: parse_providers(chain_data["providers"]),
      connection: parse_connection(chain_data["connection"]),
      failover: parse_failover(chain_data["failover"])
    }
  end

  defp parse_providers(providers_data) do
    Enum.map(providers_data, fn provider_data ->
      %Provider{
        id: provider_data["id"],
        name: provider_data["name"],
        priority: provider_data["priority"],
        type: provider_data["type"],
        url: substitute_env_vars(provider_data["url"]),
        ws_url: substitute_env_vars(provider_data["ws_url"]),
        api_key_required: provider_data["api_key_required"],
        region: provider_data["region"]
      }
    end)
  end

  defp parse_connection(connection_data) do
    %Connection{
      heartbeat_interval: connection_data["heartbeat_interval"],
      reconnect_interval: connection_data["reconnect_interval"],
      max_reconnect_attempts: connection_data["max_reconnect_attempts"]
    }
  end

  defp parse_failover(nil) do
    # Use default values if no failover config provided
    %__MODULE__.Failover{}
  end

  defp parse_failover(failover_data) do
    %__MODULE__.Failover{
      max_backfill_blocks: Map.get(failover_data, "max_backfill_blocks", 100),
      backfill_timeout: Map.get(failover_data, "backfill_timeout", 30_000),
      enabled: Map.get(failover_data, "enabled", true)
    }
  end

  @doc """
  Substitutes environment variables in configuration strings.

  Replaces ${VAR_NAME} with the value of the environment variable.
  """
  def substitute_env_vars(nil), do: nil

  def substitute_env_vars(string) when is_binary(string) do
    Regex.replace(~r/\$\{([^}]+)\}/, string, fn _, var_name ->
      System.get_env(var_name) || "${#{var_name}}"
    end)
  end

  def substitute_env_vars(value), do: value

  @doc """
  Validates that a chain configuration has valid providers.
  """
  def validate_chain_config(%__MODULE__{} = chain_config) do
    with :ok <- validate_providers(chain_config.providers),
         :ok <- validate_connection(chain_config.connection) do
      :ok
    end
  end

  defp validate_providers([]), do: {:error, :no_providers}

  defp validate_providers(providers) do
    if Enum.all?(providers, &valid_provider?/1) do
      :ok
    else
      {:error, :invalid_provider}
    end
  end

  defp valid_provider?(%Provider{id: id, name: name, url: url})
       when not is_nil(id) and not is_nil(name) and not is_nil(url) do
    true
  end

  defp valid_provider?(_), do: false

  defp validate_connection(%Connection{heartbeat_interval: hi, reconnect_interval: ri})
       when is_integer(hi) and hi > 0 and is_integer(ri) and ri > 0 do
    :ok
  end

  defp validate_connection(_), do: {:error, :invalid_connection}
end
