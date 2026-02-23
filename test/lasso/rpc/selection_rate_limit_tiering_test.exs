defmodule Lasso.RPC.SelectionRateLimitTieringTest do
  @moduledoc """
  Tests that rate-limited providers are deprioritized (placed last) in selection,
  not excluded entirely.
  """

  use ExUnit.Case, async: false
  import Mox

  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.RPC.ProviderPool
  alias Lasso.Config.ChainConfig

  setup_all do
    TestHelper.ensure_test_environment_ready()
    :ok
  end

  setup :verify_on_exit!

  setup do
    stub(Lasso.RPC.HttpClientMock, :request, fn _endpoint, method, _params, _timeout ->
      case method do
        "eth_chainId" -> {:ok, "0x1"}
        "eth_blockNumber" -> {:ok, "0x100"}
        _ -> {:error, :method_not_mocked}
      end
    end)

    :ok
  end

  defp provider_struct(attrs) do
    struct(
      ChainConfig.Provider,
      Map.merge(
        %{
          id: "test_provider",
          name: "Test Provider",
          priority: 1,
          url: "http://example"
        },
        attrs
      )
    )
  end

  defp base_chain_config(providers) do
    %{
      aggregation: %{max_providers: 5},
      global: %{
        health_check: %{
          interval: 2000,
          timeout: 5_000,
          failure_threshold: 2,
          recovery_threshold: 1
        },
        provider_management: %{load_balancing: "priority"}
      },
      providers: providers
    }
  end

  describe "rate limit tiering in list_candidates" do
    test "rate-limited providers appear in candidates with rate_limited flag" do
      p1 = provider_struct(%{id: "rl_tier_p1", name: "P1", priority: 1})
      p2 = provider_struct(%{id: "rl_tier_p2", name: "P2", priority: 2})
      chain = "rl_tiering_test_1"
      chain_config = base_chain_config([p1, p2])

      {:ok, _pid} = ProviderPool.start_link({"default", chain, chain_config})

      # Make providers healthy
      ProviderPool.report_success("default", chain, p1.id, :http)
      ProviderPool.report_success("default", chain, p2.id, :http)
      Process.sleep(50)

      # Rate limit p1 via a rate limit error
      rate_limit_err =
        JError.new(-32_005, "Rate limited",
          category: :rate_limit,
          data: %{retry_after_ms: 30_000}
        )

      ProviderPool.report_failure("default", chain, p1.id, rate_limit_err, :http)
      Process.sleep(50)

      # Both providers should appear in candidates
      candidates =
        ProviderPool.list_candidates("default", chain, %{
          protocol: :http,
          include_half_open: true
        })

      ids = Enum.map(candidates, & &1.id)
      assert p1.id in ids, "Rate-limited provider should still be a candidate"
      assert p2.id in ids

      # p1 should be flagged as rate-limited
      p1_candidate = Enum.find(candidates, &(&1.id == p1.id))
      assert p1_candidate.rate_limited.http == true

      # p2 should not be rate-limited
      p2_candidate = Enum.find(candidates, &(&1.id == p2.id))
      assert p2_candidate.rate_limited.http == false
    end

    test "rate-limited providers are not excluded from selection" do
      p1 = provider_struct(%{id: "rl_tier_only_p1", name: "Only Provider", priority: 1})
      chain = "rl_tiering_test_2"
      chain_config = base_chain_config([p1])

      {:ok, _pid} = ProviderPool.start_link({"default", chain, chain_config})

      # Make healthy then rate limit
      ProviderPool.report_success("default", chain, p1.id, :http)
      Process.sleep(50)

      rate_limit_err =
        JError.new(-32_005, "Rate limited",
          category: :rate_limit,
          data: %{retry_after_ms: 30_000}
        )

      ProviderPool.report_failure("default", chain, p1.id, rate_limit_err, :http)
      Process.sleep(50)

      # Even though p1 is rate-limited, it should still be a candidate
      # (prevents "no candidates" when all providers are rate-limited)
      candidates =
        ProviderPool.list_candidates("default", chain, %{
          protocol: :http,
          include_half_open: true
        })

      assert length(candidates) == 1
      assert hd(candidates).id == p1.id
    end
  end
end
