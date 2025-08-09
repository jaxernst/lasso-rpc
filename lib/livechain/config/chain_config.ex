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
    block_time: non_neg_integer(),
    providers: [Provider.t()],
    connection: Connection.t(),
    aggregation: Aggregation.t(),
    failover: Failover.t()
  }

  defstruct [
    :chain_id,
    :name,
    :block_time,
    :providers,
    :connection,
    :aggregation,
    :failover
  ]

  defmodule Config do
    @type t :: %__MODULE__{
      chains: %{String.t() => ChainConfig.t()},
      global: Global.t()
    }

    defstruct [
      :chains,
      :global
    ]
  end

  defmodule Provider do
    @type t :: %__MODULE__{
      id: String.t(),
      name: String.t(),
      priority: non_neg_integer(),
      type: String.t(), # "paid" | "public" | "dedicated"
      url: String.t(),
      ws_url: String.t(),
      api_key_required: boolean(),
      rate_limit: non_neg_integer(),
      latency_target: non_neg_integer(),
      reliability: float()
    }

    defstruct [
      :id,
      :name,
      :priority,
      :type,
      :url,
      :ws_url,
      :api_key_required,
      :rate_limit,
      :latency_target,
      :reliability
    ]
  end

  defmodule Connection do
    @type t :: %__MODULE__{
      heartbeat_interval: non_neg_integer(), # milliseconds
      reconnect_interval: non_neg_integer(),  # milliseconds
      max_reconnect_attempts: non_neg_integer()
    }

    defstruct [
      :heartbeat_interval,
      :reconnect_interval,
      :max_reconnect_attempts
    ]
  end

  defmodule Aggregation do
    @type t :: %__MODULE__{
      deduplication_window: non_neg_integer(), # milliseconds
      min_confirmations: non_neg_integer(),     # min providers that must confirm
      max_providers: non_neg_integer()          # max concurrent providers to use
    }

    defstruct [
      :deduplication_window,
      :min_confirmations,
      :max_providers
    ]
  end

  defmodule Failover do
    @type t :: %__MODULE__{
      max_backfill_blocks: non_neg_integer(),    # max blocks to backfill on failover  
      backfill_timeout: non_neg_integer(),       # max time to spend backfilling (ms)
      enabled: boolean()                         # enable/disable backfill feature
    }

    defstruct [
      max_backfill_blocks: 100,
      backfill_timeout: 30_000,
      enabled: true
    ]
  end

  defmodule Global do
    defstruct [
      :health_check,
      :provider_management,
      :deduplication
    ]

    defmodule HealthCheck do
      defstruct [
        :interval,
        :timeout,
        :failure_threshold,
        :recovery_threshold
      ]
    end

    defmodule ProviderManagement do
      defstruct [
        :auto_failover,
        :load_balancing,
        :provider_rotation
      ]
    end

    defmodule Deduplication do
      defstruct [
        :enabled,
        :algorithm,
        :cache_size,
        :cache_ttl
      ]
    end
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

  defp parse_config(yaml_data) do
    with {:ok, chains} <- parse_chains(yaml_data["chains"]),
         {:ok, global} <- parse_global(yaml_data["global"]) do
      config = %Config{
        chains: chains,
        global: global
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
      block_time: chain_data["block_time"],
      providers: parse_providers(chain_data["providers"]),
      connection: parse_connection(chain_data["connection"]),
      aggregation: parse_aggregation(chain_data["aggregation"]),
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
        rate_limit: provider_data["rate_limit"],
        latency_target: provider_data["latency_target"],
        reliability: provider_data["reliability"]
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

  defp parse_aggregation(aggregation_data) do
    %Aggregation{
      deduplication_window: aggregation_data["deduplication_window"],
      min_confirmations: aggregation_data["min_confirmations"],
      max_providers: aggregation_data["max_providers"]
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

  defp parse_global(global_data) do
    global = %Global{
      health_check: parse_health_check(global_data["health_check"]),
      provider_management: parse_provider_management(global_data["provider_management"]),
      deduplication: parse_deduplication(global_data["deduplication"])
    }

    {:ok, global}
  end

  defp parse_health_check(health_check_data) do
    %Global.HealthCheck{
      interval: health_check_data["interval"],
      timeout: health_check_data["timeout"],
      failure_threshold: health_check_data["failure_threshold"],
      recovery_threshold: health_check_data["recovery_threshold"]
    }
  end

  defp parse_provider_management(pm_data) do
    %Global.ProviderManagement{
      auto_failover: pm_data["auto_failover"],
      load_balancing: pm_data["load_balancing"],
      provider_rotation: pm_data["provider_rotation"]
    }
  end

  defp parse_deduplication(dedup_data) do
    %Global.Deduplication{
      enabled: dedup_data["enabled"],
      algorithm: dedup_data["algorithm"],
      cache_size: dedup_data["cache_size"],
      cache_ttl: dedup_data["cache_ttl"]
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
         :ok <- validate_connection(chain_config.connection),
         :ok <- validate_aggregation(chain_config.aggregation) do
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

  defp valid_provider?(%Provider{id: id, name: name, url: url, ws_url: ws_url})
       when not is_nil(id) and not is_nil(name) and not is_nil(url) and not is_nil(ws_url) do
    true
  end

  defp valid_provider?(_), do: false

  defp validate_connection(%Connection{heartbeat_interval: hi, reconnect_interval: ri})
       when is_integer(hi) and hi > 0 and is_integer(ri) and ri > 0 do
    :ok
  end

  defp validate_connection(_), do: {:error, :invalid_connection}

  defp validate_aggregation(%Aggregation{deduplication_window: dw, min_confirmations: mc})
       when is_integer(dw) and dw > 0 and is_integer(mc) and mc > 0 do
    :ok
  end

  defp validate_aggregation(_), do: {:error, :invalid_aggregation}
end
