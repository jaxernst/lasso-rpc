defmodule MockHttpClient do
  @moduledoc """
  Mock HTTP client for testing that provides default implementations
  for common RPC calls to prevent test hanging.

  Returns raw bytes in the passthrough format: {:ok, {:raw, binary()}}.
  """

  alias Lasso.Core.Support.AttemptLifecycle

  def request(_config, "eth_chainId", _params, opts) do
    AttemptLifecycle.mark_dispatched(Keyword.get(opts, :attempt_dispatch))
    response(opts, "0x1")
  end

  def request(_config, "eth_blockNumber", _params, opts) do
    AttemptLifecycle.mark_dispatched(Keyword.get(opts, :attempt_dispatch))
    response(opts, "0x12345")
  end

  def request(_config, "eth_getBalance", _params, opts) do
    AttemptLifecycle.mark_dispatched(Keyword.get(opts, :attempt_dispatch))
    response(opts, "0x1234567890abcdef")
  end

  def request(_config, _method, _params, opts) do
    AttemptLifecycle.mark_dispatched(Keyword.get(opts, :attempt_dispatch))
    response(opts, "0x0")
  end

  defp response(opts, result) do
    id = Keyword.get(opts, :request_id, 1)
    {:ok, {:raw, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})}}
  end
end
