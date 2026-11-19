defmodule Lasso.Integration.RuntimeProviderSchemaTest do
  use ExUnit.Case, async: false

  alias Lasso.Config.ConfigStore
  alias Lasso.Providers
  alias Lasso.Test.Harness.Fleet

  @moduletag :integration

  test "runtime providers enforce the YAML observation policy and burst budget, including partial updates" do
    chain_id = 700_000_000 + rem(System.unique_integer([:positive]), 100_000_000)
    upstream = Fleet.start!(self(), "runtime-schema")
    client = Application.fetch_env!(:lasso, :http_client)
    Application.put_env(:lasso, :http_client, Lasso.RPC.Transport.HTTP.Client.Finch)

    on_exit(fn ->
      Providers.remove_provider(chain_id, "metered")
      Lasso.ProfileChainSupervisor.stop_profile_chain("public", chain_id)
      ConfigStore.unregister_chain_runtime("public", chain_id)
      Application.put_env(:lasso, :http_client, client)
    end)

    assert :ok =
             ConfigStore.register_chain_runtime("public", chain_id, %{
               providers: [],
               monitoring: %{probe_interval_ms: 1_000}
             })

    config = %{
      id: "metered",
      url: upstream.url,
      background_observations: false,
      block_poll_interval_ms: 1_000,
      request_budget: %{requests_per_second: 1, burst: 2},
      capabilities: %{limits: %{max_block_age: 100, block_age_methods: ["eth_getBalance"]}}
    }

    assert {:error, {:invalid_profile_config, "providers.metered.typo", _}} =
             Providers.add_provider(chain_id, Map.put(config, :typo, true), validate: false)

    assert {:error, {:invalid_profile_config, "providers.metered.request_budget.typo", _}} =
             Providers.add_provider(chain_id, put_in(config, [:request_budget, :typo], true))

    assert {:error, {:invalid_profile_config, "providers.metered.request_budget.burst", _}} =
             Providers.add_provider(chain_id, put_in(config, [:request_budget, :burst], 0))

    assert {:ok, "metered"} = Providers.add_provider(chain_id, config)
    assert {:ok, provider} = Providers.get_provider(chain_id, "metered")
    assert provider.name == "metered"
    assert provider.priority == 100
    assert provider.capabilities.limits.max_block_age == 100

    # Wait past the configured head-poll interval before spending any client capacity.
    Process.sleep(1_200)
    assert Fleet.drain(upstream) == []

    assert rpc(chain_id)["result"]
    assert rpc(chain_id)["result"]
    error = rpc(chain_id)["error"]
    assert error["code"] == -32005
    assert error["data"]["reason"] == "upstream_request_budget_exhausted"
    assert error["data"]["retry_after_ms"] > 0
    calls = Fleet.drain(upstream)
    assert length(calls) == 2
    assert Enum.all?(calls, &(&1.request["method"] == "eth_getBalance"))

    assert {:error, {:invalid_profile_config, "providers.metered.typo", _}} =
             Providers.update_provider(chain_id, "metered", %{"typo" => true})

    assert :ok =
             Providers.update_provider(chain_id, "metered", %{
               "request_budget" => %{"requests_per_second" => 1, "burst" => 3},
               "observation_overrides" => %{"background_observations" => false}
             })

    assert {:ok, updated} = Providers.get_provider(chain_id, "metered")
    assert updated.request_budget == %{requests_per_second: 1, burst: 3}
    assert updated.background_observations == false
    assert updated.capabilities == provider.capabilities
    Process.sleep(1_200)
    assert Fleet.drain(upstream) == calls
    assert rpc(chain_id)["result"]
    assert rpc(chain_id)["result"]
    assert rpc(chain_id)["result"]
    assert rpc(chain_id)["error"]["code"] == -32005
  end

  defp rpc(chain_id) do
    port = LassoWeb.Endpoint.config(:http)[:port]

    {:ok, response} =
      Finch.build(
        :post,
        "http://127.0.0.1:#{port}/rpc/provider/metered/#{chain_id}",
        [{"content-type", "application/json"}],
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "eth_getBalance",
          params: ["0x0000000000000000000000000000000000000001", "latest"]
        })
      )
      |> Finch.request(Lasso.Finch)

    Jason.decode!(response.body)
  end
end
