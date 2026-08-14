defmodule Lasso.RPC.PreparedRequestTest do
  use ExUnit.Case, async: true

  alias Lasso.RPC.PreparedRequest

  test "encodes an upstream transport id once and retains the client id" do
    rpc_request = %{
      "jsonrpc" => "2.0",
      "method" => "eth_call",
      "params" => [%{"to" => "0x1"}],
      "id" => "client-id"
    }

    assert {:ok, prepared} = PreparedRequest.new(rpc_request, "lasso-request-nonce")
    assert prepared.client_id == "client-id"
    assert prepared.transport_id == "lasso-request-nonce"

    assert {:ok,
            %{
              "id" => "lasso-request-nonce",
              "method" => "eth_call",
              "params" => [%{"to" => "0x1"}]
            }} = Jason.decode(prepared.encoded)
  end

  test "preserves an explicit null client id" do
    request = %{"jsonrpc" => "2.0", "method" => "eth_call", "params" => [], "id" => nil}

    assert {:ok, %PreparedRequest{client_id: nil} = prepared} =
             PreparedRequest.new(request, "lasso-null")

    assert {:ok, %{"id" => nil}} = PreparedRequest.to_legacy_map(prepared)
  end

  test "rejects invalid transport ids and unencodable request values" do
    request = %{"jsonrpc" => "2.0", "method" => "eth_call", "params" => [], "id" => 1}

    assert {:error, :invalid_transport_id} = PreparedRequest.new(request, "client-id")

    assert {:error, :invalid_client_id} =
             PreparedRequest.new(%{request | "id" => self()}, "lasso-invalid-client-id")

    assert {:error, %Protocol.UndefinedError{}} =
             PreparedRequest.new(%{request | "params" => [self()]}, "lasso-unencodable")
  end
end
