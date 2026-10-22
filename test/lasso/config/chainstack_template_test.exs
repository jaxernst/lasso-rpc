defmodule Lasso.Config.ChainstackTemplateTest do
  @moduledoc """
  Loads the Chainstack profile template through the file backend and verifies
  the multichain token substitution, provider capabilities, and public
  fallbacks it declares.
  """
  use ExUnit.Case, async: false

  alias Lasso.Config.Backend.File, as: FileBackend
  alias Lasso.RPC.Providers.Capabilities

  @examples_dir "config/examples"
  @profiles_dir "config/profiles"
  @token_var "CHAINSTACK_MULTICHAIN_TOKEN"
  @token "mt_lasso_template_test"

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

      provider = chainstack_provider(chain_config)
      assert provider.id == "#{chain}_chainstack"
      assert provider.url == "https://#{host}/#{@token}"
      assert provider.ws_url == "wss://#{host}/#{@token}"
      assert provider.archival == false
    end
  end

  test "Chainstack is the sole priority-1 provider with keyless archival-capable fallbacks" do
    profile = load_template!(@token)

    for {chain, chain_config} <- profile.chains do
      {[primary], fallbacks} = Enum.split_with(chain_config.providers, &chainstack?/1)

      assert primary.priority == 1
      assert fallbacks != [], "#{chain}: no fallback providers"

      for fallback <- fallbacks do
        assert fallback.priority > primary.priority,
               "#{chain}/#{fallback.id}: fallback must rank below Chainstack"

        refute fallback.url =~ @token, "#{chain}/#{fallback.id}: fallback must be keyless"
      end

      assert Enum.any?(fallbacks, & &1.archival), "#{chain}: no archival fallback"
    end
  end

  test "fallbacks match their public profile entries apart from priority" do
    profile = load_template!(@token)
    {:ok, state} = FileBackend.init(profiles_dir: @profiles_dir)
    {:ok, public} = FileBackend.load(state, "public")

    for {chain, chain_config} <- profile.chains,
        fallback <- chain_config.providers,
        not chainstack?(fallback) do
      public_entry = Enum.find(public.chains[chain].providers, &(&1.id == fallback.id))
      assert public_entry, "#{chain}/#{fallback.id}: not present in public.yml"

      assert %{public_entry | priority: fallback.priority} == fallback,
             "#{chain}/#{fallback.id}: differs from public.yml"
    end
  end

  test "Chainstack capabilities pass boot validation and enforce the eth_getLogs cap" do
    profile = load_template!(@token)

    for {_chain, chain_config} <- profile.chains do
      provider = chainstack_provider(chain_config)
      caps = provider.capabilities
      assert :ok = Capabilities.validate!(provider.id, caps)

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

    for {_chain, chain_config} <- profile.chains do
      provider = chainstack_provider(chain_config)

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

  defp chainstack?(provider), do: String.ends_with?(provider.id, "_chainstack")

  defp chainstack_provider(chain_config) do
    assert [provider] = Enum.filter(chain_config.providers, &chainstack?/1)
    provider
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
