defmodule Lasso.Config.FileBackendCompatibilityTest do
  use ExUnit.Case, async: true

  alias Lasso.Config.Backend.File, as: FileBackend

  setup do
    root = Path.join(System.tmp_dir!(), "lasso-file-compat-#{System.unique_integer([:positive])}")
    profiles_dir = Path.join(root, "profiles")
    legacy_path = Path.join(root, "chains.yml")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, root: root, profiles_dir: profiles_dir, legacy_path: legacy_path}
  end

  test "legacy chains.yml auto-migrates without losing routing fields", context do
    File.write!(context.legacy_path, """
    chains:
      ethereum:
        chain_id: 1
        name: Ethereum Mainnet
        block_time_ms: 12000
        selection:
          max_lag_blocks: 2
          archival_threshold: 256
        monitoring:
          probe_interval_ms: 15000
          lag_alert_threshold_blocks: 4
        websocket:
          subscribe_new_heads: false
          new_heads_timeout_ms: 45000
          failover:
            max_backfill_blocks: 55
            backfill_timeout_ms: 9000
        providers:
          - id: primary
            name: Primary
            url: https://rpc.example.com
            ws_url: wss://rpc.example.com/ws
            priority: 7
            archival: false
            sharing_mode: isolated
            capabilities:
              methods: [eth_blockNumber, eth_chainId]
    """)

    assert {:ok, state} =
             FileBackend.init(
               profiles_dir: context.profiles_dir,
               legacy_config_path: context.legacy_path
             )

    assert File.exists?(Path.join(context.profiles_dir, "public.yml"))
    assert {:ok, [profile]} = FileBackend.load_all(state)
    assert profile.profile_id == "public"
    assert profile.slug == "public"

    assert %{"ethereum" => chain} = profile.chains
    assert chain.chain_id == 1
    assert chain.name == "Ethereum Mainnet"
    assert chain.display_name == "Ethereum Mainnet"
    assert chain.url_aliases == ["ethereum"]
    assert chain.block_time_ms == 12_000
    assert chain.selection.max_lag_blocks == 2
    assert chain.selection.archival_threshold == 256
    assert chain.monitoring.probe_interval_ms == 15_000
    assert chain.websocket.subscribe_new_heads == false
    assert chain.websocket.failover.max_backfill_blocks == 55

    assert [provider] = chain.providers
    assert provider.id == "primary"
    assert provider.priority == 7
    assert provider.archival == false
    assert provider.sharing_mode == :isolated
    assert provider.capabilities.methods == ["eth_blockNumber", "eth_chainId"]
  end

  test "frontmatter profile retains legacy aliases and provider authentication", context do
    File.mkdir_p!(context.profiles_dir)

    File.write!(Path.join(context.profiles_dir, "custom.yml"), """
    ---
    name: Custom
    slug: custom
    rps_limit: 25
    burst_limit: 50
    ---
    chains:
      custom-chain:
        chain_id: 31337
        name: Custom Chain
        url_aliases: [custom-chain, local]
        providers:
          - id: authenticated
            name: Authenticated
            url: https://rpc.example.com
            api_key: secret-token
            headers:
              x-network: local
            auth_headers:
              authorization: Basic explicit
      unnamed:
        chain_id: 31338
        providers: []
    """)

    assert {:ok, state} =
             FileBackend.init(
               profiles_dir: context.profiles_dir,
               legacy_config_path: context.legacy_path
             )

    assert {:ok, profile} = FileBackend.load(state, "custom")
    assert profile.profile_id == "custom"
    assert profile.rps_limit == 25
    assert profile.burst_limit == 50

    chain = profile.chains["custom-chain"]
    assert chain.url_aliases == ["custom-chain", "local"]
    assert [provider] = chain.providers
    assert provider.api_key == "secret-token"
    assert provider.headers == %{"x-network" => "local"}
    assert provider.auth_headers == %{"authorization" => "Basic explicit"}
    assert profile.chains["unnamed"].name == "unnamed"
    assert profile.chains["unnamed"].display_name == "unnamed"
  end
end
