defmodule Lasso.Config.ChainConfigManager do
  @moduledoc """
  Context module for managing chain configurations dynamically.

  Provides CRUD operations for chain configurations while maintaining
  compatibility with  YAML + ETS architecture. Supports
  hot-reloading and real-time updates via PubSub.
  """

  require Logger
  alias Lasso.Config.{ChainConfig, ConfigStore}
  alias Phoenix.PubSub

  @config_file System.get_env("LASSO_CHAINS_PATH") || "config/chains.yml"
  @backup_dir System.get_env("LASSO_BACKUP_DIR") || "priv/config_backups"
  @pubsub Lasso.PubSub

  @doc """
  Lists all available chains with their configurations.
  """
  @spec list_chains() :: {:ok, %{String.t() => ChainConfig.t()}}
  def list_chains do
    chains = ConfigStore.get_all_chains()
    {:ok, chains}
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

  @doc """
  Adds a provider to a chain's configuration and persists to YAML.

  ## Example

      ChainConfigManager.add_provider_to_chain("ethereum", %{
        id: "new_provider",
        name: "New Provider",
        url: "https://rpc.example.com",
        ws_url: "wss://ws.example.com"
      })
  """
  @spec add_provider_to_chain(String.t(), map()) ::
          {:ok, ChainConfig.Provider.t()} | {:error, term()}
  def add_provider_to_chain(chain_name, provider_attrs) do
    with {:ok, current_config} <- load_current_config(),
         {:ok, chain_config} <- get_existing_chain(current_config, chain_name),
         {:ok, provider_config} <- build_provider_config(provider_attrs),
         :ok <- validate_provider_id_unique(chain_config, provider_config.id),
         {:ok, updated_chain} <- add_provider_to_chain_config(chain_config, provider_config),
         {:ok, new_config} <-
           update_chain_in_full_config(current_config, chain_name, updated_chain),
         :ok <- backup_current_config(),
         :ok <- save_config_to_file(new_config),
         :ok <- reload_config_store() do
      Logger.info("Added provider #{provider_config.id} to chain #{chain_name} in config")
      broadcast_config_change(:provider_added, chain_name, provider_config)
      {:ok, provider_config}
    else
      {:error, reason} = error ->
        Logger.error("Failed to add provider to chain #{chain_name}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Removes a provider from a chain's configuration and persists to YAML.

  ## Example

      ChainConfigManager.remove_provider_from_chain("ethereum", "old_provider")
  """
  @spec remove_provider_from_chain(String.t(), String.t()) :: :ok | {:error, term()}
  def remove_provider_from_chain(chain_name, provider_id) do
    with {:ok, current_config} <- load_current_config(),
         {:ok, chain_config} <- get_existing_chain(current_config, chain_name),
         :ok <- validate_provider_exists(chain_config, provider_id),
         {:ok, updated_chain} <- remove_provider_from_chain_config(chain_config, provider_id),
         {:ok, new_config} <-
           update_chain_in_full_config(current_config, chain_name, updated_chain),
         :ok <- backup_current_config(),
         :ok <- save_config_to_file(new_config),
         :ok <- reload_config_store() do
      Logger.info("Removed provider #{provider_id} from chain #{chain_name} in config")
      broadcast_config_change(:provider_removed, chain_name, provider_id)
      :ok
    else
      {:error, reason} = error ->
        Logger.error("Failed to remove provider from chain #{chain_name}: #{inspect(reason)}")
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
        providers:
          parse_providers(Map.get(attrs, "providers") || Map.get(attrs, :providers) || []),
        connection: parse_connection(Map.get(attrs, "connection") || Map.get(attrs, :connection)),
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

    # Convert to YAML format using Jason and manual formatting
    case encode_as_yaml(yaml_data) do
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
         "providers" => convert_providers_to_yaml(chain.providers),
         "connection" => convert_connection_to_yaml(chain.connection),
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

  # Simple YAML encoder using Jason and manual formatting
  defp encode_as_yaml(data) do
    try do
      case Jason.encode(data, pretty: true) do
        {:ok, json_string} ->
          # Convert JSON to YAML format by replacing JSON syntax with YAML
          yaml_content =
            json_string
            # Remove quotes from keys
            |> String.replace(~r/"([^"]+)":/, "\\1:")
            # Keep quotes around string values
            |> String.replace(~r/"([^"]+)"/, "'\\1'")
            # YAML booleans
            |> String.replace("true", "true")
            |> String.replace("false", "false")
            # YAML null
            |> String.replace("null", "~")
            # Preserve newlines
            |> String.replace("\n", "\n")

          {:ok, yaml_content}

        {:error, reason} ->
          {:error, reason}
      end
    catch
      _, reason ->
        {:error, reason}
    end
  end

  # Provider-specific helpers

  defp build_provider_config(attrs) do
    try do
      provider = %ChainConfig.Provider{
        id: Map.get(attrs, :id) || Map.get(attrs, "id"),
        name: Map.get(attrs, :name) || Map.get(attrs, "name"),
        priority: Map.get(attrs, :priority) || Map.get(attrs, "priority") || 100,
        type: Map.get(attrs, :type) || Map.get(attrs, "type") || "public",
        url: Map.get(attrs, :url) || Map.get(attrs, "url"),
        ws_url: Map.get(attrs, :ws_url) || Map.get(attrs, "ws_url"),
        api_key_required:
          Map.get(attrs, :api_key_required) || Map.get(attrs, "api_key_required") || false,
        region: Map.get(attrs, :region) || Map.get(attrs, "region")
      }

      {:ok, provider}
    rescue
      error -> {:error, {:invalid_provider_config, error}}
    end
  end

  defp validate_provider_id_unique(chain_config, provider_id) do
    if Enum.any?(chain_config.providers, fn p -> p.id == provider_id end) do
      {:error, {:provider_already_exists, provider_id}}
    else
      :ok
    end
  end

  defp validate_provider_exists(chain_config, provider_id) do
    if Enum.any?(chain_config.providers, fn p -> p.id == provider_id end) do
      :ok
    else
      {:error, {:provider_not_found, provider_id}}
    end
  end

  defp add_provider_to_chain_config(chain_config, provider_config) do
    updated_providers = chain_config.providers ++ [provider_config]
    {:ok, %{chain_config | providers: updated_providers}}
  end

  defp remove_provider_from_chain_config(chain_config, provider_id) do
    updated_providers = Enum.reject(chain_config.providers, fn p -> p.id == provider_id end)
    {:ok, %{chain_config | providers: updated_providers}}
  end

  defp update_chain_in_full_config(config, chain_name, updated_chain_config) do
    new_chains = Map.put(config.chains, chain_name, updated_chain_config)
    {:ok, %{config | chains: new_chains}}
  end
end
