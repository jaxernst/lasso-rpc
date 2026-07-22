defmodule LassoWeb.RPCSocketTest do
  use ExUnit.Case, async: false

  alias LassoWeb.RPCSocket

  @chain_id 99_999_991

  defp transport_info(path, params) do
    %{
      params: params,
      connect_info: %{
        uri: %URI{path: path},
        peer_data: %{address: {127, 0, 0, 1}}
      }
    }
  end

  setup do
    :ok =
      Lasso.Config.ConfigStore.register_chain_runtime("public", @chain_id, %{
        display_name: "Test Chain",
        url_aliases: ["test-chain"],
        providers: []
      })

    on_exit(fn ->
      Lasso.Config.ConfigStore.unregister_chain_runtime("public", @chain_id)
    end)

    :ok
  end

  describe "connect/1 - profile validation" do
    test "accepts when no profile is specified (defaults to public)" do
      assert {:ok, state} =
               RPCSocket.connect(
                 transport_info("/ws/rpc/test-chain", %{"chain_id" => "test-chain"})
               )

      assert state.profile == "public"
      assert state.chain_id == @chain_id
    end

    test "accepts an existing profile" do
      assert {:ok, state} =
               RPCSocket.connect(
                 transport_info("/ws/rpc/profile/public/test-chain", %{
                   "chain_id" => "test-chain",
                   "profile" => "public"
                 })
               )

      assert state.profile == "public"
      assert state.chain_id == @chain_id
    end

    test "accepts a numeric chain ID" do
      assert {:ok, state} =
               RPCSocket.connect(
                 transport_info("/ws/rpc/#{@chain_id}", %{"chain_id" => to_string(@chain_id)})
               )

      assert state.chain_id == @chain_id
    end

    test "rejects an unknown or nonpositive chain ID" do
      assert :error = RPCSocket.connect(transport_info("/ws/rpc/0", %{"chain_id" => "0"}))
      assert :error = RPCSocket.connect(transport_info("/ws/rpc/nope", %{"chain_id" => "nope"}))
    end

    test "rejects when profile is explicitly invalid" do
      assert :error =
               RPCSocket.connect(
                 transport_info("/ws/rpc/profile/zzz/test-chain", %{
                   "chain_id" => "test-chain",
                   "profile" => "zzz"
                 })
               )
    end
  end

  describe "connect/1 - provider override validation" do
    test "rejects when provider override does not exist" do
      assert :error =
               RPCSocket.connect(
                 transport_info("/ws/rpc/provider/ghost/test-chain", %{
                   "chain_id" => "test-chain",
                   "profile" => "public"
                 })
               )
    end

    test "accepts when no provider override is specified" do
      assert {:ok, state} =
               RPCSocket.connect(
                 transport_info("/ws/rpc/test-chain", %{
                   "chain_id" => "test-chain",
                   "profile" => "public"
                 })
               )

      assert state.provider_id == nil
    end
  end
end
