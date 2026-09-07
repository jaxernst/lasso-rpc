defmodule Lasso.Core.Support.ErrorNormalizerTest do
  use ExUnit.Case, async: true

  alias Lasso.Core.Support.ErrorNormalizer
  alias Lasso.JSONRPC.Error, as: JError

  describe "normalization preserves classification evidence" do
    test "revert selectors outrank provider overrides for direct and nested errors" do
      opts = [
        provider_id: "normalizer-revert",
        provider_capabilities: %{error_rules: [%{code: -32_000, category: :server_error}]}
      ]

      selector = "0x08c379a0" <> String.duplicate("00", 64)

      for data <- [selector, %{"data" => selector}] do
        response = %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "error" => %{"code" => -32_000, "message" => "opaque vendor error", "data" => data}
        }

        for input <- [response, {:client_error, %{status: 400, body: Jason.encode!(response)}}] do
          error = ErrorNormalizer.normalize(input, opts)
          assert error.category == :execution_revert
          refute error.retriable?
          refute error.breaker_penalty?
          assert error.data == data
        end
      end
    end

    test "all JSON data shapes survive error classification without crashing" do
      opts = [
        provider_id: "normalizer-data",
        provider_capabilities: %{error_rules: [%{code: -32_000, category: :server_error}]}
      ]

      for data <- [[], [%{"detail" => "vendor"}], 7, 1.5, true, false] do
        response = %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "error" => %{"code" => -32_000, "message" => "opaque vendor error", "data" => data}
        }

        for input <- [response, {:server_error, %{status: 500, body: Jason.encode!(response)}}] do
          assert %JError{category: :server_error, data: ^data} =
                   ErrorNormalizer.normalize(input, opts)
        end
      end
    end

    test "normalization carries explicit shared-instance control scope" do
      handler = make_ref()
      owner = self()

      :ok =
        :telemetry.attach(
          handler,
          [:lasso, :error_classification, :classified],
          fn _, _, metadata, _ ->
            if metadata.provider_id == "normalizer-shared",
              do: send(owner, {:classification, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      opts = [
        provider_id: "normalizer-shared",
        shared_instance?: true,
        provider_capabilities: %{error_rules: [%{code: -32_000, category: :rate_limit}]}
      ]

      assert %JError{category: :rate_limit} =
               ErrorNormalizer.normalize(
                 %{"error" => %{"code" => -32_000, "message" => "opaque vendor error"}},
                 opts
               )

      assert_receive {:classification,
                      %{
                        shared_control?: true,
                        control_category: :unclassified_server_error,
                        category: :rate_limit
                      }}
    end
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
      assert jerr.data == nil
      assert jerr.http_status == 400
    end

    test "normalizes invalid-method response without exposing upstream body" do
      upstream_body =
        ~s({"id":1,"jsonrpc":"2.0","error":{"message":"method is not available","code":-32601}})

      payload = %{status: 400, body: upstream_body}

      jerr = ErrorNormalizer.normalize({:client_error, payload}, provider_id: "test")

      assert %JError{} = jerr
      assert jerr.code == -32_601
      assert jerr.message == "method is not available"
      assert jerr.category == :method_not_found
      assert jerr.data == nil
      assert jerr.http_status == 400

      public_error = JError.to_map(jerr)
      refute get_in(public_error, ["data", :body])
      refute get_in(public_error, ["data", "body"])
    end

    test "does not treat an incomplete error object as JSON-RPC" do
      payload = %{
        status: 400,
        body: ~s({"error":{"message":"Missing required field"}})
      }

      jerr = ErrorNormalizer.normalize({:client_error, payload}, provider_id: "test")

      assert %JError{} = jerr
      assert jerr.category == :server_error
      assert jerr.message == "Provider infrastructure error (HTTP 400)"
    end

    test "detects rate limit in JSON-RPC error body" do
      payload = %{
        status: 429,
        body: ~s({"jsonrpc":"2.0","id":1,"error":{"code":-32005,"message":"Rate limit exceeded"}})
      }

      jerr = ErrorNormalizer.normalize({:client_error, payload}, provider_id: "test")

      assert jerr.category == :rate_limit
      assert jerr.retriable? == true
      assert jerr.data == nil
      assert jerr.http_status == 429
    end

    test "preserves authoritative revert data without retaining the raw HTTP body" do
      revert_data = "0x08c379a0" <> String.duplicate("00", 64)

      payload = %{
        status: 400,
        body:
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => "request",
            "error" => %{
              "code" => 3,
              "message" => "execution reverted",
              "data" => revert_data
            }
          })
      }

      jerr = ErrorNormalizer.normalize({:client_error, payload}, provider_id: "test")

      assert %JError{
               code: 3,
               category: :execution_revert,
               retriable?: false,
               breaker_penalty?: false,
               data: ^revert_data,
               http_status: 400
             } = jerr

      assert JError.to_map(jerr)["data"] == revert_data
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

    test "normalizes managed archive gateway errors without penalizing missing data" do
      capabilities = %{
        error_rules: [
          %{code: -32_005, category: :rate_limit},
          %{code: -32_012, category: :capability_violation},
          %{code: -32_014, category: :block_not_available},
          %{code: -32_015, category: :timeout},
          %{code: -32_016, category: :auth_error}
        ]
      }

      opts = [provider_id: "managed-archive", provider_capabilities: capabilities]

      for {code, expected_category, breaker_penalty?} <- [
            {-32_005, :rate_limit, false},
            {-32_012, :capability_violation, false},
            {-32_014, :block_not_available, false},
            {-32_015, :timeout, true},
            {-32_016, :auth_error, true}
          ] do
        assert %JError{
                 category: ^expected_category,
                 breaker_penalty?: ^breaker_penalty?
               } =
                 ErrorNormalizer.normalize(
                   %{"error" => %{"code" => code, "message" => "managed gateway error"}},
                   opts
                 )
      end
    end

    test "preserves positive JSON-RPC application error codes" do
      assert %JError{code: 429, original_code: 429, category: :rate_limit} =
               ErrorNormalizer.normalize(%{
                 "error" => %{"code" => 429, "message" => "Provider rate limit"}
               })

      assert %JError{code: 500, original_code: 500} =
               ErrorNormalizer.normalize(%{
                 "error" => %{"code" => 500, "message" => "Provider application error"}
               })
    end

    test "normalizes monthly capacity exhaustion ahead of a conflicting provider rule" do
      capabilities = %{error_rules: [%{code: 429, category: :capability_violation}]}

      assert %JError{
               code: 429,
               original_code: 429,
               category: :rate_limit,
               retriable?: true,
               breaker_penalty?: false
             } =
               ErrorNormalizer.normalize(
                 %{
                   "error" => %{
                     "code" => 429,
                     "message" =>
                       "Monthly capacity limit exceeded. Upgrade your scaling policy for continued service."
                   }
                 },
                 provider_id: "premium_unichain_1",
                 provider_capabilities: capabilities,
                 shared_instance?: true
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

    test "preserves free-plan capacity evidence through HTTP error normalization" do
      capabilities = %{error_rules: [%{code: 35, category: :capability_violation}]}

      payload = %{
        status: 400,
        body:
          ~s({"jsonrpc":"2.0","error":{"code":35,"message":"chain is not available on free plan, please upgrade to paid plan"},"id":1})
      }

      assert %JError{
               code: 35,
               category: :rate_limit,
               retriable?: true,
               breaker_penalty?: false,
               data: nil,
               http_status: 400
             } =
               ErrorNormalizer.normalize({:client_error, payload},
                 provider_id: "premium_sep_1",
                 provider_capabilities: capabilities,
                 transport: :http
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

  describe "server_error normalization" do
    test "extracts a JSON-RPC error and preserves its data from a 5xx body" do
      error_data = %{"trace" => "0xdeadbeef"}

      payload = %{
        status: 500,
        body:
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "error" => %{"code" => -32_603, "message" => "Internal error", "data" => error_data},
            "id" => 1
          })
      }

      jerr = ErrorNormalizer.normalize({:server_error, payload}, provider_id: "test")

      assert jerr.code == -32_603
      assert jerr.category == :internal_error
      assert jerr.data == error_data
      assert jerr.http_status == 500
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
      assert jerr.code == -32_005
      assert jerr.original_code == 429
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
