defmodule Lasso.Config.CapabilitiesIntegrationTest do
  @moduledoc """
  Integration tests that load actual YAML profile files and verify
  all provider capabilities pass boot-time validation.

  These tests catch:
  - Invalid category names in unsupported_categories
  - Malformed error_rules (missing code/message_contains, invalid category)
  - Invalid limits (non-integer, negative values)
  - Invalid message_contains types
  - Invalid block_age_methods types
  - YAML parsing issues in capability blocks
  """
  use ExUnit.Case, async: true

  alias Lasso.Config.Backend.File, as: FileBackend

  @profiles_dir "config/profiles"

  describe "YAML profile loading" do
    test "default.yml loads and all capabilities pass validation" do
      assert {:ok, profile} = load_profile("default")
      validate_profile_capabilities(profile)
    end

    test "all profiles have consistent capabilities for same-provider instances" do
      profile_slugs = list_profile_slugs()

      loaded =
        Enum.map(profile_slugs, fn slug ->
          {:ok, profile} = load_profile(slug)
          {slug, profile}
        end)

      for {slug_a, profile_a} <- loaded,
          {slug_b, profile_b} <- loaded,
          slug_a < slug_b do
        shared_providers = find_shared_providers(profile_a, profile_b)

        for {chain, provider_id, caps_a, caps_b} <- shared_providers do
          assert caps_a == caps_b,
                 "Provider #{provider_id} on #{chain} has different capabilities " <>
                   "between #{slug_a} and #{slug_b} profiles.\n" <>
                   "#{slug_a}: #{inspect(caps_a)}\n#{slug_b}: #{inspect(caps_b)}"
        end
      end
    end

    test "all DRPC providers have max_block_range limits" do
      for profile_slug <- list_profile_slugs() do
        {:ok, profile} = load_profile(profile_slug)

        for {chain, chain_config} <- profile.chains,
            provider <- chain_config.providers,
            String.contains?(provider.id, "drpc"),
            provider.capabilities != nil do
          limits = Map.get(provider.capabilities, :limits, %{})

          assert Map.has_key?(limits, :max_block_range),
                 "#{profile_slug}/#{chain}/#{provider.id}: DRPC provider missing max_block_range"
        end
      end
    end

    test "all PublicNode providers block filters category" do
      for profile_slug <- list_profile_slugs() do
        {:ok, profile} = load_profile(profile_slug)

        for {chain, chain_config} <- profile.chains,
            provider <- chain_config.providers,
            String.contains?(provider.id, "publicnode"),
            provider.capabilities != nil do
          categories = Map.get(provider.capabilities, :unsupported_categories, [])

          assert :filters in categories,
                 "#{profile_slug}/#{chain}/#{provider.id}: PublicNode must block :filters category, " <>
                   "got: #{inspect(categories)}"

          assert :debug in categories,
                 "#{profile_slug}/#{chain}/#{provider.id}: PublicNode must block :debug category"

          assert :trace in categories,
                 "#{profile_slug}/#{chain}/#{provider.id}: PublicNode must block :trace category"
        end
      end
    end

    test "all Ethereum mainnet PublicNode providers block eip4844" do
      for profile_slug <- list_profile_slugs() do
        {:ok, profile} = load_profile(profile_slug)

        case profile.chains["ethereum"] do
          nil ->
            :ok

          ethereum_config ->
            for provider <- ethereum_config.providers,
                String.contains?(provider.id, "publicnode"),
                provider.capabilities != nil do
              categories = Map.get(provider.capabilities, :unsupported_categories, [])

              assert :eip4844 in categories,
                     "#{profile_slug}/ethereum/#{provider.id}: Ethereum PublicNode must block :eip4844"
            end
        end
      end
    end

    test "all providers with capabilities have valid structure" do
      for profile_slug <- list_profile_slugs() do
        {:ok, profile} = load_profile(profile_slug)

        for {chain, chain_config} <- profile.chains,
            provider <- chain_config.providers,
            provider.capabilities != nil do
          caps = provider.capabilities
          ctx = "#{profile_slug}/#{chain}/#{provider.id}"

          if Map.has_key?(caps, :unsupported_categories) do
            assert is_list(caps.unsupported_categories),
                   "#{ctx}: unsupported_categories must be a list"

            assert Enum.all?(caps.unsupported_categories, &is_atom/1),
                   "#{ctx}: unsupported_categories must contain atoms"
          end

          if Map.has_key?(caps, :unsupported_methods) do
            assert is_list(caps.unsupported_methods),
                   "#{ctx}: unsupported_methods must be a list"

            assert Enum.all?(caps.unsupported_methods, &is_binary/1),
                   "#{ctx}: unsupported_methods must contain strings"
          end

          if Map.has_key?(caps, :limits) do
            assert is_map(caps.limits), "#{ctx}: limits must be a map"

            if max_range = Map.get(caps.limits, :max_block_range) do
              assert is_integer(max_range) and max_range > 0,
                     "#{ctx}: max_block_range must be a positive integer, got: #{inspect(max_range)}"
            end

            if max_age = Map.get(caps.limits, :max_block_age) do
              assert is_integer(max_age) and max_age > 0,
                     "#{ctx}: max_block_age must be a positive integer, got: #{inspect(max_age)}"
            end

            if methods = Map.get(caps.limits, :block_age_methods) do
              assert is_list(methods), "#{ctx}: block_age_methods must be a list"

              assert Enum.all?(methods, &is_binary/1),
                     "#{ctx}: block_age_methods must contain strings"
            end
          end

          if Map.has_key?(caps, :error_rules) do
            assert is_list(caps.error_rules), "#{ctx}: error_rules must be a list"

            for {rule, idx} <- Enum.with_index(caps.error_rules) do
              assert is_map(rule), "#{ctx}: error_rules[#{idx}] must be a map"

              assert Map.has_key?(rule, :category),
                     "#{ctx}: error_rules[#{idx}] missing :category"

              assert is_atom(rule.category),
                     "#{ctx}: error_rules[#{idx}].category must be an atom"

              has_code = Map.has_key?(rule, :code)
              has_msg = Map.has_key?(rule, :message_contains)

              assert has_code or has_msg,
                     "#{ctx}: error_rules[#{idx}] must have :code or :message_contains"
            end
          end
        end
      end
    end

    test "no duplicate provider IDs within a chain" do
      for profile_slug <- list_profile_slugs() do
        {:ok, profile} = load_profile(profile_slug)

        for {chain, chain_config} <- profile.chains do
          ids = Enum.map(chain_config.providers, & &1.id)
          duplicates = ids -- Enum.uniq(ids)

          assert duplicates == [],
                 "#{profile_slug}/#{chain}: duplicate provider IDs: #{inspect(duplicates)}"
        end
      end
    end
  end

  # Helpers

  defp list_profile_slugs do
    @profiles_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".yml"))
    |> Enum.map(&String.replace_suffix(&1, ".yml", ""))
    |> Enum.sort()
  end

  defp load_profile(slug) do
    {:ok, state} = FileBackend.init(profiles_dir: @profiles_dir)
    FileBackend.load(state, slug)
  end

  defp validate_profile_capabilities(profile) do
    for {chain, chain_config} <- profile.chains,
        provider <- chain_config.providers do
      assert provider.id, "Provider in #{chain} missing ID"
      assert provider.url, "Provider #{provider.id} in #{chain} missing URL"
    end
  end

  defp find_shared_providers(profile_a, profile_b) do
    for {chain, chain_a} <- profile_a.chains,
        chain_b = profile_b.chains[chain],
        chain_b != nil,
        provider_a <- chain_a.providers,
        provider_b <- chain_b.providers,
        provider_a.id == provider_b.id do
      {chain, provider_a.id, provider_a.capabilities, provider_b.capabilities}
    end
  end
end
