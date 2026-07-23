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

  @default_profile Lasso.Config.ProfileValidator.default_profile()

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

  @type chain_identifier :: pos_integer() | String.t()

  @spec add_provider(chain_identifier(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def add_provider(chain_name, provider_attrs, opts \\ []) do
    add_provider(@default_profile, chain_name, provider_attrs, opts)
  end

  @spec add_provider(String.t(), chain_identifier(), map(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def add_provider(profile, chain_identifier, provider_attrs, opts) do
    persist? = Keyword.get(opts, :persist, false)
    validate? = Keyword.get(opts, :validate, true)
    start_ws = Keyword.get(opts, :start_ws, :auto)

    provider_config = normalize_provider_config(provider_attrs)
    provider_id = Map.get(provider_config, :id)

    result =
      with {:ok, chain_id} <- resolve_chain_id(profile, chain_identifier),
           :ok <- maybe_validate(provider_config, validate?),
           :ok <- ensure_chain_started(profile, chain_id),
           :ok <- check_not_duplicate(profile, chain_id, provider_id),
           :ok <- ConfigStore.register_provider_runtime(profile, chain_id, provider_config) do
        finish_provider_add(
          profile,
          chain_id,
          provider_config,
          start_ws,
          persist?
        )
      end

    case result do
      :ok ->
        Logger.info("Successfully added provider #{provider_id} to chain #{chain_identifier}")
        {:ok, provider_id}

      {:error, reason} = error ->
        Logger.error(
          "Failed to add provider #{provider_id} to chain #{inspect(chain_identifier)}: #{inspect(reason)}"
        )

        error
    end
  end

  @spec remove_provider(chain_identifier(), String.t()) :: :ok | {:error, term()}
  def remove_provider(chain_name, provider_id)
      when (is_binary(chain_name) or (is_integer(chain_name) and chain_name > 0)) and
             is_binary(provider_id) do
    remove_provider(@default_profile, chain_name, provider_id, [])
  end

  @spec remove_provider(String.t(), chain_identifier(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def remove_provider(profile, chain_identifier, provider_id, opts \\ []) do
    persist? = Keyword.get(opts, :persist, false)

    with {:ok, chain_id} <- resolve_chain_id(profile, chain_identifier),
         {:ok, _provider} <- ConfigStore.get_provider(profile, chain_id, provider_id),
         instance_id = Catalog.lookup_instance_id(profile, chain_id, provider_id),
         :ok <- ConfigStore.unregister_provider_runtime(profile, chain_id, provider_id),
         :ok <- ChainSupervisor.remove_provider(profile, chain_id, provider_id, instance_id),
         :ok <- maybe_persist_remove(chain_id, provider_id, persist?) do
      Logger.info("Successfully removed provider #{provider_id} from chain #{chain_id}")
      :ok
    else
      {:error, :provider_not_found} ->
        :ok

      {:error, :not_found} ->
        :ok

      {:error, reason} = error ->
        Logger.error(
          "Failed to remove provider #{provider_id} from chain #{inspect(chain_identifier)}: #{inspect(reason)}"
        )

        error
    end
  end

  @spec update_provider(chain_identifier(), String.t(), map(), keyword()) ::
          :ok | {:error, term()}
  def update_provider(chain_name, provider_id, updates, opts \\ []) do
    update_provider(@default_profile, chain_name, provider_id, updates, opts)
  end

  @spec update_provider(String.t(), chain_identifier(), String.t(), map(), keyword()) ::
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

  @spec list_providers(chain_identifier()) :: {:ok, [provider_summary()]} | {:error, term()}
  def list_providers(chain_name) do
    list_providers(@default_profile, chain_name)
  end

  @spec list_providers(String.t(), chain_identifier()) ::
          {:ok, [provider_summary()]} | {:error, term()}
  def list_providers(profile, chain_identifier) do
    with {:ok, chain_id} <- resolve_chain_id(profile, chain_identifier) do
      profile_providers = Catalog.get_profile_providers(profile, chain_id)

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
  end

  @spec get_provider(chain_identifier(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_provider(chain_name, provider_id) do
    get_provider(@default_profile, chain_name, provider_id)
  end

  @spec get_provider(String.t(), chain_identifier(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def get_provider(profile, chain_identifier, provider_id) do
    with {:ok, chain_id} <- resolve_chain_id(profile, chain_identifier) do
      ConfigStore.get_provider(profile, chain_id, provider_id)
    end
  end

  # Private functions

  defp resolve_chain_id(_profile, chain_id) when is_integer(chain_id) and chain_id > 0,
    do: {:ok, chain_id}

  defp resolve_chain_id(profile, chain_identifier) when is_binary(chain_identifier) do
    case ConfigStore.lookup_chain_id_in_profile(profile, chain_identifier) do
      {:ok, chain_id} -> {:ok, chain_id}
      :not_found -> {:error, :chain_not_found}
    end
  end

  defp resolve_chain_id(_profile, _chain_identifier), do: {:error, :chain_not_found}

  defp ensure_chain_started(profile, chain_id) when is_integer(chain_id) and chain_id > 0 do
    case ConfigStore.get_chain(profile, chain_id) do
      {:ok, chain_config} ->
        if Lasso.ProfileChainSupervisor.running?(profile, chain_id) do
          :ok
        else
          case Lasso.ProfileChainSupervisor.start_profile_chain(profile, chain_id, chain_config) do
            {:ok, _pid} -> :ok
            {:error, {:already_started, _pid}} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end

      {:error, :not_found} ->
        {:error, :chain_not_found}
    end
  end

  defp finish_provider_add(profile, chain_id, provider_config, start_ws, persist?) do
    result =
      case ChainSupervisor.ensure_provider(profile, chain_id, provider_config, start_ws: start_ws) do
        :ok -> maybe_persist_add(chain_id, provider_config, persist?)
        {:error, _reason} = error -> error
      end

    case result do
      :ok ->
        :ok

      {:error, _reason} = error ->
        instance_id = Catalog.lookup_instance_id(profile, chain_id, provider_config.id)
        _ = ConfigStore.unregister_provider_runtime(profile, chain_id, provider_config.id)
        _ = ChainSupervisor.remove_provider(profile, chain_id, provider_config.id, instance_id)
        error
    end
  end

  defp normalize_provider_config(attrs) when is_map(attrs) do
    %{
      id: attr(attrs, :id),
      name: attr(attrs, :name),
      url: attr(attrs, :url),
      ws_url: attr(attrs, :ws_url),
      priority: attr(attrs, :priority, 100),
      capabilities: attr(attrs, :capabilities),
      subscribe_new_heads: attr(attrs, :subscribe_new_heads),
      archival: attr(attrs, :archival, true),
      sharing_mode: attr(attrs, :sharing_mode, :auto),
      api_key: attr(attrs, :api_key),
      credentials: attr(attrs, :credentials),
      headers: attr(attrs, :headers),
      auth_headers: attr(attrs, :auth_headers),
      __mock__: attr(attrs, :__mock__)
    }
  end

  defp attr(attrs, key, default \\ nil) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Atom.to_string(key), default)
    end
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
