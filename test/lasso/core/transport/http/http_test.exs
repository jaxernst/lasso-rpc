defmodule Lasso.RPC.Transports.HTTPTest do
  use ExUnit.Case, async: false
  import Mox

  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.RPC.Transports.HTTP

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
    assert error.data[:reason] == :no_result_or_error
  end
end
