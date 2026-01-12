defmodule Lasso.Config.Backend.File do
  @moduledoc """
  File-based configuration backend that loads profiles from YAML files.

  Profiles are stored as individual YAML files in the configured profiles directory.
  Each file contains profile metadata (frontmatter) followed by chain configurations.

  ## Profile YAML Format

      ---
      name: Production
      slug: production
      type: standard
      default_rps_limit: 500
      default_burst_limit: 1000
      ---
      chains:
        ethereum:
          chain_id: 1
          providers:
            - id: "alchemy"
              url: "https://eth-mainnet.g.alchemy.com/v2/..."
              priority: 1

  ## Auto-Migration

  If the profiles directory is empty but `config/chains.yml` exists, the backend
  will automatically generate `config/profiles/default.yml` from it during startup.
  This provides seamless migration for existing deployments.

  ## File Discovery Rules

  - Load all `*.yml` files in `profiles_dir`
  - Skip files starting with `.` or `_` (backups, templates)
  - Profile slug must match filename (e.g., `premium.yml` must have `slug: premium`)
  - **Fail-fast**: First invalid file fails entire load
  """

  @behaviour Lasso.Config.Backend

  require Logger

  alias Lasso.Config.ChainConfig

  @type state :: %{
          profiles_dir: String.t(),
          legacy_config_path: String.t()
        }

  @impl true
  def init(config) do
    profiles_dir = Keyword.get(config, :profiles_dir, "config/profiles")
    legacy_config_path = Keyword.get(config, :legacy_config_path, "config/chains.yml")

    state = %{
      profiles_dir: profiles_dir,
      legacy_config_path: legacy_config_path
    }

    # Ensure profiles directory exists
    File.mkdir_p!(profiles_dir)

    # Check for auto-migration opportunity
    with :ok <- maybe_auto_migrate(state) do
      {:ok, state}
    end
  end

  @impl true
  def load_all(%{profiles_dir: profiles_dir} = state) do
    case list_profile_files(profiles_dir) do
      [] ->
        # No profiles found - check if we need to migrate
        case maybe_auto_migrate(state) do
          :ok ->
            # Retry after migration
            load_all_profiles(profiles_dir)

          {:error, _} = error ->
            error
        end

      files ->
        load_all_profiles_from_files(files)
    end
  end

  @impl true
  def load(%{profiles_dir: profiles_dir}, slug) do
    path = Path.join(profiles_dir, "#{slug}.yml")

    if File.exists?(path) do
      load_profile_file(path)
    else
      {:error, :not_found}
    end
  end

  @impl true
  def save(%{profiles_dir: profiles_dir}, slug, yaml) do
    path = Path.join(profiles_dir, "#{slug}.yml")

    case File.write(path, yaml) do
      :ok ->
        Logger.info("Saved profile #{slug} to #{path}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to save profile #{slug}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def delete(%{profiles_dir: profiles_dir}, slug) do
    path = Path.join(profiles_dir, "#{slug}.yml")

    case File.rm(path) do
      :ok ->
        Logger.info("Deleted profile #{slug} from #{path}")
        :ok

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        Logger.error("Failed to delete profile #{slug}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Private functions

  defp list_profile_files(profiles_dir) do
    profiles_dir
    |> Path.join("*.yml")
    |> Path.wildcard()
    |> Enum.reject(fn path ->
      filename = Path.basename(path)
      String.starts_with?(filename, ".") or String.starts_with?(filename, "_")
    end)
    |> Enum.sort()
  end

  defp load_all_profiles(profiles_dir) do
    profiles_dir
    |> list_profile_files()
    |> load_all_profiles_from_files()
  end

  defp load_all_profiles_from_files(files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      case load_profile_file(file) do
        {:ok, spec} ->
          {:cont, {:ok, [spec | acc]}}

        {:error, reason} ->
          Logger.error("Failed to load profile #{file}: #{inspect(reason)}")
          {:halt, {:error, {file, reason}}}
      end
    end)
    |> case do
      {:ok, profiles} -> {:ok, Enum.reverse(profiles)}
      error -> error
    end
  end

  defp load_profile_file(path) do
    with {:ok, content} <- File.read(path),
         {:ok, spec} <- parse_profile_yaml(content),
         :ok <- validate_slug_matches_filename(spec, path) do
      {:ok, spec}
    end
  end

  defp parse_profile_yaml(content) do
    # Check if content uses frontmatter format (starts with ---)
    if String.starts_with?(String.trim(content), "---") do
      parse_frontmatter_format(content)
    else
      # Legacy format - just chains
      parse_legacy_format(content)
    end
  end

  defp parse_frontmatter_format(content) do
    # Split on --- markers
    # Format: ---\nmeta\n---\nchains
    case String.split(content, ~r/\n---\n/, parts: 2) do
      [frontmatter_with_marker, chains_yaml] ->
        # Remove leading --- from frontmatter
        frontmatter = String.replace_prefix(String.trim(frontmatter_with_marker), "---", "")

        with {:ok, meta} <- YamlElixir.read_from_string(frontmatter),
             {:ok, chains_data} <- YamlElixir.read_from_string(chains_yaml),
             {:ok, chains} <- parse_chains_data(chains_data) do
          {:ok,
           %{
             slug: meta["slug"],
             name: meta["name"],
             type: parse_profile_type(meta["type"]),
             default_rps_limit: meta["default_rps_limit"] || 100,
             default_burst_limit: meta["default_burst_limit"] || 500,
             chains: chains
           }}
        end

      _ ->
        {:error, :invalid_frontmatter_format}
    end
  end

  defp parse_legacy_format(content) do
    # Legacy format: just chains (from chains.yml migration)
    with {:ok, yaml_data} <- YamlElixir.read_from_string(content),
         {:ok, chains} <- parse_chains_data(yaml_data) do
      # Extract slug from chains or use "default"
      slug = yaml_data["slug"] || "default"

      {:ok,
       %{
         slug: slug,
         name: yaml_data["name"] || "Default Profile",
         type: :standard,
         default_rps_limit: yaml_data["default_rps_limit"] || 100,
         default_burst_limit: yaml_data["default_burst_limit"] || 500,
         chains: chains
       }}
    end
  end

  defp parse_chains_data(%{"chains" => chains_data}) when is_map(chains_data) do
    chains =
      Enum.map(chains_data, fn {chain_name, chain_data} ->
        {chain_name, parse_chain_config(chain_name, chain_data)}
      end)
      |> Enum.into(%{})

    {:ok, chains}
  end

  defp parse_chains_data(_), do: {:error, :invalid_chains_format}

  defp parse_chain_config(chain_name, chain_data) do
    %ChainConfig{
      chain_id: chain_data["chain_id"],
      name: chain_data["name"] || chain_name,
      providers: parse_providers(chain_data["providers"] || []),
      selection: parse_selection(chain_data["selection"]),
      monitoring: parse_monitoring(chain_data["monitoring"]),
      websocket: parse_websocket(chain_data["websocket"], chain_data),
      topology: parse_topology(chain_data["ui-topology"])
    }
  end

  defp parse_providers(providers_data) do
    Enum.map(providers_data, fn provider_data ->
      %ChainConfig.Provider{
        id: provider_data["id"],
        name: provider_data["name"],
        priority: provider_data["priority"] || 100,
        type: provider_data["type"] || "public",
        url: ChainConfig.substitute_env_vars(provider_data["url"]),
        ws_url: ChainConfig.substitute_env_vars(provider_data["ws_url"]),
        api_key_required: provider_data["api_key_required"] || false,
        region: provider_data["region"],
        adapter_config: parse_adapter_config(provider_data["adapter_config"]),
        subscribe_new_heads: provider_data["subscribe_new_heads"]
      }
    end)
  end

  defp parse_adapter_config(nil), do: nil

  defp parse_adapter_config(config_map) when is_map(config_map) do
    config_map
    |> Enum.map(fn {key, value} ->
      atom_key = if is_binary(key), do: safe_to_existing_atom(key), else: key
      {atom_key, value}
    end)
    |> Enum.into(%{})
  end

  defp parse_adapter_config(_), do: nil

  defp safe_to_existing_atom(string) do
    String.to_existing_atom(string)
  rescue
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    ArgumentError -> String.to_atom(string)
  end

  # Parse websocket config, with backwards compatibility for old structure
  # Old structure had monitoring.subscribe_new_heads, monitoring.new_heads_staleness_threshold_ms
  # and a separate failover section
  defp parse_websocket(nil, chain_data) do
    # Check for legacy config locations
    monitoring = chain_data["monitoring"] || %{}
    failover = chain_data["failover"] || %{}

    %ChainConfig.Websocket{
      subscribe_new_heads: Map.get(monitoring, "subscribe_new_heads", true),
      new_heads_timeout_ms: Map.get(monitoring, "new_heads_staleness_threshold_ms", 42_000),
      failover: parse_websocket_failover(failover)
    }
  end

  defp parse_websocket(websocket_data, _chain_data) when is_map(websocket_data) do
    %ChainConfig.Websocket{
      subscribe_new_heads: Map.get(websocket_data, "subscribe_new_heads", true),
      new_heads_timeout_ms: Map.get(websocket_data, "new_heads_timeout_ms", 42_000),
      failover: parse_websocket_failover(websocket_data["failover"])
    }
  end

  defp parse_websocket_failover(nil), do: %ChainConfig.WebsocketFailover{}

  defp parse_websocket_failover(failover_data) when is_map(failover_data) do
    %ChainConfig.WebsocketFailover{
      max_backfill_blocks: Map.get(failover_data, "max_backfill_blocks", 100),
      backfill_timeout_ms:
        Map.get(failover_data, "backfill_timeout_ms") ||
          Map.get(failover_data, "backfill_timeout", 30_000)
    }
  end

  defp parse_selection(nil), do: nil

  defp parse_selection(selection_data) when is_map(selection_data) do
    %ChainConfig.Selection{
      max_lag_blocks: Map.get(selection_data, "max_lag_blocks")
    }
  end

  defp parse_monitoring(nil), do: %ChainConfig.Monitoring{}

  defp parse_monitoring(monitoring_data) when is_map(monitoring_data) do
    %ChainConfig.Monitoring{
      probe_interval_ms: Map.get(monitoring_data, "probe_interval_ms", 12_000),
      # Support both new and legacy field names
      lag_alert_threshold_blocks:
        Map.get(monitoring_data, "lag_alert_threshold_blocks") ||
          Map.get(monitoring_data, "lag_threshold_blocks", 3)
    }
  end

  defp parse_topology(nil), do: %ChainConfig.Topology{}

  defp parse_topology(topology_data) when is_map(topology_data) do
    %ChainConfig.Topology{
      category: parse_topology_category(Map.get(topology_data, "category")),
      parent: Map.get(topology_data, "parent"),
      network: parse_topology_network(Map.get(topology_data, "network")),
      color: Map.get(topology_data, "color", "#6B7280"),
      size: parse_topology_size(Map.get(topology_data, "size"))
    }
  end

  defp parse_topology_category("l1"), do: :l1
  defp parse_topology_category("l2"), do: :l2
  defp parse_topology_category("sidechain"), do: :sidechain
  defp parse_topology_category(_), do: :other

  defp parse_topology_network("mainnet"), do: :mainnet
  defp parse_topology_network("sepolia"), do: :sepolia
  defp parse_topology_network("goerli"), do: :goerli
  defp parse_topology_network("holesky"), do: :holesky
  defp parse_topology_network(_), do: :mainnet

  defp parse_topology_size("sm"), do: :sm
  defp parse_topology_size("md"), do: :md
  defp parse_topology_size("lg"), do: :lg
  defp parse_topology_size("xl"), do: :xl
  defp parse_topology_size(_), do: :md

  defp parse_profile_type("free"), do: :free
  defp parse_profile_type("standard"), do: :standard
  defp parse_profile_type("premium"), do: :premium
  defp parse_profile_type("byok"), do: :byok
  defp parse_profile_type(_), do: :standard

  defp validate_slug_matches_filename(%{slug: slug}, path) do
    expected_slug = path |> Path.basename(".yml")

    if slug == expected_slug do
      :ok
    else
      {:error, {:slug_mismatch, slug, expected_slug}}
    end
  end

  # Auto-migration from legacy chains.yml to profiles/default.yml
  defp maybe_auto_migrate(%{profiles_dir: profiles_dir, legacy_config_path: legacy_path}) do
    profile_files = list_profile_files(profiles_dir)
    legacy_exists = File.exists?(legacy_path)

    cond do
      # Already have profiles - nothing to migrate
      length(profile_files) > 0 ->
        :ok

      # No profiles and no legacy file - error
      not legacy_exists ->
        Logger.warning(
          "No profiles found in #{profiles_dir} and no legacy config at #{legacy_path}"
        )

        :ok

      # Need to migrate
      true ->
        migrate_legacy_config(legacy_path, profiles_dir)
    end
  end

  defp migrate_legacy_config(legacy_path, profiles_dir) do
    Logger.info("Auto-migrating #{legacy_path} to #{profiles_dir}/default.yml")

    with {:ok, content} <- File.read(legacy_path),
         {:ok, yaml_data} <- YamlElixir.read_from_string(content) do
      # Generate profile YAML with frontmatter
      profile_yaml = generate_profile_yaml(yaml_data)
      target_path = Path.join(profiles_dir, "default.yml")

      case File.write(target_path, profile_yaml) do
        :ok ->
          Logger.info("Successfully migrated legacy config to #{target_path}")
          :ok

        {:error, reason} ->
          Logger.error("Failed to write migrated profile: #{inspect(reason)}")
          {:error, {:migration_failed, reason}}
      end
    else
      {:error, reason} ->
        Logger.error("Failed to read legacy config: #{inspect(reason)}")
        {:error, {:migration_read_failed, reason}}
    end
  end

  defp generate_profile_yaml(yaml_data) do
    # Generate profile YAML with frontmatter format
    """
    ---
    name: Default
    slug: default
    type: standard
    default_rps_limit: 100
    default_burst_limit: 500
    ---
    chains:
    #{generate_chains_yaml(yaml_data["chains"])}
    """
  end

  defp generate_chains_yaml(chains_data) when is_map(chains_data) do
    chains_data
    |> Enum.map_join("\n", fn {chain_name, chain_config} ->
      generate_chain_yaml(chain_name, chain_config)
    end)
  end

  defp generate_chains_yaml(_), do: ""

  defp generate_chain_yaml(chain_name, chain_config) do
    providers_yaml = generate_providers_yaml(chain_config["providers"] || [])

    # Build chain yaml with proper indentation
    chain_yaml = "  #{chain_name}:\n"

    chain_yaml =
      if chain_config["chain_id"],
        do: chain_yaml <> "    chain_id: #{chain_config["chain_id"]}\n",
        else: chain_yaml

    chain_yaml =
      if chain_config["name"],
        do: chain_yaml <> "    name: \"#{chain_config["name"]}\"\n",
        else: chain_yaml

    # Add monitoring config if present
    chain_yaml =
      if chain_config["monitoring"],
        do: chain_yaml <> generate_monitoring_yaml(chain_config["monitoring"]),
        else: chain_yaml

    # Add selection config if present
    chain_yaml =
      if chain_config["selection"],
        do: chain_yaml <> generate_selection_yaml(chain_config["selection"]),
        else: chain_yaml

    # Add websocket config (converting from legacy failover/monitoring fields)
    chain_yaml = chain_yaml <> generate_websocket_yaml(chain_config)

    # Add topology config if present
    chain_yaml =
      if chain_config["ui-topology"],
        do: chain_yaml <> generate_topology_yaml(chain_config["ui-topology"]),
        else: chain_yaml

    # Add providers
    chain_yaml <> "    providers:\n" <> providers_yaml
  end

  defp generate_monitoring_yaml(monitoring) do
    yaml = "    monitoring:\n"

    yaml =
      if monitoring["probe_interval_ms"],
        do: yaml <> "      probe_interval_ms: #{monitoring["probe_interval_ms"]}\n",
        else: yaml

    yaml =
      if monitoring["lag_threshold_blocks"] || monitoring["lag_alert_threshold_blocks"],
        do:
          yaml <>
            "      lag_alert_threshold_blocks: #{monitoring["lag_alert_threshold_blocks"] || monitoring["lag_threshold_blocks"]}\n",
        else: yaml

    yaml
  end

  defp generate_websocket_yaml(chain_config) do
    monitoring = chain_config["monitoring"] || %{}
    failover = chain_config["failover"] || %{}
    websocket = chain_config["websocket"] || %{}

    # Prefer new websocket config, fall back to legacy locations
    subscribe_new_heads =
      websocket["subscribe_new_heads"] || monitoring["subscribe_new_heads"]

    new_heads_timeout_ms =
      websocket["new_heads_timeout_ms"] || monitoring["new_heads_staleness_threshold_ms"]

    max_backfill_blocks =
      (websocket["failover"] || %{})["max_backfill_blocks"] || failover["max_backfill_blocks"]

    backfill_timeout_ms =
      (websocket["failover"] || %{})["backfill_timeout_ms"] ||
        failover["backfill_timeout_ms"] || failover["backfill_timeout"]

    # Only generate if there's something to write
    if subscribe_new_heads || new_heads_timeout_ms || max_backfill_blocks || backfill_timeout_ms do
      yaml = "    websocket:\n"

      yaml =
        if subscribe_new_heads != nil,
          do: yaml <> "      subscribe_new_heads: #{subscribe_new_heads}\n",
          else: yaml

      yaml =
        if new_heads_timeout_ms,
          do: yaml <> "      new_heads_timeout_ms: #{new_heads_timeout_ms}\n",
          else: yaml

      append_failover_yaml(yaml, max_backfill_blocks, backfill_timeout_ms)
    else
      ""
    end
  end

  defp append_failover_yaml(yaml, max_backfill_blocks, backfill_timeout_ms) do
    if max_backfill_blocks || backfill_timeout_ms do
      yaml = yaml <> "      failover:\n"

      yaml =
        if max_backfill_blocks,
          do: yaml <> "        max_backfill_blocks: #{max_backfill_blocks}\n",
          else: yaml

      if backfill_timeout_ms,
        do: yaml <> "        backfill_timeout_ms: #{backfill_timeout_ms}\n",
        else: yaml
    else
      yaml
    end
  end

  defp generate_selection_yaml(selection) do
    yaml = "    selection:\n"

    yaml =
      if selection["max_lag_blocks"],
        do: yaml <> "      max_lag_blocks: #{selection["max_lag_blocks"]}\n",
        else: yaml

    yaml
  end

  defp generate_topology_yaml(topology) do
    yaml = "    ui-topology:\n"

    yaml =
      if topology["category"],
        do: yaml <> "      category: #{topology["category"]}\n",
        else: yaml

    yaml =
      if topology["parent"],
        do: yaml <> "      parent: #{topology["parent"]}\n",
        else: yaml

    yaml =
      if topology["network"],
        do: yaml <> "      network: #{topology["network"]}\n",
        else: yaml

    yaml =
      if topology["color"],
        do: yaml <> "      color: \"#{topology["color"]}\"\n",
        else: yaml

    yaml =
      if topology["size"],
        do: yaml <> "      size: #{topology["size"]}\n",
        else: yaml

    yaml
  end

  defp generate_providers_yaml(providers) do
    providers
    |> Enum.map_join("", &generate_provider_yaml/1)
  end

  defp generate_provider_yaml(provider) do
    yaml = "      - id: \"#{provider["id"]}\"\n"
    yaml = if provider["name"], do: yaml <> "        name: \"#{provider["name"]}\"\n", else: yaml

    yaml =
      if provider["priority"],
        do: yaml <> "        priority: #{provider["priority"]}\n",
        else: yaml

    yaml = if provider["type"], do: yaml <> "        type: \"#{provider["type"]}\"\n", else: yaml
    yaml = if provider["url"], do: yaml <> "        url: \"#{provider["url"]}\"\n", else: yaml

    yaml =
      if provider["ws_url"], do: yaml <> "        ws_url: \"#{provider["ws_url"]}\"\n", else: yaml

    yaml =
      if provider["api_key_required"] != nil,
        do: yaml <> "        api_key_required: #{provider["api_key_required"]}\n",
        else: yaml

    yaml =
      if provider["region"], do: yaml <> "        region: \"#{provider["region"]}\"\n", else: yaml

    yaml =
      if provider["subscribe_new_heads"] != nil,
        do: yaml <> "        subscribe_new_heads: #{provider["subscribe_new_heads"]}\n",
        else: yaml

    yaml
  end
end
