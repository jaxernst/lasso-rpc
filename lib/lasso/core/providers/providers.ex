defmodule Lasso.Providers do
  @moduledoc """
  Public API for dynamic provider management.

  Provides a clean interface for adding, removing, and managing
  RPC providers at runtime without requiring application restarts or YAML edits.
  """

  require Logger
  alias Lasso.Config.{ConfigStore, ConfigValidator}
  alias Lasso.Providers.{Catalog, InstanceState}
  alias Lasso.RPC.ChainSupervisor

  @default_profile "default"

  @type provider_config :: %{
          id: String.t(),
          name: String.t(),
          url: String.t(),
          ws_url: String.t() | nil,
          priority: integer()
        }

  @type provider_summary :: %{
          id: String.t(),
          name: String.t(),
          status: atom(),
          availability: atom(),
          has_http: boolean(),
          has_ws: boolean()
        }

  @spec add_provider(String.t(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def add_provider(chain_name, provider_attrs, opts \\ []) do
    add_provider(@default_profile, chain_name, provider_attrs, opts)
  end

  @spec add_provider(String.t(), String.t(), map(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def add_provider(profile, chain_name, provider_attrs, opts) do
    persist? = Keyword.get(opts, :persist, false)
    validate? = Keyword.get(opts, :validate, true)
    start_ws = Keyword.get(opts, :start_ws, :auto)

    provider_config = normalize_provider_config(provider_attrs)
    provider_id = Map.get(provider_config, :id)

    with :ok <- maybe_validate(provider_config, validate?),
         :ok <- ensure_chain_started(profile, chain_name),
         :ok <- check_not_duplicate(profile, chain_name, provider_id),
         :ok <- ConfigStore.register_provider_runtime(profile, chain_name, provider_config),
         :ok <-
           ChainSupervisor.ensure_provider(profile, chain_name, provider_config,
             start_ws: start_ws
           ),
         :ok <- maybe_persist_add(chain_name, provider_config, persist?) do
      Logger.info("Successfully added provider #{provider_id} to #{chain_name}")
      {:ok, provider_id}
    else
      {:error, reason} = error ->
        if is_binary(provider_id) do
          _ = ConfigStore.unregister_provider_runtime(profile, chain_name, provider_id)
        end

        Logger.error("Failed to add provider #{provider_id} to #{chain_name}: #{inspect(reason)}")
        error
    end
  end

  @spec remove_provider(String.t(), String.t()) :: :ok | {:error, term()}
  def remove_provider(chain_name, provider_id)
      when is_binary(chain_name) and is_binary(provider_id) do
    remove_provider(@default_profile, chain_name, provider_id, [])
  end

  @spec remove_provider(String.t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def remove_provider(profile, chain_name, provider_id, opts \\ []) do
    persist? = Keyword.get(opts, :persist, false)

    with :ok <- ChainSupervisor.remove_provider(profile, chain_name, provider_id),
         :ok <- ConfigStore.unregister_provider_runtime(profile, chain_name, provider_id),
         :ok <- maybe_persist_remove(chain_name, provider_id, persist?) do
      Logger.info("Successfully removed provider #{provider_id} from #{chain_name}")
      :ok
    else
      {:error, :provider_not_found} ->
        # It may already be absent from runtime config; treat as successful cleanup.
        :ok

      {:error, reason} = error ->
        Logger.error(
          "Failed to remove provider #{provider_id} from #{chain_name}: #{inspect(reason)}"
        )

        error
    end
  end

  @spec update_provider(String.t(), String.t(), map(), keyword()) :: :ok | {:error, term()}
  def update_provider(chain_name, provider_id, updates, opts \\ []) do
    update_provider(@default_profile, chain_name, provider_id, updates, opts)
  end

  @spec update_provider(String.t(), String.t(), String.t(), map(), keyword()) ::
          :ok | {:error, term()}
  def update_provider(profile, chain_name, provider_id, updates, opts) do
    persist? = Keyword.get(opts, :persist, false)

    with {:ok, existing} <- get_provider(profile, chain_name, provider_id),
         updated_config = Map.merge(existing, normalize_provider_config(updates)),
         :ok <- remove_provider(profile, chain_name, provider_id, persist: false),
         {:ok, _} <- add_provider(profile, chain_name, updated_config, persist: persist?) do
      Logger.info("Successfully updated provider #{provider_id} in #{chain_name}")
      :ok
    else
      {:error, reason} = error ->
        Logger.error(
          "Failed to update provider #{provider_id} in #{chain_name}: #{inspect(reason)}"
        )

        error
    end
  end

  @spec list_providers(String.t()) :: {:ok, [provider_summary()]} | {:error, term()}
  def list_providers(chain_name) do
    list_providers(@default_profile, chain_name)
  end

  @spec list_providers(String.t(), String.t()) :: {:ok, [provider_summary()]} | {:error, term()}
  def list_providers(profile, chain_name) do
    profile_providers = Catalog.get_profile_providers(profile, chain_name)

    summaries =
      Enum.map(profile_providers, fn pp ->
        instance_id = pp.instance_id

        instance_config =
          case Catalog.get_instance(instance_id) do
            {:ok, config} -> config
            _ -> %{}
          end

        health = InstanceState.read_health(instance_id)
        ws_status = InstanceState.read_ws_status(instance_id)
        http_cb = InstanceState.read_circuit(instance_id, :http)
        ws_cb = InstanceState.read_circuit(instance_id, :ws)

        url = Map.get(instance_config, :url)
        ws_url = Map.get(instance_config, :ws_url)

        %{
          id: pp.provider_id,
          name: pp[:name] || pp.provider_id,
          status: health.status,
          availability: InstanceState.status_to_availability(health.status),
          has_http: is_binary(url),
          has_ws: is_binary(ws_url),
          http_status: health.http_status,
          ws_status: ws_status.status,
          http_availability: InstanceState.status_to_availability(health.http_status),
          ws_availability: InstanceState.status_to_availability(ws_status.status),
          http_cb_state: http_cb.state,
          ws_cb_state: ws_cb.state
        }
      end)

    {:ok, summaries}
  end

  @spec get_provider(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_provider(chain_name, provider_id) do
    get_provider(@default_profile, chain_name, provider_id)
  end

  @spec get_provider(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_provider(profile, chain_name, provider_id) do
    ConfigStore.get_provider(profile, chain_name, provider_id)
  end

  # Private functions

  defp ensure_chain_started(profile, chain_name) do
    case ConfigStore.get_chain(profile, chain_name) do
      {:ok, _chain_config} ->
        :ok

      {:error, :not_found} ->
        Logger.info("Chain '#{chain_name}' not found, creating with default configuration")

        default_config = create_default_chain_config(chain_name)

        with :ok <- ConfigStore.register_chain_runtime(profile, chain_name, default_config),
             {:ok, _pid} <- start_chain_supervisor(profile, chain_name, default_config) do
          Logger.info("Successfully started chain supervisor for '#{chain_name}'")
          :ok
        else
          {:error, {:already_started, _pid}} ->
            :ok

          {:error, reason} = error ->
            Logger.error("Failed to start chain '#{chain_name}': #{inspect(reason)}")
            error
        end
    end
  end

  defp create_default_chain_config(chain_name) do
    %{
      chain_id: nil,
      name: chain_name,
      providers: [],
      connection: %{
        heartbeat_interval: 30_000,
        reconnect_interval: 5_000,
        max_reconnect_attempts: 5
      },
      failover: %{
        enabled: true,
        max_backfill_blocks: 100,
        backfill_timeout: 30_000
      }
    }
  end

  defp start_chain_supervisor(profile, chain_name, _chain_config_attrs) do
    case ConfigStore.get_chain(profile, chain_name) do
      {:ok, chain_config} ->
        Lasso.ProfileChainSupervisor.start_profile_chain(profile, chain_name, chain_config)

      {:error, reason} ->
        {:error, {:config_fetch_failed, reason}}
    end
  end

  defp normalize_provider_config(attrs) when is_map(attrs) do
    %{
      id: Map.get(attrs, :id) || Map.get(attrs, "id"),
      name: Map.get(attrs, :name) || Map.get(attrs, "name"),
      url: Map.get(attrs, :url) || Map.get(attrs, "url"),
      ws_url: Map.get(attrs, :ws_url) || Map.get(attrs, "ws_url"),
      priority: Map.get(attrs, :priority) || Map.get(attrs, "priority") || 100
    }
  end

  defp maybe_validate(provider_config, true) do
    with :ok <- validate_required_fields(provider_config),
         :ok <- ConfigValidator.validate_provider_url(provider_config.url) do
      maybe_validate_ws_url(provider_config.ws_url)
    end
  end

  defp maybe_validate(_provider_config, false), do: :ok

  defp validate_required_fields(config) do
    required = [:id, :name, :url]
    missing = Enum.filter(required, fn field -> is_nil(Map.get(config, field)) end)

    if Enum.empty?(missing) do
      :ok
    else
      {:error, {:missing_required_fields, missing}}
    end
  end

  defp maybe_validate_ws_url(nil), do: :ok

  defp maybe_validate_ws_url(ws_url) when is_binary(ws_url) do
    ConfigValidator.validate_provider_url(ws_url)
  end

  defp check_not_duplicate(profile, chain_name, provider_id) do
    case get_provider(profile, chain_name, provider_id) do
      {:ok, _} -> {:error, {:already_exists, provider_id}}
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_persist_add(_chain_name, _provider_config, _persist?), do: :ok

  defp maybe_persist_remove(_chain_name, _provider_id, _persist?), do: :ok
end
