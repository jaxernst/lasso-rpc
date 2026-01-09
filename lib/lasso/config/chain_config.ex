defmodule Lasso.Config.ChainConfig do
  @moduledoc """
  Chain configuration data structures and validation.

  Defines the data structures used to represent profile chain configurations
  including providers, connection settings, failover behavior, and monitoring.
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

  defmodule Provider do
    @moduledoc "Configuration for an RPC provider."
    @derive Jason.Encoder
    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            priority: non_neg_integer(),
            type: String.t(),
            url: String.t(),
            ws_url: String.t() | nil,
            api_key_required: boolean(),
            region: String.t() | nil,
            adapter_config: %{atom() => any()} | nil,
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
      :__mock__
    ]
  end

  defmodule Connection do
    @moduledoc "Connection settings for RPC providers."
    @type t :: %__MODULE__{
            heartbeat_interval: non_neg_integer(),
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
    @moduledoc "Failover configuration for RPC provider selection."
    @type t :: %__MODULE__{
            max_backfill_blocks: non_neg_integer(),
            backfill_timeout: non_neg_integer(),
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
              new_heads_staleness_threshold_ms: 42_000,
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

    @doc "Check if this chain is an L2"
    @spec l2?(t()) :: boolean()
    def l2?(%__MODULE__{category: category}), do: category in [:l2]

    @doc "Check if this chain is a mainnet chain"
    @spec mainnet?(t()) :: boolean()
    def mainnet?(%__MODULE__{network: network}), do: network == :mainnet

    @doc "Check if this chain is a testnet"
    @spec testnet?(t()) :: boolean()
    def testnet?(%__MODULE__{network: network}), do: network in [:sepolia, :goerli, :holesky]
  end

  @doc """
  Gets a specific provider by ID.
  """
  @spec get_provider_by_id(t(), String.t()) :: {:ok, Provider.t()} | {:error, :provider_not_found}
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
  """
  @spec should_subscribe_new_heads?(t(), Provider.t()) :: boolean()
  def should_subscribe_new_heads?(chain_config, provider) do
    case provider.subscribe_new_heads do
      nil -> chain_config.monitoring.subscribe_new_heads
      value when is_boolean(value) -> value
    end
  end

  @doc "Substitutes ${VAR_NAME} patterns with environment variable values."
  @spec substitute_env_vars(nil) :: nil
  def substitute_env_vars(nil), do: nil

  @spec substitute_env_vars(String.t()) :: String.t()
  def substitute_env_vars(string) when is_binary(string) do
    Regex.replace(~r/\$\{([^}]+)\}/, string, fn _, var_name ->
      System.get_env(var_name) || "${#{var_name}}"
    end)
  end

  @spec substitute_env_vars(any()) :: any()
  def substitute_env_vars(value), do: value

  @doc "Returns true if string contains unresolved ${VAR_NAME} placeholders."
  @spec has_unresolved_placeholders?(String.t()) :: boolean()
  def has_unresolved_placeholders?(string) when is_binary(string) do
    string =~ ~r/\$\{[^}]+\}/
  end

  @spec has_unresolved_placeholders?(any()) :: false
  def has_unresolved_placeholders?(_), do: false

  @doc "Validates that all provider URLs have resolved environment variables."
  @spec validate_no_unresolved_placeholders(t()) ::
          :ok | {:error, {:unresolved_env_vars, [{String.t(), [{atom(), String.t()}]}]}}
  def validate_no_unresolved_placeholders(%__MODULE__{} = chain_config) do
    chain_config.providers
    |> Enum.flat_map(&collect_provider_issues/1)
    |> case do
      [] -> :ok
      unresolved -> {:error, {:unresolved_env_vars, unresolved}}
    end
  end

  defp collect_provider_issues(provider) do
    issues =
      [
        if(has_unresolved_placeholders?(provider.url), do: {:url, provider.url}),
        if(has_unresolved_placeholders?(provider.ws_url), do: {:ws_url, provider.ws_url})
      ]
      |> Enum.reject(&is_nil/1)

    case issues do
      [] -> []
      issues -> [{provider.id, issues}]
    end
  end

  @doc """
  Validates that a chain configuration has valid providers.
  """
  @spec validate_chain_config(t()) :: :ok | {:error, :no_providers | :invalid_provider | :invalid_connection}
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
