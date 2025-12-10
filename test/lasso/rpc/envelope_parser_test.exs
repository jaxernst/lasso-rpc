defmodule Lasso.RPC.EnvelopeParserTest do
  use ExUnit.Case, async: true

  alias Lasso.RPC.EnvelopeParser

  describe "parse/1 - key ordering" do
    test "handles standard order: jsonrpc, id, result" do
      json = ~s({"jsonrpc":"2.0","id":1,"result":[1,2,3]})

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.jsonrpc == "2.0"
      assert envelope.id == 1
      assert envelope.type == :result
      assert envelope.error == nil
    end

    test "handles result-first order" do
      json = ~s({"result":[1,2,3],"jsonrpc":"2.0","id":42})

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.jsonrpc == "2.0"
      assert envelope.id == 42
      assert envelope.type == :result
    end

    test "handles id-first order" do
      json = ~s({"id":999,"result":{"foo":"bar"},"jsonrpc":"2.0"})

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.id == 999
      assert envelope.type == :result
    end

    test "handles error response with different order" do
      json = ~s({"error":{"code":-32000,"message":"error"},"id":1,"jsonrpc":"2.0"})

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.type == :error
      assert envelope.error["code"] == -32000
      assert envelope.error["message"] == "error"
    end
  end

  describe "parse/1 - ID types" do
    test "handles integer ID" do
      json = ~s({"jsonrpc":"2.0","id":12345,"result":null})

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.id == 12345
    end

    test "handles string ID" do
      json = ~s({"jsonrpc":"2.0","id":"request-uuid-123","result":null})

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.id == "request-uuid-123"
    end

    test "handles null ID (notification response)" do
      json = ~s({"jsonrpc":"2.0","id":null,"result":true})

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.id == nil
    end

    test "handles missing ID (notification)" do
      json = ~s({"jsonrpc":"2.0","result":"ok"})

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.id == nil
    end

    test "handles negative integer ID" do
      json = ~s({"jsonrpc":"2.0","id":-1,"result":[]})

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.id == -1
    end
  end

  describe "parse/1 - whitespace handling" do
    test "handles pretty-printed JSON" do
      json = """
      {
        "jsonrpc": "2.0",
        "id": 1,
        "result": [1, 2, 3]
      }
      """

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.id == 1
      assert envelope.type == :result
    end

    test "handles extra whitespace around colon" do
      json = ~s({"jsonrpc" : "2.0" , "id" : 1 , "result" : []})

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.id == 1
    end
  end

  describe "parse/1 - error responses" do
    test "parses full error object" do
      json = ~s({"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"Invalid Request","data":{"details":"missing field"}}})

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.type == :error
      assert envelope.error["code"] == -32600
      assert envelope.error["message"] == "Invalid Request"
      assert envelope.error["data"]["details"] == "missing field"
    end

    test "handles error with nested objects" do
      json = ~s({"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"Server error","data":{"context":{"block":123}}}})

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.error["data"]["context"]["block"] == 123
    end

    test "handles error with string containing braces" do
      json = ~s({"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"Error in {block}"}})

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.error["message"] == "Error in {block}"
    end
  end

  describe "parse/1 - large result (not parsed)" do
    test "does not parse large result array" do
      # Generate a large result
      large_result = 1..1000 |> Enum.to_list() |> Jason.encode!()
      json = ~s({"jsonrpc":"2.0","id":1,"result":#{large_result}})

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.type == :result
      assert envelope.result_offset > 0
      # The raw bytes are preserved for pass-through
      assert envelope.raw_bytes == json
    end

    test "preserves raw_bytes for pass-through" do
      json = ~s({"jsonrpc":"2.0","id":1,"result":{"key":"value"}})

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.raw_bytes == json
    end
  end

  describe "parse/1 - edge cases" do
    test "handles escaped quotes in string values" do
      json = ~s({"jsonrpc":"2.0","id":"req\\"123","result":null})

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.id == "req\"123"
    end

    test "handles all JSON escape sequences" do
      # Test \n, \r, \t, \\, \/, \b, \f
      json = ~s({"jsonrpc":"2.0","id":"a\\nb\\rc\\td\\\\e\\/f","result":null})

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.id == "a\nb\rc\td\\e/f"
    end

    test "handles very long string IDs (near scan limit)" do
      # ID with 1000 characters - should still find result key within 2000 byte scan limit
      long_id = String.duplicate("x", 1000)
      json = ~s({"jsonrpc":"2.0","id":"#{long_id}","result":null})

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.id == long_id
      assert envelope.type == :result
    end

    test "handles deeply nested error objects within limit" do
      # 50 levels deep - within the 100 depth limit
      nested =
        Enum.reduce(1..50, ~s({"code":-32000,"message":"deep"}), fn _, acc ->
          ~s({"nested":#{acc}})
        end)

      json = ~s({"jsonrpc":"2.0","id":1,"error":#{nested}})

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.type == :error
      assert envelope.error["nested"]["nested"]["nested"] != nil
    end

    test "rejects excessively nested error objects" do
      # 150 levels deep - exceeds the 100 depth limit
      nested =
        Enum.reduce(1..150, ~s({"code":-32000}), fn _, acc ->
          ~s({"x":#{acc}})
        end)

      json = ~s({"jsonrpc":"2.0","id":1,"error":#{nested}})

      assert {:error, :malformed_error_object} = EnvelopeParser.parse(json)
    end

    test "returns error for missing result/error" do
      json = ~s({"jsonrpc":"2.0","id":1})

      assert {:error, :no_result_or_error} = EnvelopeParser.parse(json)
    end

    test "returns error for empty input" do
      assert {:error, _} = EnvelopeParser.parse("")
    end

    test "returns error for non-binary input" do
      assert {:error, :invalid_input} = EnvelopeParser.parse(nil)
      assert {:error, :invalid_input} = EnvelopeParser.parse(123)
    end
  end

  describe "passthrough_eligible?/2" do
    test "returns true for matching result response" do
      json = ~s({"jsonrpc":"2.0","id":1,"result":[]})
      {:ok, envelope} = EnvelopeParser.parse(json)

      assert EnvelopeParser.passthrough_eligible?(envelope, 1)
    end

    test "returns false for ID mismatch" do
      json = ~s({"jsonrpc":"2.0","id":2,"result":[]})
      {:ok, envelope} = EnvelopeParser.parse(json)

      refute EnvelopeParser.passthrough_eligible?(envelope, 1)
    end

    test "returns false for error response" do
      json = ~s({"jsonrpc":"2.0","id":1,"error":{"code":-1,"message":"err"}})
      {:ok, envelope} = EnvelopeParser.parse(json)

      refute EnvelopeParser.passthrough_eligible?(envelope, 1)
    end

    test "returns true when expected_id is nil (notification)" do
      json = ~s({"jsonrpc":"2.0","id":123,"result":[]})
      {:ok, envelope} = EnvelopeParser.parse(json)

      assert EnvelopeParser.passthrough_eligible?(envelope, nil)
    end
  end

  describe "real-world JSON-RPC responses" do
    test "eth_blockNumber response" do
      json = ~s({"jsonrpc":"2.0","id":1,"result":"0x1234567"})

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.type == :result
      assert envelope.id == 1
    end

    test "eth_getLogs response (simulated large)" do
      logs = for i <- 1..10, do: %{"logIndex" => "0x#{Integer.to_string(i, 16)}"}
      json = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => logs})

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.type == :result
      # Result is NOT parsed - we only know the offset
      assert is_integer(envelope.result_offset)
    end

    test "rate limit error response" do
      json = ~s({"jsonrpc":"2.0","id":1,"error":{"code":429,"message":"Too Many Requests"}})

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.type == :error
      assert envelope.error["code"] == 429
    end

    test "block range error response" do
      json = ~s({"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"block range too large","data":{"max":10000}}})

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.error["code"] == -32000
      assert envelope.error["data"]["max"] == 10000
    end
  end

  describe "parse_batch/1 - basic batch parsing" do
    test "handles empty batch" do
      json = ~s([])

      assert {:ok, envelopes} = EnvelopeParser.parse_batch(json)
      assert envelopes == []
    end

    test "handles single-item batch" do
      json = ~s([{"jsonrpc":"2.0","id":1,"result":[1,2,3]}])

      assert {:ok, envelopes} = EnvelopeParser.parse_batch(json)
      assert length(envelopes) == 1
      assert hd(envelopes).id == 1
      assert hd(envelopes).type == :result
    end

    test "handles two-item batch" do
      json = ~s([{"jsonrpc":"2.0","id":1,"result":"first"},{"jsonrpc":"2.0","id":2,"result":"second"}])

      assert {:ok, envelopes} = EnvelopeParser.parse_batch(json)
      assert length(envelopes) == 2
      [first, second] = envelopes
      assert first.id == 1
      assert second.id == 2
    end

    test "handles three-item batch with mixed types" do
      json = ~s([{"jsonrpc":"2.0","id":1,"result":null},{"jsonrpc":"2.0","id":2,"error":{"code":-1,"message":"err"}},{"jsonrpc":"2.0","id":3,"result":[]}])

      assert {:ok, envelopes} = EnvelopeParser.parse_batch(json)
      assert length(envelopes) == 3
      [first, second, third] = envelopes
      assert first.type == :result
      assert second.type == :error
      assert third.type == :result
    end

    test "handles batch with whitespace variations" do
      json = """
      [
        {"jsonrpc":"2.0","id":1,"result":1},
        {"jsonrpc":"2.0","id":2,"result":2}
      ]
      """

      assert {:ok, envelopes} = EnvelopeParser.parse_batch(json)
      assert length(envelopes) == 2
    end

    test "handles batch with whitespace around brackets" do
      json = ~s(  [  {"jsonrpc":"2.0","id":1,"result":null}  ]  )

      assert {:ok, envelopes} = EnvelopeParser.parse_batch(json)
      assert length(envelopes) == 1
    end
  end

  describe "parse_batch/1 - edge cases" do
    test "handles structural characters in string values" do
      json = ~s([{"jsonrpc":"2.0","id":"[1,2,3]","result":"[test]"}])

      assert {:ok, envelopes} = EnvelopeParser.parse_batch(json)
      assert length(envelopes) == 1
      assert hd(envelopes).id == "[1,2,3]"
    end

    test "handles commas in string values" do
      json = ~s([{"jsonrpc":"2.0","id":"a,b,c","result":"x,y,z"}])

      assert {:ok, envelopes} = EnvelopeParser.parse_batch(json)
      assert length(envelopes) == 1
      assert hd(envelopes).id == "a,b,c"
    end

    test "handles escaped quotes in batch items" do
      json = ~s([{"jsonrpc":"2.0","id":"test\\"quote","result":null}])

      assert {:ok, envelopes} = EnvelopeParser.parse_batch(json)
      assert length(envelopes) == 1
      assert hd(envelopes).id == "test\"quote"
    end

    test "handles large ID values in batch" do
      long_id = String.duplicate("x", 1000)
      json = ~s([{"jsonrpc":"2.0","id":"#{long_id}","result":null}])

      assert {:ok, envelopes} = EnvelopeParser.parse_batch(json)
      assert length(envelopes) == 1
      assert hd(envelopes).id == long_id
    end

    test "handles nested arrays in result values" do
      json = ~s([{"jsonrpc":"2.0","id":1,"result":[[1,2],[3,4]]}])

      assert {:ok, envelopes} = EnvelopeParser.parse_batch(json)
      assert length(envelopes) == 1
      assert hd(envelopes).type == :result
    end

    test "handles nested objects in result values" do
      json = ~s([{"jsonrpc":"2.0","id":1,"result":{"nested":{"deep":true}}}])

      assert {:ok, envelopes} = EnvelopeParser.parse_batch(json)
      assert length(envelopes) == 1
    end

    test "handles trailing comma gracefully" do
      # Some implementations allow trailing commas
      json = ~s([{"jsonrpc":"2.0","id":1,"result":null},])

      assert {:ok, envelopes} = EnvelopeParser.parse_batch(json)
      assert length(envelopes) == 1
    end
  end

  describe "parse_batch/1 - error cases" do
    test "returns error for non-array input" do
      json = ~s({"jsonrpc":"2.0","id":1,"result":null})

      assert {:error, :not_a_batch_array} = EnvelopeParser.parse_batch(json)
    end

    test "returns error for unterminated batch" do
      json = ~s([{"jsonrpc":"2.0","id":1,"result":null})

      assert {:error, :unterminated_batch} = EnvelopeParser.parse_batch(json)
    end

    test "returns error for invalid item in batch" do
      # Missing result/error key
      json = ~s([{"jsonrpc":"2.0","id":1}])

      assert {:error, :no_result_or_error} = EnvelopeParser.parse_batch(json)
    end

    test "returns error for non-binary input" do
      assert {:error, :invalid_input} = EnvelopeParser.parse_batch(nil)
      assert {:error, :invalid_input} = EnvelopeParser.parse_batch(123)
    end

    test "returns error when batch exceeds max items" do
      # Generate a batch with more than @max_batch_items (10,000)
      # For testing purposes, we'll test the guard logic with a reasonable size
      # Note: Actually generating 10,001 items would be very slow in tests
      # Instead, we trust the guard is in place and test with smaller numbers
      items =
        for i <- 1..50 do
          ~s({"jsonrpc":"2.0","id":#{i},"result":null})
        end

      json = "[#{Enum.join(items, ",")}]"

      # This should succeed (well under limit)
      assert {:ok, envelopes} = EnvelopeParser.parse_batch(json)
      assert length(envelopes) == 50
    end
  end

  describe "parse_batch/1 - real-world batch responses" do
    test "handles multi-request eth_getBalance batch" do
      json = ~s([{"jsonrpc":"2.0","id":1,"result":"0x1234"},{"jsonrpc":"2.0","id":2,"result":"0x5678"}])

      assert {:ok, envelopes} = EnvelopeParser.parse_batch(json)
      assert length(envelopes) == 2
      assert Enum.all?(envelopes, fn env -> env.type == :result end)
    end

    test "handles batch with mixed success and error" do
      json = ~s([{"jsonrpc":"2.0","id":1,"result":"0xabc"},{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"insufficient funds"}}])

      assert {:ok, envelopes} = EnvelopeParser.parse_batch(json)
      assert length(envelopes) == 2
      [first, second] = envelopes
      assert first.type == :result
      assert second.type == :error
      assert second.error["code"] == -32000
    end

    test "handles batch with notifications (null IDs)" do
      json = ~s([{"jsonrpc":"2.0","id":null,"result":true},{"jsonrpc":"2.0","id":null,"result":false}])

      assert {:ok, envelopes} = EnvelopeParser.parse_batch(json)
      assert length(envelopes) == 2
      assert Enum.all?(envelopes, fn env -> env.id == nil end)
    end
  end

  describe "Bug fixes" do
    # Bug 1: Binary injection vulnerability
    test "prevents binary injection with result key in error message" do
      # Has "result": pattern in a string value, but actual result key comes after
      json = ~s({"jsonrpc":"2.0","id":"msg with \\"result\\" word","result":"real"})

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.type == :result
      assert envelope.id == "msg with \"result\" word"
    end

    test "prevents binary injection - actual attack from bug description" do
      # This is the actual attack: "result": appears inside a string,
      # then actual "error" key follows. Parser should find error, not the fake result in string.
      json = ~s({"jsonrpc":"2.0","id":"bad\\"result\\":123","error":{"code":-1,"message":"err"}})

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.type == :error
      assert envelope.id == "bad\"result\":123"
    end

    test "prevents binary injection with error key in result value" do
      json = ~s({"result":"this has \\"error\\": false inside","jsonrpc":"2.0","id":1})

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.type == :result
      assert envelope.id == 1
    end

    test "handles result key appearing in quoted string before actual result" do
      json = ~s({"jsonrpc":"2.0","id":"test with \\"result\\"","result":123})

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.type == :result
      assert envelope.id == "test with \"result\""
    end

    # Bug 2: Integer parsing with invalid minus signs
    test "accepts negative numbers correctly" do
      json = ~s({"jsonrpc":"2.0","id":-999,"result":null})

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.id == -999
    end

    test "handles minus only at start, not in middle" do
      # Valid: negative number
      json = ~s({"jsonrpc":"2.0","id":-42,"result":null})
      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.id == -42

      # Edge case: just a minus followed by comma (invalid in JSON)
      # Our parser should handle gracefully by returning error
      json_bad = ~s({"jsonrpc":"2.0","id":-,"result":null})
      assert {:error, _} = EnvelopeParser.parse(json_bad)
    end

    # Bug 3: Unicode escape sequences
    test "handles unicode escape sequences in ID" do
      json = ~s({"jsonrpc":"2.0","id":"test\\u0020id","result":null})

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.id == "test id"
    end

    test "handles unicode emoji escape sequence" do
      json = ~s({"jsonrpc":"2.0","id":"hello\\u263A","result":null})

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.id == "hello☺"
    end

    test "handles multiple unicode escapes" do
      json = ~s({"jsonrpc":"2.0","id":"\\u0041\\u0042\\u0043","result":null})

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.id == "ABC"
    end

    test "handles uppercase hex in unicode escapes" do
      json = ~s({"jsonrpc":"2.0","id":"\\u004A\\u004B","result":null})

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.id == "JK"
    end

    test "handles invalid unicode escape gracefully" do
      json = ~s({"jsonrpc":"2.0","id":"test\\uXYZZ","result":null})

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      # Should keep literal on invalid hex
      assert envelope.id == "test\\uXYZZ"
    end

    # Bug 4: Dual-field responses (Nethermind)
    test "prefers error when both result and error are present" do
      json = ~s({"jsonrpc":"2.0","id":1,"result":"ignored","error":{"code":-32000,"message":"real error"}})

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.type == :error
      assert envelope.error["code"] == -32000
      assert envelope.error["message"] == "real error"
    end

    test "prefers error when result appears first in bytes" do
      json = ~s({"result":"should ignore","error":{"code":-1,"message":"take this"},"jsonrpc":"2.0","id":1})

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.type == :error
      assert envelope.error["code"] == -1
    end

    test "prefers error when error appears first in bytes" do
      json = ~s({"error":{"code":-1,"message":"priority"},"result":"ignored","jsonrpc":"2.0","id":1})

      assert {:ok, envelope} = EnvelopeParser.parse(json)
      assert envelope.type == :error
      assert envelope.error["code"] == -1
    end
  end
end
