defmodule LivechainWeb.Admin.ChainController do
  use LivechainWeb, :controller

  alias Livechain.Config.{ChainConfigManager, ConfigValidator}
  alias Phoenix.PubSub

  require Logger

  @doc """
  Lists all chain configurations.
  GET /api/admin/chains
  """
  def index(conn, _params) do
    case ChainConfigManager.list_chains() do
      {:ok, chains} ->
        # Convert to a list format that's easier to work with in frontend
        chains_list =
          chains
          |> Enum.map(fn {name, config} ->
            %{
              id: name,
              name: config.name,
              chain_id: config.chain_id,
              provider_count: length(config.providers),
              providers:
                Enum.map(config.providers, fn provider ->
                  %{
                    id: provider.id,
                    name: provider.name,
                    type: provider.type,
                    priority: provider.priority,
                    url: provider.url,
                    ws_url: provider.ws_url,
                    api_key_required: provider.api_key_required,
                    region: provider.region
                  }
                end),
              connection: %{
                heartbeat_interval: config.connection.heartbeat_interval,
                reconnect_interval: config.connection.reconnect_interval,
                max_reconnect_attempts: config.connection.max_reconnect_attempts
              },
              failover: %{
                max_backfill_blocks: config.failover.max_backfill_blocks,
                backfill_timeout: config.failover.backfill_timeout,
                enabled: config.failover.enabled
              }
            }
          end)
          |> Enum.sort_by(& &1.id)

        json(conn, %{chains: chains_list})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to list chains", details: inspect(reason)})
    end
  end

  @doc """
  Gets a specific chain configuration.
  GET /api/admin/chains/:id
  """
  def show(conn, %{"id" => chain_id}) do
    case ChainConfigManager.get_chain(chain_id) do
      {:ok, config} ->
        chain_data = %{
          id: chain_id,
          name: config.name,
          chain_id: config.chain_id,
          providers:
            Enum.map(config.providers, fn provider ->
              %{
                id: provider.id,
                name: provider.name,
                type: provider.type,
                priority: provider.priority,
                url: provider.url,
                ws_url: provider.ws_url,
                api_key_required: provider.api_key_required,
                region: provider.region
              }
            end),
          connection: %{
            heartbeat_interval: config.connection.heartbeat_interval,
            reconnect_interval: config.connection.reconnect_interval,
            max_reconnect_attempts: config.connection.max_reconnect_attempts
          },
          failover: %{
            max_backfill_blocks: config.failover.max_backfill_blocks,
            backfill_timeout: config.failover.backfill_timeout,
            enabled: config.failover.enabled
          }
        }

        json(conn, %{chain: chain_data})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Chain not found"})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to get chain", details: inspect(reason)})
    end
  end

  @doc """
  Creates a new chain configuration.
  POST /api/admin/chains
  """
  def create(conn, %{"chain" => chain_params}) do
    with :ok <- validate_chain_params(chain_params),
         chain_id <- Map.get(chain_params, "id") || generate_chain_id(chain_params),
         {:ok, chain_config} <- ChainConfigManager.create_chain(chain_id, chain_params) do
      Logger.info("Created chain configuration via API: #{chain_id}")

      # Broadcast the change for real-time updates
      PubSub.broadcast(
        Livechain.PubSub,
        "chain_config_updates",
        {:chain_created, chain_id, chain_config}
      )

      conn
      |> put_status(:created)
      |> json(%{
        message: "Chain created successfully",
        chain_id: chain_id,
        chain: format_chain_response(chain_id, chain_config)
      })
    else
      {:error, :chain_already_exists} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "Chain already exists"})

      {:error, reason} ->
        Logger.error("Failed to create chain via API: #{inspect(reason)}")

        conn
        |> put_status(:bad_request)
        |> json(%{error: "Failed to create chain", details: format_error(reason)})
    end
  end

  @doc """
  Updates an existing chain configuration.
  PUT /api/admin/chains/:id
  """
  def update(conn, %{"id" => chain_id, "chain" => chain_params}) do
    with :ok <- validate_chain_params(chain_params),
         {:ok, chain_config} <- ChainConfigManager.update_chain(chain_id, chain_params) do
      Logger.info("Updated chain configuration via API: #{chain_id}")

      # Broadcast the change for real-time updates
      PubSub.broadcast(
        Livechain.PubSub,
        "chain_config_updates",
        {:chain_updated, chain_id, chain_config}
      )

      json(conn, %{
        message: "Chain updated successfully",
        chain_id: chain_id,
        chain: format_chain_response(chain_id, chain_config)
      })
    else
      {:error, :chain_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Chain not found"})

      {:error, reason} ->
        Logger.error("Failed to update chain via API: #{inspect(reason)}")

        conn
        |> put_status(:bad_request)
        |> json(%{error: "Failed to update chain", details: format_error(reason)})
    end
  end

  @doc """
  Deletes a chain configuration.
  DELETE /api/admin/chains/:id
  """
  def delete(conn, %{"id" => chain_id}) do
    case ChainConfigManager.delete_chain(chain_id) do
      :ok ->
        Logger.info("Deleted chain configuration via API: #{chain_id}")

        # Broadcast the change for real-time updates
        PubSub.broadcast(
          Livechain.PubSub,
          "chain_config_updates",
          {:chain_deleted, chain_id, nil}
        )

        json(conn, %{message: "Chain deleted successfully", chain_id: chain_id})

      {:error, :chain_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Chain not found"})

      {:error, reason} ->
        Logger.error("Failed to delete chain via API: #{inspect(reason)}")

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to delete chain", details: format_error(reason)})
    end
  end

  @doc """
  Validates a chain configuration without saving.
  POST /api/admin/chains/validate
  """
  def validate(conn, %{"chain" => chain_params}) do
    case ChainConfigManager.validate_chain_config(chain_params) do
      :ok ->
        json(conn, %{valid: true, message: "Chain configuration is valid"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          valid: false,
          error: "Invalid chain configuration",
          details: format_validation_errors(reason)
        })
    end
  end

  @doc """
  Tests connectivity to chain providers.
  POST /api/admin/chains/:id/test
  """
  def test_connectivity(conn, %{"id" => chain_id}) do
    case ChainConfigManager.get_chain(chain_id) do
      {:ok, config} ->
        # Test each provider
        test_results =
          Enum.map(config.providers, fn provider ->
            case ConfigValidator.test_provider_connectivity(provider) do
              :ok ->
                %{
                  provider_id: provider.id,
                  provider_name: provider.name,
                  url: provider.url,
                  status: "connected",
                  # Could be enhanced to measure actual response time
                  response_time_ms: nil
                }

              {:error, reason} ->
                %{
                  provider_id: provider.id,
                  provider_name: provider.name,
                  url: provider.url,
                  status: "failed",
                  error: format_error(reason)
                }
            end
          end)

        successful_tests = Enum.count(test_results, &(&1.status == "connected"))
        total_tests = length(test_results)

        json(conn, %{
          chain_id: chain_id,
          summary: %{
            total_providers: total_tests,
            successful_connections: successful_tests,
            failed_connections: total_tests - successful_tests,
            success_rate: if(total_tests > 0, do: successful_tests / total_tests * 100, else: 0)
          },
          results: test_results
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Chain not found"})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to get chain for testing", details: inspect(reason)})
    end
  end

  @doc """
  Lists available backup files.
  GET /api/admin/chains/backups
  """
  def list_backups(conn, _params) do
    case ChainConfigManager.list_backups() do
      {:ok, backups} ->
        json(conn, %{backups: backups})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to list backups", details: inspect(reason)})
    end
  end

  @doc """
  Creates a backup of current configuration.
  POST /api/admin/chains/backup
  """
  def create_backup(conn, _params) do
    case ChainConfigManager.backup_config() do
      {:ok, backup_path} ->
        json(conn, %{
          message: "Backup created successfully",
          backup_path: backup_path,
          filename: Path.basename(backup_path)
        })

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to create backup", details: inspect(reason)})
    end
  end

  # Private helper functions

  defp validate_chain_params(params) do
    required_fields = ["name", "chain_id"]

    missing_fields =
      Enum.filter(required_fields, fn field ->
        is_nil(Map.get(params, field)) or Map.get(params, field) == ""
      end)

    if Enum.empty?(missing_fields) do
      :ok
    else
      {:error, {:missing_required_fields, missing_fields}}
    end
  end

  defp generate_chain_id(%{"name" => name}) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/, "_")
    |> String.trim("_")
  end

  defp generate_chain_id(_), do: "unknown_chain"

  defp format_chain_response(chain_id, config) do
    %{
      id: chain_id,
      name: config.name,
      chain_id: config.chain_id,
      provider_count: length(config.providers)
    }
  end

  defp format_error({:invalid_chain_config, error}),
    do: "Invalid configuration: #{inspect(error)}"

  defp format_error({:yaml_generation_failed, reason}),
    do: "YAML generation failed: #{inspect(reason)}"

  defp format_error({:file_write_failed, reason}), do: "File write failed: #{inspect(reason)}"

  defp format_error({:config_reload_failed, reason}),
    do: "Config reload failed: #{inspect(reason)}"

  defp format_error({:connectivity_failed, provider_id, reason}),
    do: "Provider #{provider_id} connectivity failed: #{inspect(reason)}"

  defp format_error(reason), do: inspect(reason)

  defp format_validation_errors({:missing_required_fields, fields}),
    do: "Missing required fields: #{Enum.join(fields, ", ")}"

  defp format_validation_errors(reason), do: ConfigValidator.format_error(reason)
end
