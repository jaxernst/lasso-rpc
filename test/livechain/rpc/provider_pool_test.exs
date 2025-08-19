defmodule Livechain.RPC.ProviderPoolTest do
  use ExUnit.Case, async: true

  alias Livechain.RPC.ProviderPool
  alias Livechain.Config.ChainConfig

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

  defp provider_struct(attrs \\ []) do
    struct(
      ChainConfig.Provider,
      Map.merge(
        %{
          id: "test_provider",
          name: "Test Provider",
          priority: 1,
          type: "public",
          url: "http://example",
          ws_url: "ws://example",
          api_key_required: false,
          region: "us"
        },
        attrs
      )
    )
  end

  test "EMA updates on success and failure, cooldown on rate limit" do
    p1 = provider_struct(%{id: "p1", name: "P1", priority: 1, region: "us"})
    p2 = provider_struct(%{id: "p2", name: "P2", priority: 2, region: "us"})
    chain_config = base_chain_config([p1, p2])

    {:ok, _pid} = ProviderPool.start_link({"testnet", chain_config})

    :ok = ProviderPool.register_provider("testnet", p1.id, self(), p1)
    :ok = ProviderPool.register_provider("testnet", p2.id, self(), p2)

    ProviderPool.report_success("testnet", p1.id, 50)
    {:ok, status} = ProviderPool.get_status("testnet")
    p1_status = Enum.find(status.providers, &(&1.id == p1.id))
    assert p1_status.status in [:healthy, :connecting]

    ProviderPool.report_failure("testnet", p1.id, {:rate_limit, "HTTP 429"})
    {:ok, status2} = ProviderPool.get_status("testnet")
    p1_status2 = Enum.find(status2.providers, &(&1.id == p1.id))
    assert p1_status2.status == :rate_limited

    ProviderPool.report_failure("testnet", p1.id, {:server_error, "500"})
    {:ok, status3} = ProviderPool.get_status("testnet")
    p1_status3 = Enum.find(status3.providers, &(&1.id == p1.id))
    assert p1_status3.error_rate > p1_status2.error_rate
  end

  test ":latency strategy prefers lowest latency meeting success-rate threshold" do
    p1 = provider_struct(%{id: "p1", name: "P1", priority: 2, region: "us"})
    p2 = provider_struct(%{id: "p2", name: "P2", priority: 1, region: "us"})
    chain_config = base_chain_config([p1, p2])

    {:ok, _pid} = ProviderPool.start_link({"testnet_lat", chain_config})

    :ok = ProviderPool.register_provider("testnet_lat", p1.id, self(), p1)
    :ok = ProviderPool.register_provider("testnet_lat", p2.id, self(), p2)

    ProviderPool.report_success("testnet_lat", p1.id, 120)
    ProviderPool.report_success("testnet_lat", p2.id, 40)

    assert {:ok, best} =
             ProviderPool.get_best_provider("testnet_lat", :latency, "eth_blockNumber")

    assert best == "p2"

    for _ <- 1..10 do
      ProviderPool.report_failure("testnet_lat", p2.id, {:server_error, "500"})
    end

    assert {:ok, best2} =
             ProviderPool.get_best_provider("testnet_lat", :latency, "eth_blockNumber")

    assert best2 == "p1"
  end

  test ":cheapest prefers public type with fallback to paid and respects region filter" do
    p_pub_us =
      provider_struct(%{
        id: "pub_us",
        name: "PUB US",
        priority: 3,
        type: "public",
        region: "us"
      })

    p_paid_us =
      provider_struct(%{
        id: "paid_us",
        name: "PAID US",
        priority: 1,
        type: "paid",
        region: "us"
      })

    p_pub_eu =
      provider_struct(%{
        id: "pub_eu",
        name: "PUB EU",
        priority: 2,
        type: "public",
        region: "eu"
      })

    chain_config = base_chain_config([p_pub_us, p_paid_us, p_pub_eu])

    {:ok, _pid} = ProviderPool.start_link({"testnet_cheapest", chain_config})

    :ok = ProviderPool.register_provider("testnet_cheapest", p_pub_us.id, self(), p_pub_us)
    :ok = ProviderPool.register_provider("testnet_cheapest", p_paid_us.id, self(), p_paid_us)
    :ok = ProviderPool.register_provider("testnet_cheapest", p_pub_eu.id, self(), p_pub_eu)

    Enum.each([p_pub_us.id, p_paid_us.id, p_pub_eu.id], fn id ->
      ProviderPool.report_success("testnet_cheapest", id, 100)
    end)

    assert {:ok, best} =
             ProviderPool.get_best_provider("testnet_cheapest", :cheapest, "eth_blockNumber")

    assert best in ["pub_us", "pub_eu"]

    assert {:ok, best_us} =
             ProviderPool.get_best_provider("testnet_cheapest", :cheapest, "eth_blockNumber", %{
               region: "us"
             })

    assert best_us == "pub_us"

    ProviderPool.report_failure("testnet_cheapest", "pub_us", {:rate_limit, "429"})

    assert {:ok, best_us2} =
             ProviderPool.get_best_provider("testnet_cheapest", :cheapest, "eth_blockNumber", %{
               region: "us"
             })

    assert best_us2 == "paid_us"
  end
end
