defmodule Lasso.Config.ChainstackTemplateTest do
  @moduledoc """
  Loads the Chainstack profile template through the file backend and verifies
  the multichain token substitution and provider capabilities it declares.
  """
  use ExUnit.Case, async: false

  alias Lasso.Config.Backend.File, as: FileBackend
  alias Lasso.RPC.Providers.Capabilities

  @examples_dir "config/examples"
  @token_var "CHAINSTACK_MULTICHAIN_TOKEN"
  @token "mt_lasso_template_test"

  @stateful_filter_methods [
    "eth_newFilter",
    "eth_newBlockFilter",
    "eth_newPendingTransactionFilter",
    "eth_getFilterChanges",
    "eth_getFilterLogs",
    "eth_uninstallFilter"
  ]

  @expected_hosts %{
    "ethereum" => {1, "ethereum-mainnet.core.chainstack.com"},
    "base" => {8453, "base-mainnet.core.chainstack.com"},
    "arbitrum" => {42_161, "arbitrum-mainnet.core.chainstack.com"}
  }

  setup do
    previous = System.get_env(@token_var)

    on_exit(fn ->
      if previous,
        do: System.put_env(@token_var, previous),
        else: System.delete_env(@token_var)
    end)

    :ok
  end

  test "every chain routes to its Global Node host with the shared multichain token" do
    profile = load_template!(@token)

    assert profile.slug == "chainstack"
    assert Map.keys(profile.chains) |> Enum.sort() == Map.keys(@expected_hosts) |> Enum.sort()

    for {chain, {chain_id, host}} <- @expected_hosts do
      chain_config = profile.chains[chain]
      assert chain_config.chain_id == chain_id
      assert [provider] = chain_config.providers

      assert provider.id == "#{chain}_chainstack"
      assert provider.url == "https://#{host}/#{@token}"
      assert provider.ws_url == "wss://#{host}/#{@token}"
      assert provider.archival == false
    end
  end

  test "capabilities pass boot validation and enforce Chainstack limits" do
    profile = load_template!(@token)

    for {_chain, chain_config} <- profile.chains, provider <- chain_config.providers do
      caps = provider.capabilities
      assert :ok = Capabilities.validate!(provider.id, caps)

      for method <- @stateful_filter_methods do
        assert {:error, :method_unsupported} = Capabilities.supports_method?(method, caps)
      end

      assert :ok = Capabilities.supports_method?("eth_getLogs", caps)
      assert :ok = Capabilities.supports_method?("debug_traceTransaction", caps)

      within = [%{"fromBlock" => "0x1000", "toBlock" => "0x1064"}]
      beyond = [%{"fromBlock" => "0x1000", "toBlock" => "0x1065"}]

      assert :ok = Capabilities.validate_params("eth_getLogs", within, caps, %{})

      assert {:error, {:param_limit, "max 100 block range (got 101)"}} =
               Capabilities.validate_params("eth_getLogs", beyond, caps, %{})
    end
  end

  test "disabled tracer errors classify as capability violations" do
    profile = load_template!(@token)

    message =
      "Custom tracers are disabled by default. See https://docs.chainstack.com/docs/limits for details."

    for {_chain, chain_config} <- profile.chains, provider <- chain_config.providers do
      assert {:ok, :capability_violation} =
               Capabilities.classify_error(-32_612, message, provider.capabilities)
    end
  end

  test "an unset multichain token rejects the profile without exposing a value" do
    System.delete_env(@token_var)

    assert {:error, {:invalid_profile_config, path, detail}} = load_template()
    assert path =~ ~r/^chains\.\w+\.providers\.url$/
    assert detail =~ "unresolved environment variable"
    refute detail =~ "mt_"
  end

  defp load_template!(token) do
    System.put_env(@token_var, token)
    {:ok, profile} = load_template()
    profile
  end

  defp load_template do
    {:ok, state} = FileBackend.init(profiles_dir: @examples_dir)
    FileBackend.load(state, "chainstack")
  end
end
