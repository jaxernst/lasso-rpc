defmodule Lasso.RPC.Providers.AdapterHelpersTest do
  use ExUnit.Case, async: false

  alias Lasso.BlockSync.Registry, as: BlockSyncRegistry
  alias Lasso.RPC.Providers.AdapterHelpers

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
end
