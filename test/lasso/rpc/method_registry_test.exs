defmodule Lasso.RPC.MethodRegistryTest do
  use ExUnit.Case, async: true

  alias Lasso.Config.TransportPolicy
  alias Lasso.RPC.MethodRegistry

  test "uses the EIP-4844 blob base fee method name" do
    assert MethodRegistry.category_methods(:eip4844) == ["eth_blobBaseFee"]
  end

  test "registers each method in one category" do
    methods = MethodRegistry.categories() |> Map.values() |> List.flatten()
    assert Enum.uniq(methods) == methods
  end

  test "separates node introspection from application-facing network methods" do
    assert "net_version" in MethodRegistry.category_methods(:network)
    assert "net_peerCount" in MethodRegistry.category_methods(:node_admin)
    refute "net_peerCount" in MethodRegistry.category_methods(:network)
  end

  test "allows read-only transaction-pool inspection" do
    refute TransportPolicy.disallowed?("txpool_content")
    refute TransportPolicy.disallowed?("txpool_inspect")
    refute TransportPolicy.disallowed?("txpool_status")
  end
end
