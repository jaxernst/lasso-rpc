defmodule Lasso.Config.ObservationConfig do
  @moduledoc "Configuration for independent observation activities and evidence freshness."

  alias Lasso.Config.{ChainConfig, MonitoringDefaults}

  @intervals [:http_heads_interval_ms, :http_backup_interval_ms, :chain_identity_interval_ms]
  @booleans [:background_observations, :subscribe_new_heads]
  @fields @intervals ++ @booleans ++ [:evidence_freshness_ms]
  @max_interval_ms 31_536_000_000

  @spec max_interval_ms() :: pos_integer()
  def max_interval_ms, do: @max_interval_ms

  @spec fields() :: [atom()]
  def fields, do: @fields
  @spec override_fields() :: [atom()]
  def override_fields, do: @intervals ++ @booleans

  @doc "Makes saved legacy provider preferences explicit before a sparse override is edited."
  @spec legacy_overrides(map(), map() | nil) :: map()
  def legacy_overrides(chain, provider) do
    case get(provider, :observation_overrides) do
      existing when is_map(existing) -> normalize_overrides(existing)
      nil -> legacy_provider_overrides(chain, provider)
    end
  end

  defp normalize_overrides(overrides) do
    Map.new(overrides, fn {key, value} ->
      {Enum.find(override_fields(), &(to_string(&1) == to_string(key))) || key, value}
    end)
  end

  defp legacy_provider_overrides(chain, provider) do
    monitoring = get(chain, :monitoring, %{}) || %{}
    base_interval = get(monitoring, :probe_interval_ms, 12_000) || 12_000

    %{}
    |> put_legacy(:background_observations, get(provider, :background_observations), false)
    |> put_legacy(
      :subscribe_new_heads,
      legacy_subscription_preference(chain, provider, monitoring),
      nil
    )
    |> put_legacy_interval(
      :http_heads_interval_ms,
      get(provider, :block_poll_interval_ms),
      base_interval
    )
    |> put_legacy_backup(get(provider, :block_poll_interval_ms), base_interval, monitoring)
    |> put_legacy_interval(
      :chain_identity_interval_ms,
      get(provider, :chain_identity_interval_ms),
      base_interval
    )
  end

  defp put_legacy(map, key, value, false) when value == false, do: Map.put(map, key, value)
  defp put_legacy(map, key, value, nil) when is_boolean(value), do: Map.put(map, key, value)
  defp put_legacy(map, _, _, _), do: map

  defp legacy_subscription_preference(chain, provider, monitoring) do
    preference = get(provider, :subscribe_new_heads)

    if preference == true and legacy_subscription_paused?(chain, monitoring),
      do: nil,
      else: preference
  end

  defp legacy_subscription_paused?(chain, monitoring),
    do:
      is_nil(get(monitoring, :subscribe_new_heads)) and
        get(chain, :new_heads_monitoring, true) == false

  defp put_legacy_interval(map, key, value, base) when is_integer(value) and value > 0,
    do: Map.put(map, key, max(value, base))

  defp put_legacy_interval(map, _, _, _), do: map

  defp put_legacy_backup(map, value, base, monitoring) when is_integer(value) and value > 0 do
    if is_nil(get(monitoring, :http_backup_interval_ms)),
      do: Map.put(map, :http_backup_interval_ms, max(value, base) * 3),
      else: map
  end

  defp put_legacy_backup(map, _, _, _), do: map

  @doc "Explicit defaults for newly created chains; legacy configuration is not rewritten."
  @spec new_defaults(integer() | nil) :: map()
  def new_defaults(block_time_ms) do
    %{
      background_observations: true,
      http_heads_interval_ms: MonitoringDefaults.default_probe_interval_ms(block_time_ms),
      http_backup_interval_ms: 60_000,
      chain_identity_interval_ms: 1_800_000,
      evidence_freshness_ms: default_freshness(block_time_ms),
      subscribe_new_heads: true
    }
  end

  @spec default_freshness(term()) :: pos_integer()
  def default_freshness(block_time_ms) when is_integer(block_time_ms) and block_time_ms > 0,
    do: max(30_000, min(block_time_ms * 4, 60_000))

  def default_freshness(_), do: 30_000

  @doc "Resolves a single reference before ownership or sharing policy is applied."
  @spec resolve(map(), map() | nil) :: map()
  def resolve(chain, provider) do
    monitoring = get(chain, :monitoring, %{}) || %{}
    raw_overrides = get(provider, :observation_overrides)

    overrides =
      if is_map(raw_overrides) do
        # File profiles have no edit flow that first materializes legacy fields.
        # Keep unspecified legacy preferences when a sparse YAML override is added.
        Map.merge(legacy_provider_overrides(chain, provider), normalize_overrides(raw_overrides))
      else
        legacy_overrides(chain, provider)
      end

    provider = if is_map(raw_overrides), do: %{}, else: provider
    legacy_interval = get(monitoring, :probe_interval_ms, 12_000) || 12_000
    legacy_http = max(legacy_interval, get(provider, :block_poll_interval_ms, 0) || 0)
    legacy_identity = max(legacy_interval, get(provider, :chain_identity_interval_ms, 0) || 0)
    websocket = get(chain, :websocket, %{}) || %{}
    legacy_ws = value(provider, :subscribe_new_heads, get(websocket, :subscribe_new_heads, true))
    legacy_ws = if legacy_subscription_paused?(chain, monitoring), do: false, else: legacy_ws

    %{
      background_observations:
        get(monitoring, :background_observations, true) != false and
          get(provider, :background_observations, true) != false and
          get(overrides, :background_observations, true) != false,
      http_heads_interval_ms:
        resolve_value(overrides, monitoring, :http_heads_interval_ms, legacy_http),
      http_backup_interval_ms:
        resolve_value(overrides, monitoring, :http_backup_interval_ms, legacy_http * 3),
      chain_identity_interval_ms:
        resolve_value(overrides, monitoring, :chain_identity_interval_ms, legacy_identity),
      evidence_freshness_ms:
        value(monitoring, :evidence_freshness_ms, default_freshness(get(chain, :block_time_ms))),
      subscribe_new_heads:
        (is_map(raw_overrides) or not legacy_subscription_paused?(chain, monitoring)) and
          resolve_value(overrides, monitoring, :subscribe_new_heads, legacy_ws)
    }
  end

  @doc "Decodes atom or string keys without inventing missing canonical settings."
  @spec monitoring(map() | nil, ChainConfig.Monitoring.t()) :: ChainConfig.Monitoring.t()
  def monitoring(config, defaults \\ %ChainConfig.Monitoring{}) do
    config = config || %{}

    Enum.reduce(Map.keys(Map.from_struct(defaults)), defaults, fn field, acc ->
      Map.put(acc, field, get(config, field, Map.get(defaults, field)))
    end)
  end

  @spec validate_monitoring(term()) :: :ok | {:error, term()}
  def validate_monitoring(nil), do: :ok

  def validate_monitoring(config) when is_map(config),
    do: validate(config, @fields ++ [:probe_interval_ms, :lag_alert_threshold_blocks], false)

  def validate_monitoring(_), do: {:error, :invalid_monitoring}

  @spec validate_overrides(term()) :: :ok | {:error, term()}
  def validate_overrides(nil), do: :ok

  def validate_overrides(config) when is_map(config),
    do: validate(config, override_fields(), true)

  def validate_overrides(_), do: {:error, :invalid_observation_overrides}

  defp validate(config, allowed, sparse?) do
    config = if is_struct(config), do: Map.from_struct(config), else: config

    Enum.reduce_while(config, :ok, fn {key, val}, :ok ->
      field = Enum.find(allowed, &(to_string(&1) == to_string(key)))

      valid? =
        cond do
          is_nil(field) ->
            false

          is_nil(val) ->
            not sparse?

          field in @booleans ->
            is_boolean(val)

          field == :evidence_freshness_ms ->
            is_integer(val) and val >= 1_000 and val <= @max_interval_ms

          field == :lag_alert_threshold_blocks ->
            is_integer(val) and val >= 0

          field == :probe_interval_ms ->
            is_integer(val) and val > 0 and val <= @max_interval_ms

          true ->
            is_integer(val) and (val == 0 or val >= 1_000) and val <= @max_interval_ms
        end

      if valid?, do: {:cont, :ok}, else: {:halt, {:error, {:invalid_observation_setting, key}}}
    end)
  end

  defp resolve_value(overrides, monitoring, key, fallback),
    do: value(overrides, key, value(monitoring, key, fallback))

  defp value(map, key, fallback) do
    case get(map, key) do
      nil -> fallback
      val -> val
    end
  end

  defp get(map, key, default \\ nil)

  defp get(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_, _, default), do: default
end
