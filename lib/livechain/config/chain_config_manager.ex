defmodule Livechain.Config.ChainConfigManager do
  @moduledoc """
  Context module for managing chain configurations dynamically.

  Provides CRUD operations for chain configurations while maintaining
  compatibility with  YAML + ETS architecture. Supports
  hot-reloading and real-time updates via PubSub.
  """

  require Logger
  alias Livechain.Config.{ChainConfig, ConfigStore}
  alias Phoenix.PubSub

  @config_file "config/chains.yml"
  @backup_dir "priv/config_backups"
  @pubsub Livechain.PubSub

  @doc """
  Lists all available chains with their configurations.
  """
  @spec list_chains() :: {:ok, %{String.t() => ChainConfig.t()}} | {:error, term()}
  def list_chains do
    case ConfigStore.get_all_chains() do
      chains when is_map(chains) -> {:ok, chains}
      _ -> {:error, :no_chains_loaded}
    end
  end

  @doc """
  Gets a specific chain configuration by name.
  """
  @spec get_chain(String.t()) :: {:ok, ChainConfig.t()} | {:error, :not_found}
  def get_chain(chain_name) do
    ConfigStore.get_chain(chain_name)
  end

  @doc """
  Creates a new chain configuration.
  """
  @spec create_chain(String.t(), map()) :: {:ok, ChainConfig.t()} | {:error, term()}
  def create_chain(chain_name, chain_attrs) do
    with {:ok, current_config} <- load_current_config(),
         :ok <- validate_chain_name_unique(current_config, chain_name),
         {:ok, chain_config} <- build_chain_config(chain_attrs),
         {:ok, new_config} <- add_chain_to_config(current_config, chain_name, chain_config),
         :ok <- backup_current_config(),
         :ok <- save_config_to_file(new_config),
         :ok <- reload_config_store() do
      Logger.info("Created new chain configuration: #{chain_name}")
      broadcast_config_change(:chain_created, chain_name, chain_config)
      {:ok, chain_config}
    else
      {:error, reason} = error ->
        Logger.error("Failed to create chain #{chain_name}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Updates an existing chain configuration.
  """
  @spec update_chain(String.t(), map()) :: {:ok, ChainConfig.t()} | {:error, term()}
  def update_chain(chain_name, chain_attrs) do
    with {:ok, current_config} <- load_current_config(),
         {:ok, _existing_chain} <- get_existing_chain(current_config, chain_name),
         {:ok, updated_chain_config} <- build_chain_config(chain_attrs),
         {:ok, new_config} <-
           update_chain_in_config(current_config, chain_name, updated_chain_config),
         :ok <- backup_current_config(),
         :ok <- save_config_to_file(new_config),
         :ok <- reload_config_store() do
      Logger.info("Updated chain configuration: #{chain_name}")
      broadcast_config_change(:chain_updated, chain_name, updated_chain_config)
      {:ok, updated_chain_config}
    else
      {:error, reason} = error ->
        Logger.error("Failed to update chain #{chain_name}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Deletes a chain configuration.
  """
  @spec delete_chain(String.t()) :: :ok | {:error, term()}
  def delete_chain(chain_name) do
    with {:ok, current_config} <- load_current_config(),
         {:ok, existing_chain} <- get_existing_chain(current_config, chain_name),
         {:ok, new_config} <- remove_chain_from_config(current_config, chain_name),
         :ok <- backup_current_config(),
         :ok <- save_config_to_file(new_config),
         :ok <- reload_config_store() do
      Logger.info("Deleted chain configuration: #{chain_name}")
      broadcast_config_change(:chain_deleted, chain_name, existing_chain)
      :ok
    else
      {:error, reason} = error ->
        Logger.error("Failed to delete chain #{chain_name}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Creates a backup of the current configuration.
  """
  @spec backup_config() :: {:ok, String.t()} | {:error, term()}
  def backup_config do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(":", "-")
    backup_filename = "chains_backup_#{timestamp}.yml"
    backup_path = Path.join(@backup_dir, backup_filename)

    with :ok <- File.mkdir_p(@backup_dir),
         {:ok, _} <- File.copy(@config_file, backup_path) do
      Logger.info("Configuration backed up to: #{backup_path}")
      {:ok, backup_path}
    else
      error ->
        Logger.error("Failed to backup configuration: #{inspect(error)}")
        {:error, :backup_failed}
    end
  end

  @doc """
  Restores configuration from a backup file.
  """
  @spec restore_config(String.t()) :: :ok | {:error, term()}
  def restore_config(backup_path) do
    with {:ok, _} <- File.stat(backup_path),
         :ok <- backup_current_config(),
         {:ok, _} <- File.copy(backup_path, @config_file),
         :ok <- reload_config_store() do
      Logger.info("Configuration restored from: #{backup_path}")
      broadcast_config_change(:config_restored, backup_path, nil)
      :ok
    else
      error ->
        Logger.error("Failed to restore configuration from #{backup_path}: #{inspect(error)}")
        {:error, :restore_failed}
    end
  end

  @doc """
  Validates a chain configuration without saving it.
  """
  @spec validate_chain_config(map()) :: :ok | {:error, term()}
  def validate_chain_config(chain_attrs) do
    case build_chain_config(chain_attrs) do
      {:ok, chain_config} -> ChainConfig.validate_chain_config(chain_config)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Lists available backup files.
  """
  @spec list_backups() :: {:ok, [String.t()]} | {:error, term()}
  def list_backups do
    case File.ls(@backup_dir) do
      {:ok, files} ->
        backup_files =
          files
          |> Enum.filter(&String.starts_with?(&1, "chains_backup_"))
          |> Enum.sort(:desc)

        {:ok, backup_files}

      {:error, :enoent} ->
        {:ok, []}

      error ->
        error
    end
  end

  # Private functions

  defp load_current_config do
    ChainConfig.load_config(@config_file)
  end

  defp validate_chain_name_unique(config, chain_name) do
    if Map.has_key?(config.chains, chain_name) do
      {:error, :chain_already_exists}
    else
      :ok
    end
  end

  defp get_existing_chain(config, chain_name) do
    case Map.get(config.chains, chain_name) do
      nil -> {:error, :chain_not_found}
      chain -> {:ok, chain}
    end
  end

  defp build_chain_config(attrs) do
    try do
      chain_config = %ChainConfig{
        chain_id: Map.get(attrs, "chain_id") || Map.get(attrs, :chain_id),
        name: Map.get(attrs, "name") || Map.get(attrs, :name),
        block_time: Map.get(attrs, "block_time") || Map.get(attrs, :block_time) || 12000,
        providers:
          parse_providers(Map.get(attrs, "providers") || Map.get(attrs, :providers) || []),
        connection: parse_connection(Map.get(attrs, "connection") || Map.get(attrs, :connection)),
        aggregation:
          parse_aggregation(Map.get(attrs, "aggregation") || Map.get(attrs, :aggregation)),
        failover: parse_failover(Map.get(attrs, "failover") || Map.get(attrs, :failover))
      }

      {:ok, chain_config}
    rescue
      error ->
        {:error, {:invalid_chain_config, error}}
    end
  end

  defp parse_providers(providers) when is_list(providers) do
    Enum.map(providers, fn provider ->
      %ChainConfig.Provider{
        id: Map.get(provider, "id") || Map.get(provider, :id),
        name: Map.get(provider, "name") || Map.get(provider, :name),
        priority: Map.get(provider, "priority") || Map.get(provider, :priority) || 1,
        type: Map.get(provider, "type") || Map.get(provider, :type) || "public",
        url: Map.get(provider, "url") || Map.get(provider, :url),
        ws_url: Map.get(provider, "ws_url") || Map.get(provider, :ws_url),
        api_key_required:
          Map.get(provider, "api_key_required") || Map.get(provider, :api_key_required) || false,
        region: Map.get(provider, "region") || Map.get(provider, :region)
      }
    end)
  end

  defp parse_providers(_), do: []

  defp parse_connection(nil), do: default_connection()

  defp parse_connection(conn) do
    %ChainConfig.Connection{
      heartbeat_interval:
        Map.get(conn, "heartbeat_interval") || Map.get(conn, :heartbeat_interval) || 30000,
      reconnect_interval:
        Map.get(conn, "reconnect_interval") || Map.get(conn, :reconnect_interval) || 5000,
      max_reconnect_attempts:
        Map.get(conn, "max_reconnect_attempts") || Map.get(conn, :max_reconnect_attempts) || 10
    }
  end

  defp parse_aggregation(nil), do: default_aggregation()

  defp parse_aggregation(agg) do
    %ChainConfig.Aggregation{
      deduplication_window:
        Map.get(agg, "deduplication_window") || Map.get(agg, :deduplication_window) || 2000,
      min_confirmations:
        Map.get(agg, "min_confirmations") || Map.get(agg, :min_confirmations) || 1,
      max_providers: Map.get(agg, "max_providers") || Map.get(agg, :max_providers) || 3,
      max_cache_size: Map.get(agg, "max_cache_size") || Map.get(agg, :max_cache_size) || 10000
    }
  end

  defp parse_failover(nil), do: default_failover()

  defp parse_failover(failover) do
    %ChainConfig.Failover{
      max_backfill_blocks:
        Map.get(failover, "max_backfill_blocks") || Map.get(failover, :max_backfill_blocks) || 100,
      backfill_timeout:
        Map.get(failover, "backfill_timeout") || Map.get(failover, :backfill_timeout) || 30000,
      enabled: Map.get(failover, "enabled") || Map.get(failover, :enabled) || true
    }
  end

  defp default_connection do
    %ChainConfig.Connection{
      heartbeat_interval: 30000,
      reconnect_interval: 5000,
      max_reconnect_attempts: 10
    }
  end

  defp default_aggregation do
    %ChainConfig.Aggregation{
      deduplication_window: 2000,
      min_confirmations: 1,
      max_providers: 3,
      max_cache_size: 10000
    }
  end

  defp default_failover do
    %ChainConfig.Failover{
      max_backfill_blocks: 100,
      backfill_timeout: 30000,
      enabled: true
    }
  end

  defp add_chain_to_config(config, chain_name, chain_config) do
    new_chains = Map.put(config.chains, chain_name, chain_config)
    {:ok, %{config | chains: new_chains}}
  end

  defp update_chain_in_config(config, chain_name, chain_config) do
    new_chains = Map.put(config.chains, chain_name, chain_config)
    {:ok, %{config | chains: new_chains}}
  end

  defp remove_chain_from_config(config, chain_name) do
    new_chains = Map.delete(config.chains, chain_name)
    {:ok, %{config | chains: new_chains}}
  end

  defp backup_current_config do
    case backup_config() do
      {:ok, _path} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp save_config_to_file(config) do
    yaml_data = %{
      "chains" => convert_chains_to_yaml(config.chains),
      "global" => convert_global_to_yaml(config.global)
    }

    case YamlElixir.write_to_string(yaml_data) do
      {:ok, yaml_content} ->
        case File.write(@config_file, yaml_content) do
          :ok -> :ok
          {:error, reason} -> {:error, {:file_write_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:yaml_generation_failed, reason}}
    end
  end

  defp convert_chains_to_yaml(chains) do
    chains
    |> Enum.map(fn {name, chain} ->
      {name,
       %{
         "chain_id" => chain.chain_id,
         "name" => chain.name,
         "block_time" => chain.block_time,
         "providers" => convert_providers_to_yaml(chain.providers),
         "connection" => convert_connection_to_yaml(chain.connection),
         "aggregation" => convert_aggregation_to_yaml(chain.aggregation),
         "failover" => convert_failover_to_yaml(chain.failover)
       }}
    end)
    |> Enum.into(%{})
  end

  defp convert_providers_to_yaml(providers) do
    Enum.map(providers, fn provider ->
      %{
        "id" => provider.id,
        "name" => provider.name,
        "priority" => provider.priority,
        "type" => provider.type,
        "url" => provider.url,
        "ws_url" => provider.ws_url,
        "api_key_required" => provider.api_key_required,
        "region" => provider.region
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.into(%{})
    end)
  end

  defp convert_connection_to_yaml(connection) do
    %{
      "heartbeat_interval" => connection.heartbeat_interval,
      "reconnect_interval" => connection.reconnect_interval,
      "max_reconnect_attempts" => connection.max_reconnect_attempts
    }
  end

  defp convert_aggregation_to_yaml(aggregation) do
    %{
      "deduplication_window" => aggregation.deduplication_window,
      "min_confirmations" => aggregation.min_confirmations,
      "max_providers" => aggregation.max_providers,
      "max_cache_size" => aggregation.max_cache_size
    }
  end

  defp convert_failover_to_yaml(failover) do
    %{
      "max_backfill_blocks" => failover.max_backfill_blocks,
      "backfill_timeout" => failover.backfill_timeout,
      "enabled" => failover.enabled
    }
  end

  defp convert_global_to_yaml(global) do
    %{
      "health_check" => %{
        "interval" => global.health_check.interval,
        "timeout" => global.health_check.timeout,
        "failure_threshold" => global.health_check.failure_threshold,
        "recovery_threshold" => global.health_check.recovery_threshold
      },
      "provider_management" => %{
        "auto_failover" => global.provider_management.auto_failover,
        "load_balancing" => global.provider_management.load_balancing
      },
      "deduplication" => %{
        "enabled" => global.deduplication.enabled,
        "algorithm" => global.deduplication.algorithm,
        "cache_size" => global.deduplication.cache_size,
        "cache_ttl" => global.deduplication.cache_ttl
      }
    }
  end

  defp reload_config_store do
    case ConfigStore.reload() do
      :ok -> :ok
      {:error, reason} -> {:error, {:config_reload_failed, reason}}
    end
  end

  defp broadcast_config_change(event, chain_name, chain_config) do
    PubSub.broadcast(@pubsub, "chain_config_changes", {event, chain_name, chain_config})
  end
end
