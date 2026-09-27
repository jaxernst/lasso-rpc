defmodule Lasso.RPC.Providers.AdapterHelpersTest do
  use ExUnit.Case, async: false

  alias Lasso.BlockSync.Registry, as: BlockSyncRegistry
  alias Lasso.RPC.Providers.AdapterHelpers
  alias Lasso.RPC.Providers.Capabilities

  setup do
    chain_id = 4_218_000 + System.unique_integer([:positive, :monotonic])
    BlockSyncRegistry.clear_chain(chain_id)
    on_exit(fn -> BlockSyncRegistry.clear_chain(chain_id) end)
    {:ok, chain_id: chain_id}
  end

  describe "estimate_current_block/1" do
    test "reads consensus using the integer chain ID", %{chain_id: chain_id} do
      BlockSyncRegistry.put_height(chain_id, "provider_1", 1_000_000, :http, %{})

      assert AdapterHelpers.estimate_current_block(%{chain: "ethereum", chain_id: chain_id}) ==
               1_000_000
    end

    test "fails open when the context has only a chain slug" do
      assert AdapterHelpers.estimate_current_block(%{chain: "ethereum"}) == 0
    end

    test "fails open when the chain ID is invalid" do
      assert AdapterHelpers.estimate_current_block(%{chain_id: "ethereum"}) == 0
    end
  end

  test "capability depth checks the method's block selector with real head evidence", %{
    chain_id: chain_id
  } do
    BlockSyncRegistry.put_height(chain_id, "provider_1", 1_000, :http, %{})

    capabilities = %{
      limits: %{
        max_block_age: 100,
        block_age_methods: ["eth_call", "eth_getBalance", "eth_getStorageAt"]
      }
    }

    ctx = %{chain_id: chain_id}

    assert {:error, {:requires_archival, _}} =
             Capabilities.validate_params(
               "eth_call",
               [%{"to" => "0xabc"}, "0x320", %{"0xabc" => %{}}],
               capabilities,
               ctx
             )

    assert {:error, {:requires_archival, _}} =
             Capabilities.validate_params(
               "eth_getStorageAt",
               ["0xabc", "0x0", %{"blockNumber" => "0x320"}],
               capabilities,
               ctx
             )

    assert :ok =
             Capabilities.validate_params(
               "eth_getBalance",
               ["0xabc", "0x3b6"],
               capabilities,
               ctx
             )
  end
end
