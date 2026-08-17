defmodule Lasso.Core.Transport.UpstreamResponseTest do
  use ExUnit.Case, async: true

  alias Lasso.Core.Transport.UpstreamResponse
  alias Lasso.Core.Transport.UpstreamResponse.Validated
  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.RPC.Response

  test "accepts one correlated response and restores the client id" do
    raw = ~s({"jsonrpc":"2.0","id":"internal","result":"0x1"})

    assert {:ok, %Response.Success{id: 7} = response} =
             UpstreamResponse.validate_unary(raw, "internal", 7)

    assert {:ok, %{"id" => 7, "result" => "0x1"}} = Jason.decode(response.raw_bytes)
  end

  test "captures a top-level id span during the mode scan and falls back when result comes first" do
    canonical = ~s({"jsonrpc":"2.0","id":"internal","result":"0x1"})

    assert {:ok, %Validated{id: "internal", id_span: {start, length}}} =
             UpstreamResponse.parse_unary(canonical)

    assert binary_part(canonical, start, length) == ~s("internal")

    result_first = ~s({"result":"0x1","id":"internal","jsonrpc":"2.0"})

    assert {:ok, %Validated{id: "internal", id_span: nil}} =
             UpstreamResponse.parse_unary(result_first)

    assert {:ok, %Response.Success{raw_bytes: restored}} =
             UpstreamResponse.validate_unary(result_first, "internal", 9)

    assert {:ok, %{"id" => 9, "result" => "0x1"}} = Jason.decode(restored)
  end

  test "rejects invalid unary envelopes with bounded reasons" do
    vectors = [
      {"not-json", :invalid_json},
      {~s({"jsonrpc":"1.0","id":"internal","result":1}), :unsupported_version},
      {~s({"jsonrpc":"2.0","id":"wrong","result":1}), :id_mismatch},
      {~s({"jsonrpc":"2.0","method":"notice","params":[]}), :unexpected_notification},
      {~s([{"jsonrpc":"2.0","id":"internal","result":1}]), :unexpected_batch},
      {~s({"jsonrpc":"2.0","id":"internal","result":1} trailing), :invalid_json},
      {~s({"jsonrpc":"2.0","id":"internal","result":1,"error":{}}), :invalid_envelope}
    ]

    for {raw, reason} <- vectors do
      assert {:invalid, ^reason} = UpstreamResponse.validate_unary(raw, "internal", 1)
    end
  end

  test "strictly validates the unary JSON-RPC grammar without retaining result values" do
    valid_nested =
      ~s({"jsonrpc":"2.0","result":{"id":"nested","items":[1,{"deep":true}]},"id":"internal"})

    escaped_keys =
      ~S({"json\u0072pc":"2.0","\u0069d":"internal","res\u0075lt":{"ok":true}})

    vectors = [
      {~s({"jsonrpc":"2.0","id":"internal","result":{"ok":true}}), {:ok, :result, "internal"}},
      {valid_nested, {:ok, :result, "internal"}},
      {escaped_keys, {:ok, :result, "internal"}},
      {~s({"jsonrpc":"2.0","id":"internal","error":{"code":-32000,"message":"busy","data":{"secret":"discarded"}}}),
       {:ok, :error, "internal"}},
      {~s({"jsonrpc":"2.0","id":"internal","result":[1,]}), {:invalid, :invalid_json}},
      {~s({"jsonrpc":"2.0","id":"internal","result":") <> <<0xFF>> <> ~s("}),
       {:invalid, :invalid_json}},
      {~S({"jsonrpc":"2.0","id":"internal","result":"\uD800"}), {:invalid, :invalid_json}},
      {~s({"jsonrpc":"2.0","result":{"id":"internal"}}), {:invalid, :invalid_envelope}},
      {~s({"jsonrpc":"2.0","id":"internal","id":"internal","result":1}),
       {:invalid, :invalid_envelope}},
      {~s({"jsonrpc":"2.0","id":"internal","result":1,"error":{"code":-1,"message":"both"}}),
       {:invalid, :invalid_envelope}},
      {~s({"jsonrpc":"2.0","id":"internal","error":{"code":"bad","message":"no"}}),
       {:invalid, :invalid_envelope}},
      {~s({"jsonrpc":"2.0","id":"internal","result":1} trailing), {:invalid, :invalid_json}},
      {~s([{"jsonrpc":"2.0","id":"internal","result":1}]), {:invalid, :unexpected_batch}},
      {~s({"jsonrpc":"2.0","method":"notice","params":[]}), {:legacy, :notification}}
    ]

    Enum.each(vectors, fn
      {raw, {:ok, kind, id}} ->
        assert {:ok, %Validated{kind: ^kind, id: ^id}} = UpstreamResponse.parse_unary(raw)

      {raw, {:invalid, reason}} ->
        assert {:invalid, ^reason, _candidate_id} = UpstreamResponse.parse_unary(raw)

      {raw, expected} ->
        assert expected == UpstreamResponse.parse_unary(raw)
    end)
  end

  test "preserves the full error message and data from the strict OTP pass" do
    oversized_message = String.duplicate("x", 4_096)

    error_data = %{
      "request" => String.duplicate("secret", 10_000),
      "retry_after" => 25,
      "nested" => [%{"missing" => nil}, true, [1, 2, 3]]
    }

    raw =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => "internal",
        "error" => %{
          "code" => -32_000,
          "message" => oversized_message,
          "data" => error_data
        }
      })

    assert {:ok,
            %Validated{
              kind: :error,
              error_message: ^oversized_message,
              error_data: ^error_data
            }} =
             UpstreamResponse.parse_unary(raw)

    assert {:error, %JError{code: -32_000, message: ^oversized_message, data: ^error_data}} =
             UpstreamResponse.validate_unary(raw, "internal", "client")
  end

  test "preserves JSON float and exponent values in nested error data" do
    raw =
      ~s({"jsonrpc":"2.0","id":7,"error":{"code":-32000,"message":"numeric data","data":{"decimal":1.25,"exponent":1e3,"negative_zero":-0.0,"nested":[-2.5E-4,{"value":6.02e23}]}}})

    assert {:error, %JError{data: data}} = UpstreamResponse.validate_unary(raw, 7, 7)
    assert data["decimal"] == 1.25
    assert data["exponent"] == 1.0e3
    assert data["nested"] == [-2.5e-4, %{"value" => 6.02e23}]
    negative_zero = data["negative_zero"]
    assert <<1::1, _magnitude::63>> = <<negative_zero::float>>
  end

  @tag timeout: 10_000
  test "large ignored fields retain bounded scan cost" do
    padding = String.duplicate("x", 100 * 1_024)
    raw = ~s({"jsonrpc":"2.0","id":"internal","padding":"#{padding}","result":"0x1"})

    nested =
      ~s({"jsonrpc":"2.0","id":"internal","padding":{"items":["#{padding}"]},"result":"0x1"})

    assert {:ok, %Validated{kind: :result, id: "internal"}} =
             UpstreamResponse.parse_unary(nested)

    parent = self()

    {worker, monitor} =
      spawn_monitor(fn ->
        {:reductions, before_reductions} = Process.info(self(), :reductions)
        result = UpstreamResponse.parse_unary(raw)
        {:reductions, after_reductions} = Process.info(self(), :reductions)
        send(parent, {:large_ignored_field, result, after_reductions - before_reductions})
      end)

    assert_receive {:large_ignored_field, {:ok, %Validated{kind: :result, id: "internal"}},
                    reductions},
                   5_000

    assert reductions < 50_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
  end

  @tag timeout: 10_000
  test "100 KiB errors avoid the legacy second parse with bounded parser overhead" do
    error_data = "0x" <> String.duplicate("d", 100 * 1_024)

    raw =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 7,
        "error" => %{
          "code" => -32_000,
          "message" => "execution reverted",
          "data" => error_data
        }
      })

    true = Code.ensure_loaded?(Response)
    legacy_decode_mfa = {Response, :from_bytes, 1}
    :erlang.trace_pattern(legacy_decode_mfa, true, [])
    :erlang.trace(self(), true, [:call])

    on_exit(fn ->
      :erlang.trace_pattern(legacy_decode_mfa, false, [])
    end)

    assert {:error, %JError{data: ^error_data}} =
             UpstreamResponse.validate_unary(raw, 7, 7)

    :erlang.trace(self(), false, [:call])
    :erlang.trace_pattern(legacy_decode_mfa, false, [])
    refute_receive {:trace, _pid, :call, {Response, :from_bytes, [_raw]}}, 0

    parent = self()

    {worker, monitor} =
      spawn_monitor(fn ->
        :erlang.garbage_collect()
        {:total_heap_size, before_words} = Process.info(self(), :total_heap_size)
        {:reductions, before_reductions} = Process.info(self(), :reductions)
        started_at_us = System.monotonic_time(:microsecond)
        result = UpstreamResponse.validate_unary(raw, 7, 7)
        elapsed_us = System.monotonic_time(:microsecond) - started_at_us
        {:reductions, after_reductions} = Process.info(self(), :reductions)
        :erlang.garbage_collect()
        {:total_heap_size, after_words} = Process.info(self(), :total_heap_size)

        send(
          parent,
          {:large_error_validation, result, after_words - before_words,
           after_reductions - before_reductions, elapsed_us}
        )
      end)

    assert_receive {:large_error_validation, {:error, %JError{data: ^error_data}}, heap_growth,
                    reductions, elapsed_us},
                   5_000

    assert heap_growth < 50_000
    assert reductions < 50_000
    assert elapsed_us < 500_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
  end

  test "locates only the top-level id span for escaped and repeated spellings" do
    transport_id = "lasso-internal"

    escaped =
      ~S({"jsonrpc":"2.0","\u0069d":"lasso-\u0069nternal","result":{"copy":"lasso-internal"}})

    assert {:transport, %Validated{id: ^transport_id} = validated} =
             UpstreamResponse.parse_ws_frame(escaped)

    assert {:ok, %Response.Success{raw_bytes: restored}} =
             UpstreamResponse.finalize_unary(validated, escaped, transport_id, "client")

    assert {:ok, %{"id" => "client", "result" => %{"copy" => ^transport_id}}} =
             Jason.decode(restored)

    repeated =
      ~s({"result":{"first":"#{transport_id}","nested":{"id":"#{transport_id}"}},"id":"#{transport_id}","jsonrpc":"2.0"})

    assert {:transport, %Validated{id: ^transport_id} = repeated_validation} =
             UpstreamResponse.parse_ws_frame(repeated)

    assert {:ok, %Response.Success{raw_bytes: repeated_restored}} =
             UpstreamResponse.finalize_unary(
               repeated_validation,
               repeated,
               transport_id,
               "client"
             )

    assert {:ok,
            %{
              "id" => "client",
              "result" => %{
                "first" => ^transport_id,
                "nested" => %{"id" => ^transport_id}
              }
            }} = Jason.decode(repeated_restored)
  end

  test "accepts long string and arbitrary-size integer JSON-RPC ids" do
    long_id = String.duplicate("client-id-", 64)
    large_integer_id = String.to_integer(String.duplicate("9", 128))

    for id <- [long_id, large_integer_id] do
      raw = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => %{"ok" => true}})

      assert {:ok, %Response.Success{id: ^id, raw_bytes: ^raw}} =
               UpstreamResponse.validate_unary(raw, id, id)
    end

    refute UpstreamResponse.transport_id?("lasso-" <> String.duplicate("x", 129))
  end

  test "extracts only bounded internal transport ids for correlation" do
    first = "lasso-conn_a-first"
    second = "lasso-conn_a-second"

    assert {:ok, [^first]} =
             UpstreamResponse.extract_transport_ids(
               ~s({"jsonrpc":"2.0","id":"#{first}","result":1})
             )

    assert {:ok, [^first]} =
             UpstreamResponse.extract_transport_ids(
               ~s({"jsonrpc":"2.0","id":"#{first}","result":1} trailing)
             )

    batch =
      Jason.encode!([
        %{"jsonrpc" => "2.0", "id" => first, "result" => 1},
        %{"jsonrpc" => "2.0", "id" => second, "result" => 2}
      ])

    assert {:error, :unattributable} = UpstreamResponse.extract_transport_ids(batch)
    assert {:ok, []} = UpstreamResponse.extract_transport_ids(~s({"id":"client-id","result":1}))
    assert {:error, :unattributable} = UpstreamResponse.extract_transport_ids("not-json")
  end

  test "correlates only one unambiguous top-level transport id" do
    transport_id = "lasso-conn_a-only"

    assert {:error, :unattributable} =
             UpstreamResponse.extract_transport_ids(
               ~s({"id":"#{transport_id}","id":"#{transport_id}","result":1})
             )

    assert {:ok, []} =
             UpstreamResponse.extract_transport_ids(
               ~s({"jsonrpc":"2.0","id":"client","result":{"id":"#{transport_id}"}})
             )

    assert {:error, :unattributable} =
             UpstreamResponse.extract_transport_ids(
               ~s({"jsonrpc":"2.0","meta":{"id":"#{transport_id}"},"result":1)
             )
  end

  @tag timeout: 10_000
  test "large success has bounded retained memory and a generous parser latency ceiling" do
    result = "[" <> String.duplicate("0,", 524_288) <> "0]"
    raw = ~s({"jsonrpc":"2.0","id":"internal","result":#{result}})
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        :erlang.garbage_collect()
        {:total_heap_size, before_words} = :erlang.process_info(self(), :total_heap_size)
        {:reductions, before_reductions} = :erlang.process_info(self(), :reductions)
        started_at = System.monotonic_time(:microsecond)
        validation = UpstreamResponse.validate_unary(raw, "internal", "client")
        elapsed_us = System.monotonic_time(:microsecond) - started_at
        {:reductions, after_reductions} = :erlang.process_info(self(), :reductions)
        :erlang.garbage_collect()
        {:total_heap_size, after_words} = :erlang.process_info(self(), :total_heap_size)

        send(
          parent,
          {:large_validation, validation, after_words - before_words,
           after_reductions - before_reductions, elapsed_us}
        )
      end)

    assert_receive {:large_validation,
                    {:ok, %Response.Success{id: "client", raw_bytes: restored}}, heap_growth,
                    reductions, elapsed_us},
                   5_000

    assert restored ==
             ~s({"jsonrpc":"2.0","id":"client","result":#{result}})

    assert heap_growth < 100_000
    assert reductions < byte_size(raw) * 50
    assert elapsed_us < 2_000_000

    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
  end

  test "same-id HTTP validation returns the exact upstream binary" do
    result = "[" <> String.duplicate("0,", 100_000) <> "0]"
    raw = ~s({"jsonrpc":"2.0","id":77,"result":#{result}})

    assert {:ok, %Response.Success{id: 77, raw_bytes: restored}} =
             UpstreamResponse.validate_unary(raw, 77, 77)

    assert restored === raw
    assert :erts_debug.same(restored, raw)

    assert {:error, %JError{code: -32_000, message: "busy"}} =
             UpstreamResponse.validate_unary(
               ~s({"jsonrpc":"2.0","id":77,"error":{"code":-32000,"message":"busy"}}),
               77,
               77
             )
  end
end
