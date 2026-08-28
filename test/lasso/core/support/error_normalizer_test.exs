defmodule Lasso.Core.Support.ErrorNormalizerTest do
  use ExUnit.Case, async: true

  alias Lasso.Core.Support.ErrorNormalizer
  alias Lasso.JSONRPC.Error, as: JError

  test "normalizes transport timeouts with a distinct timeout category" do
    jerr = ErrorNormalizer.normalize(:timeout, provider_id: "test", transport: :http)

    assert jerr.category == :timeout
    assert jerr.retriable?
    assert jerr.breaker_penalty?
  end

  test "normalizes local pool rejection without upstream penalty" do
    jerr =
      ErrorNormalizer.normalize({:local_capacity_rejection, :pool_checkout_failed},
        provider_id: "test",
        transport: :http
      )

    assert jerr.category == :local_capacity_rejection
    assert jerr.retriable?
    refute jerr.breaker_penalty?
  end

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

  describe "provider capability classification" do
    test "applies code-only, message-only, and combined rules through normalization" do
      capabilities = %{
        error_rules: [
          %{code: 35, category: :capability_violation},
          %{message_contains: "credits quota", category: :rate_limit},
          %{code: 30, message_contains: "free tier", category: :auth_error}
        ]
      }

      opts = [provider_id: "custom", provider_capabilities: capabilities]

      assert %JError{category: :capability_violation} =
               ErrorNormalizer.normalize(
                 %{"error" => %{"code" => 35, "message" => "provider-specific"}},
                 opts
               )

      assert %JError{category: :rate_limit, breaker_penalty?: false} =
               ErrorNormalizer.normalize(
                 %{"error" => %{"code" => -32_000, "message" => "Credits quota exhausted"}},
                 opts
               )

      assert %JError{category: :auth_error} =
               ErrorNormalizer.normalize(
                 %{"error" => %{"code" => 30, "message" => "Timeout on the free tier"}},
                 opts
               )
    end

    test "keeps default classification when no provider rule matches" do
      capabilities = %{error_rules: [%{code: 35, category: :rate_limit}]}

      assert %JError{category: :invalid_params} =
               ErrorNormalizer.normalize(
                 %{"error" => %{"code" => -32_602, "message" => "Invalid params"}},
                 provider_id: "custom",
                 provider_capabilities: capabilities
               )
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

  describe "WebSocket upgrade failures" do
    test "keeps throttling retriable without penalizing the circuit" do
      jerr =
        ErrorNormalizer.normalize({:ws_upgrade_error, 429, [{"retry-after", "1"}]},
          provider_id: "custom",
          transport: :ws
        )

      assert jerr.category == :rate_limit
      assert jerr.retriable?
      refute jerr.breaker_penalty?
    end

    test "distinguishes terminal authentication from retriable upstream failure" do
      auth =
        ErrorNormalizer.normalize({:ws_upgrade_error, 403, []},
          provider_id: "custom",
          transport: :ws
        )

      upstream =
        ErrorNormalizer.normalize({:ws_upgrade_error, 503, []},
          provider_id: "custom",
          transport: :ws
        )

      assert auth.category == :client_error
      refute auth.retriable?
      assert upstream.category == :server_error
      assert upstream.retriable?
    end
  end
end
