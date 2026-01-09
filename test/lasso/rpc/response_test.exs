defmodule Lasso.RPC.ResponseTest do
  use ExUnit.Case, async: true

  alias Lasso.RPC.Response
  alias Lasso.RPC.Response.{Success, Error, Batch}

  describe "Response.from_bytes/1" do
    test "parses success response" do
      raw = ~s({"jsonrpc":"2.0","id":1,"result":"0x123"})

      assert {:ok, %Success{} = resp} = Response.from_bytes(raw)
      assert resp.id == 1
      assert resp.jsonrpc == "2.0"
      assert resp.raw_bytes == raw
    end

    test "parses error response fully" do
      raw = ~s({"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"Invalid"}})

      assert {:ok, %Error{} = resp} = Response.from_bytes(raw)
      assert resp.id == 1
      assert resp.error.code == -32600
      assert resp.error.message == "Invalid"
    end

    test "parses error response with data field" do
      raw =
        ~s({"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"Invalid params","data":{"field":"value"}}})

      assert {:ok, %Error{} = resp} = Response.from_bytes(raw)
      assert resp.error.code == -32602
      assert resp.error.data == %{"field" => "value"}
    end

    test "handles large array result without parsing" do
      large_array = "[" <> String.duplicate("1,", 10_000) <> "1]"
      raw = ~s({"jsonrpc":"2.0","id":1,"result":#{large_array}})

      assert {:ok, %Success{} = resp} = Response.from_bytes(raw)
      assert Success.response_size(resp) > 10_000
      # raw_bytes should be preserved exactly
      assert resp.raw_bytes == raw
    end

    test "handles various key orderings" do
      orderings = [
        ~s({"jsonrpc":"2.0","id":1,"result":"ok"}),
        ~s({"result":"ok","jsonrpc":"2.0","id":1}),
        ~s({"id":1,"result":"ok","jsonrpc":"2.0"}),
        ~s({"result":"ok","id":1,"jsonrpc":"2.0"})
      ]

      for raw <- orderings do
        assert {:ok, %Success{id: 1}} = Response.from_bytes(raw)
      end
    end

    test "handles string IDs" do
      raw = ~s({"jsonrpc":"2.0","id":"abc123","result":"ok"})

      assert {:ok, %Success{id: "abc123"}} = Response.from_bytes(raw)
    end

    test "handles null ID" do
      raw = ~s({"jsonrpc":"2.0","id":null,"result":"ok"})

      assert {:ok, %Success{id: nil}} = Response.from_bytes(raw)
    end

    test "handles negative integer ID" do
      raw = ~s({"jsonrpc":"2.0","id":-42,"result":"ok"})

      assert {:ok, %Success{id: -42}} = Response.from_bytes(raw)
    end

    test "returns error for invalid input" do
      assert {:error, _} = Response.from_bytes("not json")
      assert {:error, :invalid_input} = Response.from_bytes(123)
      assert {:error, :invalid_input} = Response.from_bytes(nil)
    end

    test "returns error for malformed JSON-RPC" do
      # Missing result and error
      assert {:error, _} = Response.from_bytes(~s({"jsonrpc":"2.0","id":1}))
    end
  end

  describe "Response.from_batch_bytes/1" do
    test "parses batch with success responses" do
      raw = ~s([{"jsonrpc":"2.0","id":1,"result":"a"},{"jsonrpc":"2.0","id":2,"result":"b"}])

      assert {:ok, %Batch{} = batch} = Response.from_batch_bytes(raw)
      assert length(batch.items) == 2
      assert batch.request_ids == [1, 2]
      assert [%Success{id: 1}, %Success{id: 2}] = batch.items
    end

    test "parses batch with mixed success and error" do
      raw =
        ~s([{"jsonrpc":"2.0","id":1,"result":"ok"},{"jsonrpc":"2.0","id":2,"error":{"code":-32600,"message":"Bad"}}])

      assert {:ok, %Batch{} = batch} = Response.from_batch_bytes(raw)
      assert [%Success{id: 1}, %Error{id: 2}] = batch.items
    end

    test "parses empty batch" do
      assert {:ok, %Batch{items: [], request_ids: []}} = Response.from_batch_bytes("[]")
    end

    test "returns error for non-batch input" do
      assert {:error, _} = Response.from_batch_bytes(~s({"jsonrpc":"2.0","id":1,"result":"ok"}))
    end
  end

  describe "Response.to_bytes/1" do
    test "returns raw bytes for Success" do
      raw = ~s({"jsonrpc":"2.0","id":1,"result":"0x123"})
      {:ok, resp} = Response.from_bytes(raw)

      assert {:ok, ^raw} = Response.to_bytes(resp)
    end

    test "encodes Error to bytes" do
      raw = ~s({"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"Invalid"}})
      {:ok, resp} = Response.from_bytes(raw)

      assert {:ok, encoded} = Response.to_bytes(resp)
      assert {:ok, decoded} = Jason.decode(encoded)
      assert decoded["error"]["code"] == -32600
      assert decoded["id"] == 1
    end
  end

  describe "Response.id/1" do
    test "extracts ID from Success" do
      {:ok, resp} = Response.from_bytes(~s({"jsonrpc":"2.0","id":42,"result":"ok"}))
      assert Response.id(resp) == 42
    end

    test "extracts ID from Error" do
      {:ok, resp} =
        Response.from_bytes(~s({"jsonrpc":"2.0","id":42,"error":{"code":-32600,"message":"Bad"}}))

      assert Response.id(resp) == 42
    end

    test "returns nil for Batch" do
      {:ok, batch} = Response.from_batch_bytes(~s([{"jsonrpc":"2.0","id":1,"result":"ok"}]))
      assert Response.id(batch) == nil
    end
  end

  describe "Success.decode_result/1" do
    test "decodes result when explicitly called" do
      raw = ~s({"jsonrpc":"2.0","id":1,"result":"0x123"})
      {:ok, resp} = Response.from_bytes(raw)

      assert {:ok, "0x123"} = Success.decode_result(resp)
    end

    test "decodes complex result" do
      raw = ~s({"jsonrpc":"2.0","id":1,"result":{"hash":"0xabc","number":123}})
      {:ok, resp} = Response.from_bytes(raw)

      assert {:ok, %{"hash" => "0xabc", "number" => 123}} = Success.decode_result(resp)
    end

    test "decodes null result" do
      raw = ~s({"jsonrpc":"2.0","id":1,"result":null})
      {:ok, resp} = Response.from_bytes(raw)

      assert {:ok, nil} = Success.decode_result(resp)
    end

    test "decodes array result" do
      raw = ~s({"jsonrpc":"2.0","id":1,"result":[1,2,3]})
      {:ok, resp} = Response.from_bytes(raw)

      assert {:ok, [1, 2, 3]} = Success.decode_result(resp)
    end

    test "decodes boolean result" do
      raw = ~s({"jsonrpc":"2.0","id":1,"result":true})
      {:ok, resp} = Response.from_bytes(raw)

      assert {:ok, true} = Success.decode_result(resp)
    end
  end

  describe "Success.response_size/1" do
    test "returns byte size of raw response" do
      raw = ~s({"jsonrpc":"2.0","id":1,"result":"0x123"})
      {:ok, resp} = Response.from_bytes(raw)

      assert Success.response_size(resp) == byte_size(raw)
    end
  end

  describe "Error.to_bytes/1" do
    test "returns raw bytes if available" do
      raw = ~s({"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"Invalid"}})
      {:ok, %Error{} = resp} = Response.from_bytes(raw)

      # raw_bytes is preserved from envelope
      assert {:ok, ^raw} = Error.to_bytes(resp)
    end

    test "encodes error without raw bytes" do
      error = %Error{
        id: 1,
        jsonrpc: "2.0",
        error: Lasso.JSONRPC.Error.new(-32600, "Invalid"),
        raw_bytes: nil
      }

      assert {:ok, encoded} = Error.to_bytes(error)
      assert {:ok, decoded} = Jason.decode(encoded)
      assert decoded["error"]["code"] == -32600
      assert decoded["id"] == 1
    end
  end

  describe "Batch.build/2" do
    test "orders items by request IDs" do
      items = [
        %Success{id: 2, jsonrpc: "2.0", raw_bytes: ~s({"jsonrpc":"2.0","id":2,"result":"b"})},
        %Success{id: 1, jsonrpc: "2.0", raw_bytes: ~s({"jsonrpc":"2.0","id":1,"result":"a"})},
        %Success{id: 3, jsonrpc: "2.0", raw_bytes: ~s({"jsonrpc":"2.0","id":3,"result":"c"})}
      ]

      assert {:ok, batch} = Batch.build(items, [1, 2, 3])
      assert [%Success{id: 1}, %Success{id: 2}, %Success{id: 3}] = batch.items
    end

    test "rejects duplicate response IDs" do
      items = [
        %Success{id: 1, jsonrpc: "2.0", raw_bytes: ~s({"jsonrpc":"2.0","id":1,"result":"a"})},
        %Success{id: 1, jsonrpc: "2.0", raw_bytes: ~s({"jsonrpc":"2.0","id":1,"result":"b"})}
      ]

      assert {:error, {:duplicate_response_ids, [1]}} = Batch.build(items, [1, 1])
    end

    test "rejects missing response IDs" do
      items = [
        %Success{id: 1, jsonrpc: "2.0", raw_bytes: ~s({"jsonrpc":"2.0","id":1,"result":"a"})}
      ]

      assert {:error, {:missing_response_id, 2}} = Batch.build(items, [1, 2])
    end
  end

  describe "Batch.to_bytes/1" do
    test "reconstructs JSON array from raw bytes" do
      items = [
        %Success{id: 1, jsonrpc: "2.0", raw_bytes: ~s({"jsonrpc":"2.0","id":1,"result":"0x123"})},
        %Success{id: 2, jsonrpc: "2.0", raw_bytes: ~s({"jsonrpc":"2.0","id":2,"result":[1,2,3]})}
      ]

      {:ok, batch} = Batch.build(items, [1, 2])
      {:ok, bytes} = Batch.to_bytes(batch)

      assert {:ok, decoded} = Jason.decode(bytes)
      assert is_list(decoded)
      assert length(decoded) == 2
      assert Enum.at(decoded, 0)["result"] == "0x123"
      assert Enum.at(decoded, 1)["result"] == [1, 2, 3]
    end

    test "handles empty batch" do
      batch = %Batch{items: [], request_ids: [], total_byte_size: 0}
      assert {:ok, "[]"} = Batch.to_bytes(batch)
    end

    test "handles mixed success and error items" do
      success = %Success{
        id: 1,
        jsonrpc: "2.0",
        raw_bytes: ~s({"jsonrpc":"2.0","id":1,"result":"ok"})
      }

      error = %Error{
        id: 2,
        jsonrpc: "2.0",
        error: Lasso.JSONRPC.Error.new(-32600, "Bad"),
        raw_bytes: nil
      }

      {:ok, batch} = Batch.build([success, error], [1, 2])
      {:ok, bytes} = Batch.to_bytes(batch)

      assert {:ok, decoded} = Jason.decode(bytes)
      assert length(decoded) == 2
      assert Enum.at(decoded, 0)["result"] == "ok"
      assert Enum.at(decoded, 1)["error"]["code"] == -32600
    end
  end

  describe "Batch.passthrough_count/1" do
    test "counts success items" do
      items = [
        %Success{id: 1, jsonrpc: "2.0", raw_bytes: "{}"},
        %Error{
          id: 2,
          jsonrpc: "2.0",
          error: Lasso.JSONRPC.Error.new(-32600, "Bad"),
          raw_bytes: nil
        },
        %Success{id: 3, jsonrpc: "2.0", raw_bytes: "{}"}
      ]

      {:ok, batch} = Batch.build(items, [1, 2, 3])
      assert Batch.passthrough_count(batch) == 2
    end

    test "returns zero for all errors" do
      items = [
        %Error{
          id: 1,
          jsonrpc: "2.0",
          error: Lasso.JSONRPC.Error.new(-32600, "Bad"),
          raw_bytes: nil
        }
      ]

      {:ok, batch} = Batch.build(items, [1])
      assert Batch.passthrough_count(batch) == 0
    end
  end

  describe "invariant: raw_bytes preservation" do
    test "raw_bytes is bit-for-bit identical to input" do
      # Various response shapes
      test_cases = [
        ~s({"jsonrpc":"2.0","id":1,"result":"0x123"}),
        ~s({"jsonrpc":"2.0","id":1,"result":null}),
        ~s({"jsonrpc":"2.0","id":1,"result":[1,2,3]}),
        ~s({"jsonrpc":"2.0","id":1,"result":{"a":1,"b":2}}),
        ~s({"result":"ok","jsonrpc":"2.0","id":1}),
        ~s({"id":1,"result":"ok","jsonrpc":"2.0"})
      ]

      for raw <- test_cases do
        {:ok, %Success{raw_bytes: bytes}} = Response.from_bytes(raw)
        assert bytes == raw, "raw_bytes must be bit-for-bit identical for: #{raw}"
      end
    end
  end

  describe "invariant: decode_result matches full JSON decode" do
    test "decode_result returns same value as Jason.decode['result']" do
      test_cases = [
        ~s({"jsonrpc":"2.0","id":1,"result":"0x123"}),
        ~s({"jsonrpc":"2.0","id":1,"result":null}),
        ~s({"jsonrpc":"2.0","id":1,"result":true}),
        ~s({"jsonrpc":"2.0","id":1,"result":42}),
        ~s({"jsonrpc":"2.0","id":1,"result":[1,2,3]}),
        ~s({"jsonrpc":"2.0","id":1,"result":{"hash":"0xabc","number":123}})
      ]

      for raw <- test_cases do
        {:ok, success} = Response.from_bytes(raw)
        {:ok, decoded_result} = Success.decode_result(success)

        {:ok, full_decode} = Jason.decode(raw)
        assert decoded_result == full_decode["result"], "decode_result mismatch for: #{raw}"
      end
    end
  end

  describe "invariant: parsed ID matches decoded ID" do
    test "parsed ID equals ID in raw bytes" do
      test_cases = [
        {~s({"jsonrpc":"2.0","id":1,"result":"ok"}), 1},
        {~s({"jsonrpc":"2.0","id":-42,"result":"ok"}), -42},
        {~s({"jsonrpc":"2.0","id":"abc","result":"ok"}), "abc"},
        {~s({"jsonrpc":"2.0","id":null,"result":"ok"}), nil}
      ]

      for {raw, expected_id} <- test_cases do
        {:ok, success} = Response.from_bytes(raw)
        assert success.id == expected_id, "ID mismatch for: #{raw}"
      end
    end
  end
end
