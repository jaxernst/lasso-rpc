defmodule Lasso.Config.FileSchema do
  @moduledoc "Validates YAML fields before conversion to runtime configuration."

  alias Lasso.Config.ChainConfig

  @metadata %{
    "name" => :string,
    "slug" => :slug,
    "logo" => :string,
    "rps_limit" => :positive,
    "default_rps_limit" => :positive,
    "burst_limit" => :positive,
    "default_burst_limit" => :positive,
    "unlisted" => :boolean
  }
  @failover %{
    "max_backfill_blocks" => :nonnegative,
    "backfill_timeout_ms" => :positive,
    "backfill_timeout" => :positive
  }
  @monitoring %{
    "probe_interval_ms" => :positive,
    "lag_alert_threshold_blocks" => :nonnegative,
    "lag_threshold_blocks" => :nonnegative,
    "subscribe_new_heads" => :boolean,
    "new_heads_staleness_threshold_ms" => :positive
  }
  @capabilities %{
    "unsupported_categories" => {:list, :string},
    "unsupported_methods" => {:list, :string},
    "limits" => %{
      "max_block_range" => :nonnegative,
      "max_block_age" => :nonnegative,
      "block_age_methods" => {:list, :string}
    },
    "error_rules" =>
      {:list,
       %{
         "code" => :integer,
         "message_contains" => :strings,
         "category" => :string
       }}
  }
  @provider %{
    "id" => :slug,
    "name" => :string,
    "priority" => :nonnegative,
    "url" => :http_url,
    "ws_url" => :ws_url,
    "subscribe_new_heads" => :boolean,
    "archival" => :boolean,
    "sharing_mode" => {:enum, ["auto", "isolated"]},
    "api_key" => :secret,
    "headers" => :headers,
    "auth_headers" => :headers,
    "capabilities" => @capabilities
  }
  @chain %{
    "chain_id" => :positive,
    "name" => :string,
    "url_aliases" => {:list, :string},
    "aliases" => {:list, :string},
    "block_time_ms" => :positive,
    "head_policy" => {:enum, ["off", "local", "global"]},
    "providers" => {:list, @provider},
    "monitoring" => @monitoring,
    "selection" => %{"max_lag_blocks" => :nonnegative, "archival_threshold" => :nonnegative},
    "websocket" => %{
      "subscribe_new_heads" => :boolean,
      "new_heads_timeout_ms" => :positive,
      "failover" => @failover
    },
    "failover" => @failover,
    "ui-topology" => %{
      "color" => :color,
      "size" => {:enum, ["sm", "md", "lg", "xl"]}
    }
  }

  @spec validate_metadata!(term(), :frontmatter | :legacy) :: :ok
  def validate_metadata!(meta, format \\ :frontmatter) do
    validate!(meta, @metadata, "profile")
    if format == :frontmatter, do: require_keys!(meta, ["name", "slug"], "profile")
    reject_pair!(meta, "rps_limit", "default_rps_limit", "profile")
    reject_pair!(meta, "burst_limit", "default_burst_limit", "profile")
    :ok
  end

  @spec validate_legacy!(term()) :: :ok
  def validate_legacy!(body) when is_map(body) do
    validate_metadata!(Map.drop(body, ["chains"]), :legacy)
  end

  def validate_legacy!(_body), do: invalid!("profile", "expected a mapping")

  @spec validate_body!(term()) :: :ok
  def validate_body!(body) do
    unless is_map(body) and Map.keys(body) == ["chains"],
      do: invalid!("profile body", "expected only the chains mapping")

    :ok
  end

  @spec validate_chains!(map()) :: :ok
  def validate_chains!(chains) do
    Enum.each(chains, fn {name, chain} ->
      path = "chains.#{name}"
      validate!(name, :slug, "chain key")
      validate!(chain, @chain, path)
      require_keys!(chain, ["chain_id", "providers"], path)
      reject_pair!(chain, "url_aliases", "aliases", path)
      monitoring = chain["monitoring"] || %{}
      reject_pair!(monitoring, "lag_alert_threshold_blocks", "lag_threshold_blocks", path)

      if chain["websocket"] &&
           (chain["failover"] || Map.has_key?(monitoring, "subscribe_new_heads") ||
              Map.has_key?(monitoring, "new_heads_staleness_threshold_ms")),
         do: invalid!(path, "use websocket settings without legacy monitoring/failover settings")

      for failover <- [chain["failover"], get_in(chain, ["websocket", "failover"])],
          is_map(failover),
          do: reject_pair!(failover, "backfill_timeout_ms", "backfill_timeout", path)

      providers = chain["providers"]
      ids = Enum.map(providers, & &1["id"])
      if length(ids) != length(Enum.uniq(ids)), do: invalid!(path, "duplicate provider IDs")

      Enum.each(providers, fn provider ->
        provider_path = path <> ".providers.#{provider["id"]}"
        require_keys!(provider, ["id"], provider_path)

        unless provider["url"] || provider["ws_url"],
          do: invalid!(provider_path, "requires url or ws_url")
      end)
    end)

    :ok
  end

  defp validate!(value, schema, path) when is_map(schema) and is_map(value) do
    Enum.each(value, fn {key, field} ->
      case Map.fetch(schema, key) do
        {:ok, type} -> validate!(field, type, path <> ".#{key}")
        :error -> invalid!(path <> ".#{key}", "unsupported field")
      end
    end)
  end

  defp validate!(value, {:list, type}, path) when is_list(value),
    do: Enum.each(value, &validate!(&1, type, path))

  defp validate!(value, {:enum, values}, path) do
    unless value in values, do: invalid!(path, "unsupported value")
  end

  defp validate!(value, :positive, _) when is_integer(value) and value > 0, do: :ok
  defp validate!(value, :nonnegative, _) when is_integer(value) and value >= 0, do: :ok
  defp validate!(value, :integer, _) when is_integer(value), do: :ok
  defp validate!(value, :boolean, _) when is_boolean(value), do: :ok
  defp validate!(value, :string, _) when is_binary(value) and byte_size(value) > 0, do: :ok

  defp validate!(value, :strings, path) when is_list(value),
    do: validate!(value, {:list, :string}, path)

  defp validate!(value, :strings, path), do: validate!(value, :string, path)

  defp validate!(value, :slug, path) when is_binary(value) do
    unless Regex.match?(~r/^[a-zA-Z0-9][a-zA-Z0-9_-]*$/, value),
      do: invalid!(path, "expected a URL-safe identifier")
  end

  defp validate!(value, :color, path) when is_binary(value) do
    unless Regex.match?(~r/^#[0-9a-fA-F]{6}$/, value), do: invalid!(path, "expected #RRGGBB")
  end

  defp validate!(value, :secret, path) when is_binary(value) do
    resolved = ChainConfig.substitute_env_vars(value)

    if resolved == "" or ChainConfig.has_unresolved_placeholders?(resolved),
      do: invalid!(path, "empty value or unresolved environment variable")
  end

  defp validate!(value, type, path) when type in [:http_url, :ws_url] and is_binary(value) do
    validate!(value, :secret, path)
    uri = value |> ChainConfig.substitute_env_vars() |> URI.parse()
    schemes = if type == :http_url, do: ["http", "https"], else: ["ws", "wss"]

    unless uri.scheme in schemes and is_binary(uri.host) and uri.host != "",
      do: invalid!(path, "invalid endpoint URL scheme or host")
  end

  defp validate!(value, :headers, path) when is_map(value) do
    Enum.each(value, fn {key, field} ->
      validate!(key, :string, path)
      validate!(field, :secret, path <> ".#{key}")
    end)
  end

  defp validate!(_value, _type, path), do: invalid!(path, "invalid value type or range")

  defp require_keys!(value, keys, path) do
    Enum.each(keys, fn key ->
      unless Map.has_key?(value, key), do: invalid!(path <> ".#{key}", "required field")
    end)
  end

  defp reject_pair!(value, key, legacy, path) do
    if Map.has_key?(value, key) and Map.has_key?(value, legacy),
      do: invalid!(path, "specify only one of #{key} and #{legacy}")
  end

  defp invalid!(path, reason), do: throw({:invalid_profile_config, path, reason})
end
