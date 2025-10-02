defmodule Lasso.Config.RuntimeConfig do
  @moduledoc """
  Runtime configuration provider with dependency injection support.

  Provides a layer between modules and direct ConfigStore access,
  enabling better testability and configuration management.
  """

  alias Lasso.Config.ConfigStore

  @type chain_config :: %{
          providers: [map()],
          failover: map(),
          dedupe: map()
        }

  @type provider_config :: %{
          id: String.t(),
          name: String.t(),
          url: String.t() | nil,
          ws_url: String.t() | nil,
          priority: integer(),
          type: String.t()
        }

  @doc """
  Gets chain configuration with sensible defaults.
  """
  @spec get_chain_config(String.t()) :: {:ok, chain_config()} | {:error, term()}
  def get_chain_config(chain_name) do
    case ConfigStore.get_chain(chain_name) do
      {:ok, config} ->
        {:ok, normalize_chain_config(config)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets provider configuration with validation.
  """
  @spec get_provider_config(String.t(), String.t()) ::
          {:ok, provider_config()} | {:error, term()}
  def get_provider_config(chain_name, provider_id) do
    case ConfigStore.get_provider(chain_name, provider_id) do
      {:ok, config} ->
        {:ok, normalize_provider_config(config)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets all providers for a chain in priority order.
  """
  @spec get_chain_providers(String.t()) :: {:ok, [provider_config()]} | {:error, term()}
  def get_chain_providers(chain_name) do
    case ConfigStore.get_providers(chain_name) do
      {:ok, providers} ->
        normalized =
          providers
          |> Enum.map(&normalize_provider_config/1)
          |> Enum.sort_by(& &1.priority)

        {:ok, normalized}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets metrics backend configuration.
  """
  @spec get_metrics_backend() :: module()
  def get_metrics_backend do
    Application.get_env(:lasso, :metrics_backend, Lasso.RPC.Metrics.BenchmarkStore)
  end

  @doc """
  Gets provider selection strategy configuration.
  """
  @spec get_default_strategy() :: atom()
  def get_default_strategy do
    Application.get_env(:lasso, :provider_selection_strategy, :cheapest)
  end

  @doc """
  Gets circuit breaker configuration with defaults.
  """
  @spec get_circuit_breaker_config() :: map()
  def get_circuit_breaker_config do
    default = %{
      failure_threshold: 5,
      recovery_timeout: 60_000,
      success_threshold: 2
    }

    user_config = Application.get_env(:lasso, :circuit_breaker, %{})
    Map.merge(default, user_config)
  end

  @doc """
  Gets health policy configuration with defaults.
  """
  @spec get_health_policy_config() :: map()
  def get_health_policy_config do
    %{
      failure_threshold: 3,
      base_cooldown_ms: 1_000,
      max_cooldown_ms: 300_000,
      ema_alpha: 0.1
    }
  end

  @doc """
  Creates a scoped configuration for a specific module/process.
  """
  @spec create_scoped_config(String.t(), keyword()) :: map()
  def create_scoped_config(chain_name, opts \\ []) do
    with {:ok, chain_config} <- get_chain_config(chain_name),
         {:ok, providers} <- get_chain_providers(chain_name) do
      %{
        chain: chain_name,
        chain_config: chain_config,
        providers: providers,
        metrics_backend: get_metrics_backend(),
        default_strategy: get_default_strategy(),
        circuit_breaker: get_circuit_breaker_config(),
        health_policy: get_health_policy_config(),
        custom: Map.new(opts)
      }
    else
      {:error, reason} ->
        %{error: reason}
    end
  end

  # Private functions

  defp normalize_chain_config(config) do
    %{
      providers: Map.get(config, :providers, []),
      failover:
        Map.get(config, :failover, %{
          enabled: true,
          max_backfill_blocks: 32,
          backfill_timeout: 30_000
        }),
      dedupe:
        Map.get(config, :dedupe, %{
          max_items: 256,
          max_age_ms: 30_000
        })
    }
  end

  defp normalize_provider_config(config) do
    %{
      id: Map.get(config, :id) || Map.get(config, "id"),
      name: Map.get(config, :name) || Map.get(config, "name") || "Unknown Provider",
      url: Map.get(config, :url) || Map.get(config, "url"),
      ws_url: Map.get(config, :ws_url) || Map.get(config, "ws_url"),
      priority: Map.get(config, :priority) || Map.get(config, "priority") || 0,
      type: Map.get(config, :type) || Map.get(config, "type") || "unknown"
    }
  end
end
