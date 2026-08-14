defmodule Lasso.RPC.Transports.HTTPTest do
  use ExUnit.Case, async: false
  import Mox

  alias Lasso.Core.Request.RequestOwner
  alias Lasso.Core.Support.ErrorClassifier
  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.RPC.{AttemptIdentity, AttemptTerminal, PreparedRequest}
  alias Lasso.RPC.Transports.HTTP

  defmodule LocalRawClient do
    @spec request(term(), term(), term(), term()) :: {:ok, {:raw, term()}}
    def request(_config, _method, _params, _opts) do
      {:ok, {:raw, Process.get({__MODULE__, :raw})}}
    end
  end

  setup :verify_on_exit!

  setup do
    original_client = Application.get_env(:lasso, :http_client)
    Application.put_env(:lasso, :http_client, Lasso.RPC.HttpClientMock)

    on_exit(fn ->
      if is_nil(original_client) do
        Application.delete_env(:lasso, :http_client)
      else
        Application.put_env(:lasso, :http_client, original_client)
      end
    end)

    :ok
  end

  defp attempt_identity(provider_id) do
    AttemptIdentity.new(
      request_id: "classified-error",
      attempt_id: "classified-error-attempt",
      profile: "public",
      chain_id: 1,
      upstream_instance_id: provider_id,
      transport: :http,
      route_generation: 1,
      circuit_scope: :broad,
      circuit_epoch: 1,
      execution_safety: :replay_safe,
      routing_intent: "default",
      workload_key: "eth_call",
      request_budget_ms: 1_000,
      candidate_admission_count: 1,
      dispatch_count: 1
    )
  end

  test "treats malformed upstream response as retriable server error" do
    channel = %{
      provider_id: "sepolia_onfinality",
      config: %{id: "sepolia_onfinality", url: "https://example.invalid"}
    }

    rpc_request = %{
      "jsonrpc" => "2.0",
      "method" => "net_peerCount",
      "params" => [],
      "id" => "req-1"
    }

    expect(Lasso.RPC.HttpClientMock, :request, fn _config, _method, _params, _opts ->
      # Valid JSON, but invalid JSON-RPC envelope (no "result" or "error")
      {:ok, {:raw, ~s({"jsonrpc":"2.0","id":"req-1","foo":"bar"})}}
    end)

    assert {:error, %JError{} = error, _io_ms} = HTTP.request(channel, rpc_request, 1_000)
    assert error.code == -32_700
    assert error.message == "Invalid JSON-RPC response format"
    assert error.category == :server_error
    assert error.retriable? == true
    assert error.breaker_penalty? == true
    assert error.provider_id == "sepolia_onfinality"
    assert error.data[:reason] == :invalid_envelope
  end

  test "preserves the original large response binary on the same-id HTTP path" do
    channel = %{
      provider_id: "large-response-provider",
      config: %{id: "large-response-provider", url: "https://example.invalid"}
    }

    request_id = "large-response"
    result = String.duplicate("a", 4 * 1_024 * 1_024)
    raw = ~s({"jsonrpc":"2.0","id":"#{request_id}","result":"#{result}"})
    Application.put_env(:lasso, :http_client, LocalRawClient)
    Process.put({LocalRawClient, :raw}, raw)

    on_exit(fn -> Process.delete({LocalRawClient, :raw}) end)

    rpc_request = %{
      "jsonrpc" => "2.0",
      "method" => "eth_call",
      "params" => [],
      "id" => request_id
    }

    assert {:ok, %Lasso.RPC.Response.Success{} = response, _io_ms} =
             HTTP.request(channel, rpc_request, 1_000)

    assert response.id == request_id
    assert response.raw_bytes == raw
    assert :erts_debug.same(response.raw_bytes, raw)
  end

  test "prepared requests validate the transport id and restore an escaped client id" do
    channel = %{
      provider_id: "prepared-provider",
      config: %{id: "prepared-provider", url: "https://example.invalid"}
    }

    client_id = "client-\"\\-id"

    request = %{
      "jsonrpc" => "2.0",
      "method" => "eth_call",
      "params" => [],
      "id" => client_id
    }

    assert {:ok, prepared} = PreparedRequest.new(request, "lasso-http-prepared")

    raw =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => prepared.transport_id,
        "result" => %{"copy" => prepared.transport_id}
      })

    Application.put_env(:lasso, :http_client, LocalRawClient)
    Process.put({LocalRawClient, :raw}, raw)
    on_exit(fn -> Process.delete({LocalRawClient, :raw}) end)

    assert {:ok, %Lasso.RPC.Response.Success{id: ^client_id, raw_bytes: restored}, _io_ms} =
             HTTP.request_prepared(channel, prepared, 1_000)

    assert {:ok,
            %{
              "id" => ^client_id,
              "result" => %{"copy" => "lasso-http-prepared"}
            }} = Jason.decode(restored)
  end

  test "rejects a structurally incomplete response without decoding its result" do
    channel = %{
      provider_id: "malformed-provider",
      config: %{id: "malformed-provider", url: "https://example.invalid"}
    }

    rpc_request = %{
      "jsonrpc" => "2.0",
      "method" => "eth_call",
      "params" => [],
      "id" => "malformed-response"
    }

    raw = ~s({"jsonrpc":"2.0","id":"malformed-response","result":[1}})

    expect(Lasso.RPC.HttpClientMock, :request, fn _config, _method, _params, _opts ->
      {:ok, {:raw, raw}}
    end)

    assert {:error, %JError{code: -32_700} = error, _io_ms} =
             HTTP.request(channel, rpc_request, 1_000)

    assert error.data.reason == :invalid_json
  end

  test "preserves JSON-RPC error data and existing classification semantics" do
    provider_id = "classified-error-provider"

    channel = %{
      provider_id: provider_id,
      config: %{id: provider_id, url: "https://example.invalid"}
    }

    error_data = %{"retry_after" => 50, "scope" => "provider"}

    rpc_request = %{
      "jsonrpc" => "2.0",
      "method" => "eth_call",
      "params" => [],
      "id" => "classified-error"
    }

    raw =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => "classified-error",
        "error" => %{"code" => -32_005, "message" => "rate limited", "data" => error_data}
      })

    expect(Lasso.RPC.HttpClientMock, :request, fn _config, _method, _params, _opts ->
      {:ok, {:raw, raw}}
    end)

    expected =
      ErrorClassifier.classify(-32_005, "rate limited",
        data: error_data,
        provider_id: provider_id
      )

    assert {:error, %JError{} = error, _io_ms} = HTTP.request(channel, rpc_request, 1_000)
    assert error.data == error_data
    assert error.category == expected.category
    assert error.retriable? == expected.retriable?
    assert error.breaker_penalty? == expected.breaker_penalty?
  end

  test "request ownership projects production HTTP errors into canonical classes" do
    provider_id = "owner-classified-provider"

    channel = %{
      provider_id: provider_id,
      config: %{id: provider_id, url: "https://example.invalid"}
    }

    rpc_request = %{
      "jsonrpc" => "2.0",
      "method" => "eth_call",
      "params" => [],
      "id" => "classified-error"
    }

    cases = [
      {-32_602, "invalid params", :deterministic, :return_response, :none},
      {-32_005, "rate limited", :quota, :try_next_candidate, :none},
      {-32_601, "method not found", :capability, :try_next_candidate, :none},
      {-32_002, "provider unavailable", :provider_failure, :try_next_candidate, :failure}
    ]

    for {code, message, category, action, breaker_effect} <- cases do
      raw =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => "classified-error",
          "error" => %{"code" => code, "message" => message}
        })

      expect(Lasso.RPC.HttpClientMock, :request, fn _config, _method, _params, _opts ->
        {:ok, {:raw, raw}}
      end)

      outcome =
        RequestOwner.execute(
          attempt_identity(provider_id),
          System.monotonic_time(:microsecond) + 1_000_000,
          fn -> HTTP.request(channel, rpc_request, 1_000) end
        )

      assert %AttemptTerminal.Response{
               kind: :application_error,
               error_category: ^category
             } = outcome.fact

      assert outcome.projection.recommended_action == action
      assert outcome.projection.breaker_effect == breaker_effect
    end
  end

  test "composes the per-attempt timeout with the shared decision deadline" do
    channel = %{
      provider_id: "deadline-provider",
      config: %{id: "deadline-provider", url: "https://example.invalid"}
    }

    rpc_request = %{
      "jsonrpc" => "2.0",
      "method" => "eth_blockNumber",
      "params" => [],
      "id" => "deadline-response"
    }

    started_before_us = System.monotonic_time(:microsecond)
    decision_deadline_us = started_before_us + 100_000
    previous_deadline = Process.put(:lasso_attempt_deadline_us, decision_deadline_us)

    on_exit(fn ->
      if is_nil(previous_deadline) do
        Process.delete(:lasso_attempt_deadline_us)
      else
        Process.put(:lasso_attempt_deadline_us, previous_deadline)
      end
    end)

    expect(Lasso.RPC.HttpClientMock, :request, fn _config, _method, _params, opts ->
      deadline_us = Keyword.fetch!(opts, :deadline_us)
      assert deadline_us >= started_before_us + 25_000
      assert deadline_us < decision_deadline_us

      {:ok, {:raw, ~s({"jsonrpc":"2.0","id":"deadline-response","result":"0x1"})}}
    end)

    assert {:ok, %Lasso.RPC.Response.Success{}, _io_ms} =
             HTTP.request(channel, rpc_request, 25)
  end
end
