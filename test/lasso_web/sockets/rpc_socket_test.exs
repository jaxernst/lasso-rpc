defmodule LassoWeb.RPCSocketTest do
  use ExUnit.Case, async: false

  alias LassoWeb.RPCSocket

  defp transport_info(path, params) do
    %{
      params: params,
      connect_info: %{
        uri: %URI{path: path},
        peer_data: %{address: {127, 0, 0, 1}}
      }
    }
  end

  describe "connect/1 - profile validation" do
    test "accepts when no profile is specified (defaults to public)" do
      assert {:ok, state} =
               RPCSocket.connect(transport_info("/ws/rpc/ethereum", %{"chain_id" => "ethereum"}))

      assert state.profile == "public"
      assert state.chain == "ethereum"
    end

    test "accepts an existing profile" do
      assert {:ok, state} =
               RPCSocket.connect(
                 transport_info("/ws/rpc/profile/public/ethereum", %{
                   "chain_id" => "ethereum",
                   "profile" => "public"
                 })
               )

      assert state.profile == "public"
    end

    test "rejects when profile is explicitly invalid" do
      assert :error =
               RPCSocket.connect(
                 transport_info("/ws/rpc/profile/zzz/ethereum", %{
                   "chain_id" => "ethereum",
                   "profile" => "zzz"
                 })
               )
    end
  end

  describe "connect/1 - provider override validation" do
    test "rejects when provider override does not exist" do
      assert :error =
               RPCSocket.connect(
                 transport_info("/ws/rpc/provider/ghost/ethereum", %{
                   "chain_id" => "ethereum",
                   "profile" => "public"
                 })
               )
    end

    test "accepts when no provider override is specified" do
      assert {:ok, state} =
               RPCSocket.connect(
                 transport_info("/ws/rpc/ethereum", %{
                   "chain_id" => "ethereum",
                   "profile" => "public"
                 })
               )

      assert state.provider_id == nil
    end
  end
end
