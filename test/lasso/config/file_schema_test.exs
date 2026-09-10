defmodule Lasso.Config.FileSchemaTest do
  use ExUnit.Case, async: false

  alias Lasso.Config.Backend.File, as: FileBackend
  alias Lasso.Config.ConfigStore

  setup do
    root = Path.join(System.tmp_dir!(), "lasso-schema-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {:ok, state} = FileBackend.init(profiles_dir: root, legacy_config_path: root <> "/absent")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, backend: state}
  end

  defp write_profile(ctx, body, metadata \\ "name: Public\nslug: public") do
    File.write!(Path.join(ctx.root, "public.yml"), "---\n#{metadata}\n---\n#{body}")
  end

  defp body(provider \\ "url: https://rpc.example.com", chain \\ "") do
    """
    chains:
      local:
        chain_id: 31337
        #{chain}
        providers:
          - id: primary
            #{provider}
    """
  end

  test "block continuity modes survive file loading and reject unknown values", ctx do
    for mode <- ["off", "local", "global"] do
      write_profile(ctx, body("url: https://rpc.example.com", "head_policy: #{mode}"))
      assert {:ok, spec} = FileBackend.load(ctx.backend, "public")
      assert spec.chains["local"].head_policy == mode
    end

    for mode <- ["false", "null", "GLOBAL", "fresh"] do
      write_profile(ctx, body("url: https://rpc.example.com", "head_policy: #{mode}"))
      assert {:error, {:invalid_profile_config, _, _}} = FileBackend.load(ctx.backend, "public")
    end
  end

  test "shipped profiles pass strict validation", _ctx do
    assert {:ok, profiles} = FileBackend.load_all(%{profiles_dir: "config/profiles"})
    assert Enum.any?(profiles, &(&1.slug == "public"))
  end

  test "rejects unsupported routing and capability controls and malformed types", ctx do
    for yaml <- [
          body() <> "routing:\n  default_strategy: fastest\n",
          body("url: https://rpc.example.com\n        archival: nope"),
          body("url: https://rpc.example.com\n        credentials: secret"),
          body(
            "url: https://rpc.example.com\n        capabilities:\n          methods: [eth_call]"
          ),
          body("url: https://rpc.example.com", "monitoring:\n      probe_interval_ms: 0"),
          body("url: https://rpc.example.com", "selection:\n      max_lag_block: 2")
        ] do
      write_profile(ctx, yaml)
      assert {:error, {:invalid_profile_config, _, _}} = FileBackend.load(ctx.backend, "public")
    end
  end

  test "validates tester limits and duplicate provider IDs", ctx do
    for limit <- ["0", "-1", "false", "\"100\""] do
      write_profile(ctx, body(), "name: Public\nslug: public\nrps_limit: #{limit}")

      assert {:error, {:invalid_profile_config, "profile.rps_limit", _}} =
               FileBackend.load(ctx.backend, "public")
    end

    write_profile(ctx, body() <> "      - id: primary\n        url: https://other.example.com\n")

    assert {:error, {:invalid_profile_config, _, "duplicate provider IDs"}} =
             FileBackend.load(ctx.backend, "public")
  end

  test "provider defaults, WS-only endpoints, false flags, and empty monitoring are honored",
       ctx do
    write_profile(
      ctx,
      body("ws_url: wss://rpc.example.com\n        archival: false", "monitoring: {}")
    )

    assert {:ok, profile} = FileBackend.load(ctx.backend, "public")
    chain = profile.chains["local"]
    assert chain.monitoring.probe_interval_ms == 12_000
    assert [provider] = chain.providers
    assert provider.name == "primary"
    refute provider.archival
    assert provider.url == nil
  end

  test "header credentials are substituted and unresolved values never activate on reload", ctx do
    env = "LASSO_SCHEMA_TEST_SECRET"
    System.put_env(env, "resolved-token")
    on_exit(fn -> System.delete_env(env) end)

    write_profile(
      ctx,
      body(
        "url: https://rpc.example.com\n        auth_headers:\n          authorization: Bearer ${#{env}}"
      )
    )

    assert {:ok, profile} = FileBackend.load(ctx.backend, "public")

    assert hd(profile.chains["local"].providers).auth_headers["authorization"] ==
             "Bearer resolved-token"

    System.delete_env(env)
    previous_state = :sys.get_state(ConfigStore)
    previous_profile = ConfigStore.get_profile("public")
    generation = ConfigStore.route_generation()
    on_exit(fn -> :sys.replace_state(ConfigStore, fn _ -> previous_state end) end)

    :sys.replace_state(ConfigStore, fn state ->
      %{state | backend_module: FileBackend, backend_state: ctx.backend}
    end)

    assert {:error, {_, {:invalid_profile_config, path, reason}}} = ConfigStore.reload()
    assert path =~ "auth_headers.authorization"
    refute reason =~ "resolved-token"
    assert ConfigStore.route_generation() == generation
    assert ConfigStore.get_profile("public") == previous_profile
    assert Process.alive?(Process.whereis(ConfigStore))
  end

  test "frontmatter supports CRLF line endings", ctx do
    write_profile(ctx, body())
    path = Path.join(ctx.root, "public.yml")
    File.write!(path, File.read!(path) |> String.replace("\n", "\r\n"))
    assert {:ok, _} = FileBackend.load(ctx.backend, "public")
  end

  test "an empty profile directory cannot replace the running configuration", ctx do
    original = :sys.get_state(ConfigStore)
    generation = ConfigStore.route_generation()
    on_exit(fn -> :sys.replace_state(ConfigStore, fn _ -> original end) end)

    :sys.replace_state(ConfigStore, fn state ->
      %{state | backend_module: FileBackend, backend_state: ctx.backend}
    end)

    assert {:error, :public_profile_missing} = ConfigStore.reload()
    assert ConfigStore.route_generation() == generation
    assert {:ok, _} = ConfigStore.get_profile("public")
  end
end
