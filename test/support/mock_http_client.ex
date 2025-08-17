defmodule MockHttpClient do
  @moduledoc """
  Mock HTTP client for testing that provides default implementations
  for common RPC calls to prevent test hanging.
  """

  def request(_config, "eth_chainId", _params, _timeout) do
    {:ok, %{jsonrpc: "2.0", id: 1, result: "0x1"}}
  end

  def request(_config, "eth_blockNumber", _params, _timeout) do
    {:ok, %{jsonrpc: "2.0", id: 1, result: "0x12345"}}
  end

  def request(_config, "eth_getBalance", _params, _timeout) do
    {:ok, %{jsonrpc: "2.0", id: 1, result: "0x1234567890abcdef"}}
  end

  def request(_config, _method, _params, _timeout) do
    {:ok, %{jsonrpc: "2.0", id: 1, result: "0x0"}}
  end
end