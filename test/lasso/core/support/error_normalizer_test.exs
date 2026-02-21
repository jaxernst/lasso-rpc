defmodule Lasso.Core.Support.ErrorNormalizerTest do
  use ExUnit.Case, async: true

  alias Lasso.Core.Support.ErrorNormalizer
  alias Lasso.JSONRPC.Error, as: JError

  describe "client_error with JSON-RPC body" do
    test "classifies normally when body is a valid JSON-RPC error" do
      payload = %{
        status: 400,
        body: ~s({"jsonrpc":"2.0","error":{"code":-32602,"message":"Invalid params"},"id":1})
      }

      jerr = ErrorNormalizer.normalize({:client_error, payload}, provider_id: "test")

      assert %JError{} = jerr
      assert jerr.category == :invalid_params
      assert jerr.retriable? == false
      assert jerr.code == -32_602
    end

    test "classifies normally when body has error with message but no code" do
      payload = %{
        status: 400,
        body: ~s({"error":{"message":"Missing required field"}})
      }

      jerr = ErrorNormalizer.normalize({:client_error, payload}, provider_id: "test")

      assert %JError{} = jerr
      assert jerr.message == "Missing required field"
    end

    test "detects rate limit in JSON-RPC error body" do
      payload = %{
        status: 429,
        body: ~s({"error":{"code":-32005,"message":"Rate limit exceeded"}})
      }

      jerr = ErrorNormalizer.normalize({:client_error, payload}, provider_id: "test")

      assert jerr.category == :rate_limit
      assert jerr.retriable? == true
    end
  end

  describe "client_error with non-JSON-RPC body (reclassification)" do
    test "reclassifies dRPC-style gateway rejection as server_error" do
      payload = %{
        status: 400,
        body: ~s({"message":"Invalid request"}\n)
      }

      jerr = ErrorNormalizer.normalize({:client_error, payload}, provider_id: "base_drpc")

      assert %JError{} = jerr
      assert jerr.category == :server_error
      assert jerr.retriable? == true
      assert jerr.breaker_penalty? == true
      assert jerr.code == -32_002
      assert jerr.message =~ "HTTP 400"
    end

    test "reclassifies HTML error page as server_error" do
      payload = %{
        status: 403,
        body: "<html><body><h1>403 Forbidden</h1></body></html>"
      }

      jerr = ErrorNormalizer.normalize({:client_error, payload}, provider_id: "test")

      assert jerr.category == :server_error
      assert jerr.retriable? == true
      assert jerr.breaker_penalty? == true
    end

    test "reclassifies empty body as server_error" do
      payload = %{status: 400, body: ""}

      jerr = ErrorNormalizer.normalize({:client_error, payload}, provider_id: "test")

      assert jerr.category == :server_error
      assert jerr.retriable? == true
    end

    test "reclassifies invalid JSON body as server_error" do
      payload = %{status: 400, body: "not json at all"}

      jerr = ErrorNormalizer.normalize({:client_error, payload}, provider_id: "test")

      assert jerr.category == :server_error
      assert jerr.retriable? == true
    end

    test "reclassifies non-JSON-RPC JSON body as server_error" do
      payload = %{status: 401, body: ~s({"error": "invalid api key"})}

      jerr = ErrorNormalizer.normalize({:client_error, payload}, provider_id: "test")

      assert jerr.category == :server_error
      assert jerr.retriable? == true
    end

    test "preserves original payload in data field" do
      payload = %{status: 400, body: ~s({"message":"Invalid request"})}

      jerr = ErrorNormalizer.normalize({:client_error, payload}, provider_id: "test")

      assert jerr.data == payload
    end

    test "preserves provider_id and transport" do
      payload = %{status: 400, body: ~s({"message":"Invalid request"})}

      jerr =
        ErrorNormalizer.normalize({:client_error, payload},
          provider_id: "base_drpc",
          transport: :http
        )

      assert jerr.provider_id == "base_drpc"
      assert jerr.transport == :http
    end
  end

  describe "server_error normalization (unchanged)" do
    test "extracts JSON-RPC error from 5xx body" do
      payload = %{
        status: 500,
        body: ~s({"jsonrpc":"2.0","error":{"code":-32603,"message":"Internal error"},"id":1})
      }

      jerr = ErrorNormalizer.normalize({:server_error, payload}, provider_id: "test")

      assert jerr.code == -32_603
      assert jerr.category == :internal_error
    end

    test "uses fallback when 5xx body is not JSON-RPC" do
      payload = %{status: 502, body: "Bad Gateway"}

      jerr = ErrorNormalizer.normalize({:server_error, payload}, provider_id: "test")

      assert jerr.code == -32_002
      assert jerr.message == "Server error"
      assert jerr.category == :server_error
      assert jerr.retriable? == true
    end
  end
end
