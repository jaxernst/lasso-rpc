defmodule Lasso.Config.ValidationDetailTest do
  use ExUnit.Case, async: false

  alias Lasso.Config.ConfigStore
  alias Lasso.Operator.Commands

  @moduletag :tmp_dir

  test "operator commands and boot loader identify broken fields without credentials", %{
    tmp_dir: dir
  } do
    previous = Application.get_env(:lasso, :backend_config)

    Application.put_env(:lasso, :backend_config,
      backend: Lasso.Config.Backend.File,
      config: [profiles_dir: dir]
    )

    on_exit(fn -> Application.put_env(:lasso, :backend_config, previous) end)

    for {provider, field, expected} <- [
          {"id: primary", "url", "endpoint string"},
          {"id: primary\n        url: 123", "url", "HTTP URL string"},
          {"id: primary\n        url: https://rpc.example.test\n        priority: secret",
           "priority", "nonnegative integer"},
          {"url: 123", "url", "HTTP URL string"},
          {"id: primary\n        url: https://rpc.example.test\n        auth_headers: [secret]",
           "auth_headers", "mapping"},
          {"id: primary\n        url: https://user:password@rpc.example.test/private?token=secret\n        auth_headers:\n          Authorization: secret",
           "auth_headers", "exclusively"}
        ] do
      File.write!(
        Path.join(dir, "public.yml"),
        "---\nname: Public\nslug: public\n---\nchains:\n  local:\n    chain_id: 31337\n    providers:\n      - #{provider}\n"
      )

      assert {:error, error} = Lasso.Config.Backend.File.load_all(%{profiles_dir: dir})

      messages =
        [inspect(error)] ++
          Enum.map([&Commands.check_config!/0, &Commands.reload!/0], fn fun ->
            exception = assert_raise RuntimeError, fun
            Exception.message(exception)
          end)

      for message <- messages do
        assert message =~ "profile.public.chains.local.providers"
        assert message =~ if(String.starts_with?(provider, "id:"), do: "primary", else: "[1]")
        assert message =~ field
        assert message =~ expected
        for secret <- ["password", "private", "token", "secret"], do: refute(message =~ secret)
      end
    end
  end

  test "block age methods require a readable block number", %{tmp_dir: dir} do
    for method <- ["eth_getLogs", "eth_call"] do
      File.write!(Path.join(dir, "public.yml"), """
      ---
      name: Public
      slug: public
      ---
      chains:
        local:
          chain_id: 31337
          providers:
            - id: primary
              url: https://rpc.example.test
              capabilities:
                limits:
                  max_block_age: 1000
                  block_age_methods: [#{method}]
      """)

      case method do
        "eth_getLogs" ->
          assert {:error, {_, {:invalid_profile_config, path, reason}}} =
                   Commands.check_config(dir)

          assert path ==
                   "profile.public.chains.local.providers.primary.capabilities.limits.block_age_methods[1]"

          assert reason =~ "eth_getLogs"
          assert reason =~ "max_block_age"
          assert reason =~ "remove it from block_age_methods"
          assert reason =~ "max_block_range for log queries"

        "eth_call" ->
          assert {:ok, _} = Commands.check_config(dir)
      end
    end
  end

  test "unknown strategy identifies the chain and supported fields", %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, "public.yml"),
      "---\nname: Public\nslug: public\n---\nchains:\n  local:\n    chain_id: 31337\n    strategy: unknown\n    providers: []\n"
    )

    assert {:error, {_, {:invalid_profile_config, path, reason}}} =
             Commands.check_config(dir)

    assert path == "profile.public.chains.local.strategy"
    assert reason =~ "unsupported field; expected one of"
    assert reason =~ "selection"
  end

  test "runtime registration returns the same safe field diagnostic" do
    chain = System.unique_integer([:positive])
    assert :ok = ConfigStore.register_chain_runtime("public", chain, %{providers: []})
    on_exit(fn -> ConfigStore.unregister_chain_runtime("public", chain) end)

    assert {:error, {:invalid_profile_config, path, reason}} =
             ConfigStore.register_provider_runtime("public", chain, %{id: "primary", url: 123})

    assert path == "profile.public.chains.#{chain}.providers.primary.url"
    assert reason =~ "expected HTTP URL string"
    assert reason =~ "found integer"
    assert {:ok, %{providers: []}} = ConfigStore.get_chain("public", chain)
  end
end
