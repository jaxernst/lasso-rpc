defmodule Lasso.RPC.RequestOptions.BuilderTest do
  use ExUnit.Case, async: true

  alias Lasso.RPC.RequestOptions
  alias Lasso.RPC.RequestOptions.Builder

  test "an explicit null JSON-RPC id remains distinguishable from an omitted id" do
    omitted = Builder.from_map(%{}, "eth_blockNumber")
    explicit_null = Builder.from_map(%{}, "eth_blockNumber", jsonrpc_id: nil)

    refute omitted.jsonrpc_id_present?
    assert omitted.jsonrpc_id == nil
    assert explicit_null.jsonrpc_id_present?
    assert explicit_null.jsonrpc_id == nil
  end

  test "keyword conversion retains JSON-RPC id presence" do
    options = %RequestOptions{
      timeout_ms: 100,
      jsonrpc_id: nil,
      jsonrpc_id_present?: true
    }

    assert Keyword.fetch!(RequestOptions.to_keyword(options), :jsonrpc_id) == nil
    assert Keyword.fetch!(RequestOptions.to_keyword(options), :jsonrpc_id_present?)
  end

  test "request origin defaults to client and accepts explicit system ownership" do
    assert Builder.from_map(%{}, "eth_blockNumber").request_origin == :client

    assert Builder.from_map(%{}, "eth_blockNumber", request_origin: :system).request_origin ==
             :system

    assert {:error, _reason} =
             RequestOptions.validate(
               %RequestOptions{timeout_ms: 100, request_origin: :unknown},
               "eth_blockNumber"
             )
  end
end
