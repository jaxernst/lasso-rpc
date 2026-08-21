defmodule Lasso.JSON.DecoderTest do
  use ExUnit.Case, async: true

  alias Lasso.JSON.Decoder

  test "decodes JSON-RPC values with string keys" do
    assert %{
             "id" => nil,
             "jsonrpc" => "2.0",
             "method" => "eth_call",
             "params" => [%{"data" => "0x", "to" => "0x1"}, 1.5, -0.0, 1000.0]
           } =
             Decoder.decode!(
               ~s({"jsonrpc":"2.0","id":null,"method":"eth_call","params":[{"to":"0x1","data":"0x"},1.5,-0.0,1e3]})
             )
  end

  test "rejects malformed input" do
    assert_raise ArgumentError, fn -> Decoder.decode!(~s({"id":)) end
  end

  test "matches the existing decoder for accepted JSON values" do
    documents = [
      ~s(null),
      ~s(true),
      ~s(false),
      ~s(0),
      ~s(-9223372036854775809),
      ~s(1.25e-12),
      ~s("plain"),
      ~s("escaped \\n \\t \\u263a \\ud83d\\ude80"),
      ~s([null,true,false,1,2.5,"three",{"four":4}]),
      ~s({"duplicate":1,"duplicate":2}),
      ~s({"nested":{"array":[1,{"value":null}]}}  \n\t)
    ]

    Enum.each(documents, fn document ->
      assert Decoder.decode!(document) == Jason.decode!(document)
    end)
  end

  test "rejects trailing values and invalid UTF-8" do
    assert_raise ArgumentError, fn -> Decoder.decode!(~s({"id":1} true)) end
    assert_raise ArgumentError, fn -> Decoder.decode!(<<34, 255, 34>>) end
  end
end
