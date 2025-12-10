defmodule Lasso.RPC.ResponsePropertyTest do
  @moduledoc """
  Tests for JSON passthrough optimization correctness invariants.

  These tests verify the core guarantees of the passthrough system across
  a wide variety of inputs, simulating property-based testing patterns.
  """

  use ExUnit.Case, async: true

  alias Lasso.RPC.Response
  alias Lasso.RPC.Response.{Success, Error, Batch}
  alias Lasso.RPC.EnvelopeParser

  # ============================================================
  # INVARIANT 1: Raw bytes preservation (bit-for-bit identical)
  # ============================================================

  describe "INVARIANT: raw bytes preservation" do
    test "preserves raw bytes for various ID and result types" do
      test_cases = [
        # Various ID types
        {1, "0x123"},
        {999_999, "0x123"},
        {-42, "result"},
        {"string-id", true},
        {"uuid-abc-123", false},
        {nil, nil},
        # Various result types
        {1, nil},
        {1, true},
        {1, false},
        {1, 42},
        {1, -999},
        {1, 0},
        {1, "simple string"},
        {1, "0x" <> String.duplicate("ab", 32)},
        {1, []},
        {1, [1, 2, 3]},
        {1, ["a", "b", "c"]},
        {1, %{}},
        {1, %{"key" => "value"}},
        {1, %{"hash" => "0xabc", "number" => 123, "nested" => %{"a" => 1}}},
        # Complex results
        {1, Enum.to_list(1..100)},
        {1, %{"logs" => Enum.map(1..10, fn i -> %{"index" => i} end)}}
      ]

      for {id, result} <- test_cases do
        response = %{"jsonrpc" => "2.0", "id" => id, "result" => result}
        raw = Jason.encode!(response)

        {:ok, %Success{raw_bytes: bytes}} = Response.from_bytes(raw)

        assert bytes == raw,
               "raw_bytes must be bit-for-bit identical for id=#{inspect(id)}, result=#{inspect(result)}"
      end
    end
  end

  # ============================================================
  # INVARIANT 2: decode_result matches full JSON decode
  # ============================================================

  describe "INVARIANT: decode_result matches full JSON decode" do
    test "decode_result matches Jason.decode for various results" do
      test_cases = [
        nil,
        true,
        false,
        0,
        42,
        -999,
        "simple",
        "0x123456",
        [],
        [1, 2, 3],
        %{},
        %{"hash" => "0xabc", "number" => 123}
      ]

      for result <- test_cases do
        raw = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => result})

        {:ok, success} = Response.from_bytes(raw)
        {:ok, decoded_result} = Success.decode_result(success)

        {:ok, full_decode} = Jason.decode(raw)

        assert decoded_result == full_decode["result"],
               "decode_result mismatch for result=#{inspect(result)}"
      end
    end
  end

  # ============================================================
  # INVARIANT 3: Parsed ID matches decoded ID
  # ============================================================

  describe "INVARIANT: parsed ID matches decoded ID" do
    test "parsed ID matches decoded ID for various IDs" do
      test_cases = [1, 0, -1, 999_999, "abc", "uuid-123", nil]

      for id <- test_cases do
        raw = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => "ok"})

        {:ok, success} = Response.from_bytes(raw)
        {:ok, full_decode} = Jason.decode(raw)

        assert success.id == full_decode["id"], "ID mismatch for id=#{inspect(id)}"
      end
    end
  end

  # ============================================================
  # INVARIANT 4: EnvelopeParser never crashes
  # ============================================================

  describe "INVARIANT: EnvelopeParser never crashes" do
    test "parse returns tuple (not crash) for malformed inputs" do
      malformed_inputs = [
        "",
        "not json",
        "{",
        "}",
        "[]",
        "null",
        "true",
        "123",
        ~s({"jsonrpc":"2.0"}),
        ~s({"id":1}),
        ~s({"result":"ok"}),
        ~s({"jsonrpc":"2.0","id":1}),
        String.duplicate("x", 10_000),
        :binary.copy(<<0>>, 1000),
        :binary.copy(<<255>>, 1000),
        ~s({"jsonrpc":"2.0","id":1,"result":{"key":"val) <> String.duplicate("x", 5000)
      ]

      for input <- malformed_inputs do
        result = EnvelopeParser.parse(input)

        assert match?({:ok, _}, result) or match?({:error, _}, result),
               "parse must return {:ok, _} or {:error, _}, got: #{inspect(result)}"
      end
    end

    test "parse_batch returns tuple (not crash) for various inputs" do
      inputs = [
        "",
        "not json",
        "[",
        "]",
        "{}",
        ~s([{"jsonrpc":"2.0","id":1}]),
        ~s([{"jsonrpc":"2.0","id":1,"result":"ok"),
        String.duplicate("[", 100)
      ]

      for input <- inputs do
        result = EnvelopeParser.parse_batch(input)

        assert match?({:ok, _}, result) or match?({:error, _}, result),
               "parse_batch must return {:ok, _} or {:error, _} for input, got: #{inspect(result)}"
      end
    end
  end

  # ============================================================
  # INVARIANT 5: Batch split preserves item bytes exactly
  # ============================================================

  describe "INVARIANT: batch split preserves item bytes" do
    test "batch items have identical bytes to originals" do
      items = [
        ~s({"jsonrpc":"2.0","id":1,"result":"first"}),
        ~s({"jsonrpc":"2.0","id":2,"result":123}),
        ~s({"jsonrpc":"2.0","id":3,"result":null}),
        ~s({"jsonrpc":"2.0","id":4,"result":[1,2,3]}),
        ~s({"jsonrpc":"2.0","id":5,"result":{"key":"value"}})
      ]

      batch_json = "[" <> Enum.join(items, ",") <> "]"

      {:ok, envelopes} = EnvelopeParser.parse_batch(batch_json)

      assert length(envelopes) == length(items)

      Enum.zip(envelopes, items)
      |> Enum.each(fn {envelope, original_item} ->
        assert envelope.raw_bytes == original_item,
               "Item bytes must be preserved exactly"
      end)
    end

    test "batch with whitespace preserves trimmed items" do
      item1 = ~s({"jsonrpc":"2.0","id":1,"result":"a"})
      item2 = ~s({"jsonrpc":"2.0","id":2,"result":"b"})
      batch_json = "[ #{item1} , #{item2} ]"

      {:ok, envelopes} = EnvelopeParser.parse_batch(batch_json)

      assert length(envelopes) == 2
      assert Enum.at(envelopes, 0).raw_bytes == item1
      assert Enum.at(envelopes, 1).raw_bytes == item2
    end
  end

  # ============================================================
  # INVARIANT 6: Batch reconstruction produces valid JSON
  # ============================================================

  describe "INVARIANT: batch reconstruction produces valid JSON" do
    test "reconstructed batch is valid JSON array" do
      results = [nil, true, 42, "string", [1, 2], %{"k" => "v"}]

      {items, ids} =
        results
        |> Enum.with_index(1)
        |> Enum.map(fn {result, idx} ->
          raw = Jason.encode!(%{"jsonrpc" => "2.0", "id" => idx, "result" => result})
          {:ok, success} = Response.from_bytes(raw)
          {success, idx}
        end)
        |> Enum.unzip()

      {:ok, batch} = Batch.build(items, ids)
      {:ok, bytes} = Batch.to_bytes(batch)

      assert {:ok, decoded} = Jason.decode(bytes), "Batch output must be valid JSON"
      assert is_list(decoded)
      assert length(decoded) == length(results)
    end

    test "mixed success/error batch produces valid JSON" do
      success1 = %Success{
        id: 1,
        jsonrpc: "2.0",
        raw_bytes: ~s({"jsonrpc":"2.0","id":1,"result":"ok"})
      }

      error2 = %Error{
        id: 2,
        jsonrpc: "2.0",
        error: Lasso.JSONRPC.Error.new(-32600, "Invalid"),
        raw_bytes: nil
      }

      success3 = %Success{
        id: 3,
        jsonrpc: "2.0",
        raw_bytes: ~s({"jsonrpc":"2.0","id":3,"result":[1,2,3]})
      }

      {:ok, batch} = Batch.build([success1, error2, success3], [1, 2, 3])
      {:ok, bytes} = Batch.to_bytes(batch)

      assert {:ok, decoded} = Jason.decode(bytes)
      assert length(decoded) == 3
      assert Enum.at(decoded, 0)["result"] == "ok"
      assert Enum.at(decoded, 1)["error"]["code"] == -32600
      assert Enum.at(decoded, 2)["result"] == [1, 2, 3]
    end
  end

  # ============================================================
  # INVARIANT 7: Key order independence
  # ============================================================

  describe "INVARIANT: key order independence" do
    @key_orders [
      ~s({"jsonrpc":"2.0","id":1,"result":"ok"}),
      ~s({"result":"ok","jsonrpc":"2.0","id":1}),
      ~s({"id":1,"result":"ok","jsonrpc":"2.0"}),
      ~s({"result":"ok","id":1,"jsonrpc":"2.0"}),
      ~s({"id":1,"jsonrpc":"2.0","result":"ok"}),
      ~s({"jsonrpc":"2.0","result":"ok","id":1})
    ]

    for {json, idx} <- Enum.with_index(@key_orders) do
      test "parse succeeds for key order variant ##{idx}" do
        json = unquote(json)

        assert {:ok, envelope} = EnvelopeParser.parse(json)
        assert envelope.id == 1
        assert envelope.type == :result
      end
    end
  end

  # ============================================================
  # INVARIANT 8: Error responses are fully parsed
  # ============================================================

  describe "INVARIANT: error responses are fully parsed" do
    @error_cases [
      {-32700, "Parse error"},
      {-32600, "Invalid Request"},
      {-32601, "Method not found"},
      {-32602, "Invalid params"},
      {-32603, "Internal error"},
      {-32000, "Server error"},
      {3, "Execution reverted"}
    ]

    for {code, message} <- @error_cases do
      test "error response with code=#{code} is fully parsed" do
        code = unquote(code)
        message = unquote(message)

        response = %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "error" => %{"code" => code, "message" => message}
        }

        raw = Jason.encode!(response)

        assert {:ok, %Error{} = error_resp} = Response.from_bytes(raw)
        assert error_resp.id == 1
        assert error_resp.error.code == code
        assert error_resp.error.message == message
      end
    end
  end

  # ============================================================
  # INVARIANT 9: Response.to_bytes roundtrip for Success
  # ============================================================

  describe "INVARIANT: Response.to_bytes roundtrip" do
    @roundtrip_cases [
      %{"jsonrpc" => "2.0", "id" => 1, "result" => "0x123"},
      %{"jsonrpc" => "2.0", "id" => 999, "result" => nil},
      %{"jsonrpc" => "2.0", "id" => "abc", "result" => [1, 2, 3]},
      %{"jsonrpc" => "2.0", "id" => nil, "result" => %{"hash" => "0xabc"}}
    ]

    for {response, idx} <- Enum.with_index(@roundtrip_cases) do
      test "to_bytes returns identical bytes for case ##{idx}" do
        response = unquote(Macro.escape(response))
        raw = Jason.encode!(response)

        {:ok, success} = Response.from_bytes(raw)
        {:ok, output_bytes} = Response.to_bytes(success)

        assert output_bytes == raw, "to_bytes must return identical bytes"
      end
    end
  end

  # ============================================================
  # INVARIANT 10: Large response handling
  # ============================================================

  describe "INVARIANT: large response handling" do
    test "handles large array result without performance degradation" do
      # Generate a large array (simulating eth_getLogs)
      large_array = Enum.map(1..1000, fn i -> %{"index" => i, "data" => "0x#{i}"} end)
      response = %{"jsonrpc" => "2.0", "id" => 1, "result" => large_array}
      raw = Jason.encode!(response)

      # Parse should be fast (envelope only)
      {time_us, {:ok, success}} = :timer.tc(fn -> Response.from_bytes(raw) end)

      # Should complete in under 1ms (envelope parsing is O(1))
      assert time_us < 1000, "Envelope parsing took #{time_us}us, expected < 1000us"
      assert Success.response_size(success) == byte_size(raw)
      assert success.raw_bytes == raw
    end

    test "decode_result works correctly for large responses" do
      large_array = Enum.to_list(1..1000)
      raw = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => large_array})

      {:ok, success} = Response.from_bytes(raw)
      {:ok, decoded} = Success.decode_result(success)

      assert decoded == large_array
    end
  end
end
