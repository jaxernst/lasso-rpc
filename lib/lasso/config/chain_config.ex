defmodule Lasso.Config.ChainConfig do
  @moduledoc """
  Chain configuration data structures and validation.

  Defines the data structures used to represent profile chain configurations
  including providers, websocket settings, failover behavior, and monitoring.
  """

  require Logger

  @type t :: %__MODULE__{
          chain_id: non_neg_integer() | nil,
          name: String.t(),
          providers: [__MODULE__.Provider.t()],
          selection: __MODULE__.Selection.t() | nil,
          monitoring: __MODULE__.Monitoring.t(),
          websocket: __MODULE__.Websocket.t(),
          topology: __MODULE__.Topology.t() | nil
        }

  defstruct [
    :chain_id,
    :name,
    :providers,
    :selection,
    :monitoring,
    :websocket,
    :topology
  ]

  defmodule Provider do
    @moduledoc "Configuration for an RPC provider."
    @derive Jason.Encoder
    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            priority: non_neg_integer(),
            url: String.t(),
            ws_url: String.t() | nil,
            adapter_config: %{atom() => any()} | nil,
            subscribe_new_heads: boolean() | nil,
            archival: boolean()
          }

    defstruct [
      :id,
      :name,
      :priority,
      :url,
      :ws_url,
      :adapter_config,
      :subscribe_new_heads,
      :__mock__,
      archival: true
    ]
  end

  defmodule WebsocketFailover do
    @moduledoc """
    Failover configuration for WebSocket subscriptions.

    Controls gap-filling behavior when a subscription fails over to another provider.
    """

    @type t :: %__MODULE__{
            max_backfill_blocks: non_neg_integer(),
            backfill_timeout_ms: non_neg_integer()
          }

    defstruct max_backfill_blocks: 100,
              backfill_timeout_ms: 30_000
  end

  defmodule Websocket do
    @moduledoc """
    WebSocket subscription configuration.

    Controls newHeads tracking for real-time block monitoring and
    failover behavior when subscriptions lose connection.
    """

    alias Lasso.Config.ChainConfig.WebsocketFailover

    @type t :: %__MODULE__{
            subscribe_new_heads: boolean(),
            new_heads_timeout_ms: non_neg_integer(),
            failover: WebsocketFailover.t()
          }

    defstruct subscribe_new_heads: true,
              new_heads_timeout_ms: 42_000,
              failover: %WebsocketFailover{}
  end

  defmodule Selection do
    @moduledoc """
    Provider selection configuration for lag-aware routing and archival detection.

    Controls how Lasso filters providers based on block height lag to ensure
    consistent blockchain state when routing requests, and determines when a
    block is considered "archival" (requiring historical data support).

    ## Archival Threshold

    The archival threshold determines how many blocks behind the current head
    a request must target before it's considered "archival" (requiring historical
    data support). Default is 128 blocks (~25 minutes on Ethereum), which represents
    a reasonable boundary between recent and historical data.

    For comparison:
    - Ethereum mainnet: ~25 min at 12s blocks
    - Base/Optimism: ~4 min at 2s blocks
    - Polygon: ~4 min at 2s blocks
    """

    @default_archival_threshold 128

    @type t :: %__MODULE__{
            max_lag_blocks: non_neg_integer() | nil,
            archival_threshold: non_neg_integer()
          }

    defstruct max_lag_blocks: nil,
              archival_threshold: @default_archival_threshold

    @doc "Returns the default archival threshold (blocks behind head to consider archival)."
    @spec default_archival_threshold() :: non_neg_integer()
    def default_archival_threshold, do: @default_archival_threshold
  end

  defmodule Monitoring do
    @moduledoc """
    Provider health monitoring and probing configuration.

    Controls the behavior of the integrated ProviderProbe system:
    - Probe frequency (how often to query eth_blockNumber)
    - Lag detection thresholds (when to warn/alert about providers falling behind)

    These settings are chain-specific because chains have different:
    - Block times (Ethereum: 12s, Base: 2s, Polygon: 2s)
    - Reorg depths (Polygon is notorious for deep reorgs)
    - Operational requirements

    Note: WebSocket-specific settings (newHeads subscriptions) are in the Websocket struct.
    """

    @type t :: %__MODULE__{
            probe_interval_ms: non_neg_integer(),
            lag_alert_threshold_blocks: non_neg_integer()
          }

    defstruct probe_interval_ms: 12_000,
              lag_alert_threshold_blocks: 3
  end

  defmodule Topology do
    @moduledoc """
    Chain topology metadata for dashboard visualization.

    Used by the network topology component to determine display size and color.
    """

    @type size :: :sm | :md | :lg | :xl

    @type t :: %__MODULE__{
            color: String.t(),
            size: size()
          }

    defstruct color: "#6B7280",
              size: :md
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

  Provider-level setting overrides chain-level default from Websocket.subscribe_new_heads.
  Returns true if the provider should subscribe to newHeads via WebSocket.
  """
  @spec should_subscribe_new_heads?(t(), Provider.t()) :: boolean()
  def should_subscribe_new_heads?(chain_config, provider) do
    case provider.subscribe_new_heads do
      nil -> chain_config.websocket.subscribe_new_heads
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
  @spec validate_chain_config(t()) :: :ok | {:error, :no_providers | :invalid_provider}
  def validate_chain_config(%__MODULE__{} = chain_config) do
    validate_providers(chain_config.providers)
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
end
