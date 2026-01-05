defmodule Lasso.Config.ChainConfig do
  @moduledoc """
  Configuration loader and validator for multi-provider blockchain configurations.

  Loads YAML configuration files defining multiple RPC providers per blockchain,
  with support for failover, load balancing, and message deduplication.
  """

  require Logger

  @type t :: %__MODULE__{
          chain_id: non_neg_integer() | nil,
          name: String.t(),
          providers: [__MODULE__.Provider.t()],
          connection: __MODULE__.Connection.t(),
          failover: __MODULE__.Failover.t(),
          selection: __MODULE__.Selection.t() | nil,
          monitoring: __MODULE__.Monitoring.t(),
          topology: __MODULE__.Topology.t() | nil
        }

  defstruct [
    :chain_id,
    :name,
    :providers,
    :connection,
    :failover,
    :selection,
    :monitoring,
    :topology
  ]

  defmodule Config do
    @type t :: %__MODULE__{
            chains: %{String.t() => Lasso.Config.ChainConfig.t()}
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
            region: String.t() | nil,
            # Per-provider adapter configuration overrides
            # Maps to adapter-specific config keys (e.g., eth_get_logs_block_range: 10)
            adapter_config: %{atom() => any()} | nil,
            # Per-provider override for newHeads subscription behavior
            # nil = use chain-level default from Monitoring.subscribe_new_heads
            # true/false = explicit override for this provider
            subscribe_new_heads: boolean() | nil
          }

    defstruct [
      :id,
      :name,
      :priority,
      :type,
      :url,
      :ws_url,
      :api_key_required,
      :region,
      :adapter_config,
      :subscribe_new_heads,
      # For test mock providers
      :__mock__
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

  defmodule Selection do
    @moduledoc """
    Provider selection configuration for lag-aware routing.

    Controls how Lasso filters providers based on block height lag to ensure
    consistent blockchain state when routing requests.
    """

    @type t :: %__MODULE__{
            # Maximum acceptable lag in blocks (providers more than N blocks behind are excluded)
            # nil means no lag filtering
            max_lag_blocks: non_neg_integer() | nil
          }

    defstruct max_lag_blocks: nil
  end

  defmodule Monitoring do
    @moduledoc """
    Provider health monitoring and probing configuration.

    Controls the behavior of the integrated ProviderProbe system:
    - Probe frequency (how often to query eth_blockNumber)
    - Lag detection thresholds (when to warn about providers falling behind)
    - Monotonicity violation thresholds (detect unstable provider backends)
    - Subscription staleness detection threshold
    - NewHeads subscription behavior

    These settings are chain-specific because chains have different:
    - Block times (Ethereum: 12s, Base: 2s, Polygon: 2s)
    - Reorg depths (Polygon is notorious for deep reorgs)
    - Operational requirements
    """

    @type t :: %__MODULE__{
            probe_interval_ms: non_neg_integer(),
            lag_threshold_blocks: non_neg_integer(),
            new_heads_staleness_threshold_ms: non_neg_integer(),
            subscribe_new_heads: boolean()
          }

    defstruct probe_interval_ms: 12_000,
              lag_threshold_blocks: 3,
              # How long without events before a newHeads subscription is considered stale
              # Should account for: block time variance, missed slots, network delays
              # Recommended: ~3-5x expected block time + margin
              # Ethereum (12s blocks): 42000-60000ms, Base (2s blocks): 12000-16000ms
              new_heads_staleness_threshold_ms: 42_000,
              # Whether to subscribe to newHeads via WebSocket for block height tracking
              # Set to false to use HTTP polling only (avoids expensive WS subscriptions)
              # Can be overridden per-provider via Provider.subscribe_new_heads
              subscribe_new_heads: true
  end

  defmodule Topology do
    @moduledoc """
    Chain topology metadata for dashboard visualization.

    Used by the network topology component to:
    - Categorize chains (L1, L2 optimistic, L2 ZK, sidechain)
    - Establish parent-child relationships for connection lines
    - Determine display size and color
    - Group by network (mainnet vs testnets)
    """

    @type category :: :l1 | :l2 | :sidechain | :other
    @type network :: :mainnet | :sepolia | :goerli | :holesky
    @type size :: :sm | :md | :lg | :xl

    @type t :: %__MODULE__{
            category: category(),
            parent: String.t() | nil,
            network: network(),
            color: String.t(),
            size: size()
          }

    defstruct category: :other,
              parent: nil,
              network: :mainnet,
              color: "#6B7280",
              size: :md

    @doc "Check if this chain is an L2 "
    def l2?(%__MODULE__{category: category}), do: category in [:l2]

    @doc "Check if this chain is a mainnet chain"
    def mainnet?(%__MODULE__{network: network}), do: network == :mainnet

    @doc "Check if this chain is a testnet"
    def testnet?(%__MODULE__{network: network}), do: network in [:sepolia, :goerli, :holesky]
  end

  @doc """
  Loads and parses the chain configuration from a YAML file.

  ## Examples

      iex> {:ok, config} = Lasso.Config.ChainConfig.load_config("config/chains.yml")
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

  @doc """
  Determines if newHeads subscription should be enabled for a provider.

  Provider-level setting overrides chain-level default from Monitoring.subscribe_new_heads.
  Returns true if the provider should subscribe to newHeads via WebSocket.

  ## Examples

      # Provider uses chain default (true)
      iex> should_subscribe_new_heads?(chain_config, %Provider{subscribe_new_heads: nil})
      true

      # Provider explicitly disabled
      iex> should_subscribe_new_heads?(chain_config, %Provider{subscribe_new_heads: false})
      false
  """
  @spec should_subscribe_new_heads?(t(), Provider.t()) :: boolean()
  def should_subscribe_new_heads?(chain_config, provider) do
    case provider.subscribe_new_heads do
      nil -> chain_config.monitoring.subscribe_new_heads
      value when is_boolean(value) -> value
    end
  end

  defp provider_available?(%Provider{api_key_required: false}), do: true

  defp provider_available?(%Provider{api_key_required: true, url: url}) do
    # Check if API key is available in the URL
    not String.contains?(url, "${") or System.get_env("INFURA_API_KEY") != nil or
      System.get_env("ALCHEMY_API_KEY") != nil
  end

  # Handle Endpoint structs (used in tests) - always available for testing
  defp provider_available?(%Lasso.RPC.Transport.WebSocket.Endpoint{}), do: true

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
      failover: parse_failover(chain_data["failover"]),
      selection: parse_selection(chain_data["selection"]),
      monitoring: parse_monitoring(chain_data["monitoring"]),
      topology: parse_topology(chain_data["topology"])
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
        region: provider_data["region"],
        adapter_config: parse_adapter_config(provider_data["adapter_config"]),
        subscribe_new_heads: provider_data["subscribe_new_heads"]
      }
    end)
  end

  # Parse adapter_config from YAML, converting string keys to atoms and validating types
  defp parse_adapter_config(nil), do: nil

  defp parse_adapter_config(config_map) when is_map(config_map) do
    config_map
    |> Enum.map(fn {key, value} ->
      atom_key =
        if is_binary(key) do
          String.to_atom(key)
        else
          key
        end

      validated_value = validate_adapter_config_value(atom_key, value)
      {atom_key, validated_value}
    end)
    |> Enum.into(%{})
  end

  defp parse_adapter_config(_), do: nil

  # Validate known adapter config keys and their types
  # Known integer configuration keys that must be positive integers
  @integer_config_keys [
    :eth_get_logs_block_range,
    :max_block_range,
    :max_addresses_http,
    :max_addresses_ws
  ]

  defp validate_adapter_config_value(key, value) when key in @integer_config_keys do
    case value do
      v when is_integer(v) and v > 0 ->
        v

      v when is_binary(v) ->
        case Integer.parse(v) do
          {num, ""} when num > 0 ->
            num

          _ ->
            raise ArgumentError,
                  "Invalid adapter_config: #{key} must be a positive integer, got string: #{inspect(v)}"
        end

      _ ->
        raise ArgumentError,
              "Invalid adapter_config: #{key} must be a positive integer, got: #{inspect(value)}"
    end
  end

  # Unknown keys pass through without validation (future extensibility)
  defp validate_adapter_config_value(_key, value), do: value

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

  defp parse_selection(nil), do: nil

  defp parse_selection(selection_data) when is_map(selection_data) do
    %__MODULE__.Selection{
      max_lag_blocks: Map.get(selection_data, "max_lag_blocks")
    }
  end

  defp parse_monitoring(nil) do
    # Use default values if no monitoring config provided
    %__MODULE__.Monitoring{}
  end

  defp parse_monitoring(monitoring_data) when is_map(monitoring_data) do
    %__MODULE__.Monitoring{
      probe_interval_ms: Map.get(monitoring_data, "probe_interval_ms", 12_000),
      lag_threshold_blocks: Map.get(monitoring_data, "lag_threshold_blocks", 3),
      new_heads_staleness_threshold_ms:
        Map.get(monitoring_data, "new_heads_staleness_threshold_ms", 42_000),
      subscribe_new_heads: Map.get(monitoring_data, "subscribe_new_heads", true)
    }
  end

  defp parse_topology(nil) do
    # Use default values if no topology config provided
    %__MODULE__.Topology{}
  end

  defp parse_topology(topology_data) when is_map(topology_data) do
    %__MODULE__.Topology{
      category: parse_topology_category(Map.get(topology_data, "category")),
      parent: Map.get(topology_data, "parent"),
      network: parse_topology_network(Map.get(topology_data, "network")),
      color: Map.get(topology_data, "color", "#6B7280"),
      size: parse_topology_size(Map.get(topology_data, "size"))
    }
  end

  defp parse_topology_category("l1"), do: :l1
  defp parse_topology_category("l2"), do: :l2
  defp parse_topology_category("sidechain"), do: :sidechain
  defp parse_topology_category(_), do: :other

  defp parse_topology_network("mainnet"), do: :mainnet
  defp parse_topology_network("sepolia"), do: :sepolia
  defp parse_topology_network("goerli"), do: :goerli
  defp parse_topology_network("holesky"), do: :holesky
  defp parse_topology_network(_), do: :mainnet

  defp parse_topology_size("sm"), do: :sm
  defp parse_topology_size("md"), do: :md
  defp parse_topology_size("lg"), do: :lg
  defp parse_topology_size("xl"), do: :xl
  defp parse_topology_size(_), do: :md

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
    with :ok <- validate_providers(chain_config.providers) do
      validate_connection(chain_config.connection)
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
