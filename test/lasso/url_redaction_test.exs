defmodule Lasso.URLRedactionTest do
  use ExUnit.Case, async: true

  alias Lasso.URLMask

  test "diagnostics preserve the origin without credential-bearing components" do
    for url <- [
          "https://user:password@rpc.example:8443/v2/foo?key=foo#secret",
          "https://rpc.example:8443/a.b.c?key=foo&key=bar",
          "https://rpc.example:8443/a%2Fb?unknown=ab",
          "https://rpc.example:8443/short",
          "https://rpc.example:8443/abcdefgh",
          "https://rpc.example:8443/foo?apiKey=x"
        ] do
      assert URLMask.redact(url) == "https://rpc.example:8443"
      assert URLMask.redact(URLMask.redact(url)) == URLMask.redact(url)
    end

    assert URLMask.redact("wss://user:secret@rpc.example/rpc") == "wss://rpc.example"
  end

  test "malformed or unsupported URLs never pass through diagnostic output" do
    for url <- ["https://[bad/foo?key=foo", "not a url", "https:///foo", "file:///secret", 42] do
      assert URLMask.redact(url) == "[FILTERED_URL]"
    end

    assert URLMask.redact(nil) == nil
  end

  test "credential punctuation is consumed rather than left in diagnostic text" do
    for path <- ["a)b]c}d", "a'b", "a\"b"] do
      output = URLMask.mask_in_string("failed https://rpc.example/#{path} next")
      refute output =~ path
      refute output =~ "b"
      assert output =~ "next"
    end
  end

  test "embedded URLs use the same complete projection" do
    assert URLMask.mask_in_string("failed https://user:pass@rpc.example/a.b?key=foo next") ==
             "failed https://rpc.example next"

    assert URLMask.mask_in_string("failed WSS://rpc.example/short") == "failed wss://rpc.example"
    assert URLMask.mask_in_string("no URL here") == "no URL here"
  end
end
