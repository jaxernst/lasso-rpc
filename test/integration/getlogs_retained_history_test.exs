defmodule Lasso.Integration.GetLogsRetainedHistoryTest do
  use Lasso.Test.LassoIntegrationCase
  alias Lasso.JSONRPC.Error, as: JError

  test "retained history is not advertised as a request span cap", %{chain: chain} do
    setup_providers([
      %{
        id: "pruned_reader",
        priority: 1,
        background_observations: false,
        behavior:
          {:error,
           JError.new(
             -32_000,
             "requested range is too large: max 128 blocks of history retained; older blocks are pruned"
           )}
      }
    ])

    {:ok, _} = Application.ensure_all_started(:inets)
    port = LassoWeb.Endpoint.config(:http)[:port]
    url = String.to_charlist("http://127.0.0.1:#{port}/rpc/priority/#{chain}")

    body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "eth_getLogs",
        params: [%{fromBlock: "0x1", toBlock: "0x1"}]
      })

    assert {:ok, {{_, 200, _}, _, response}} =
             :httpc.request(:post, {url, [], ~c"application/json", body}, [], [])

    error = Jason.decode!(to_string(response))["error"]
    refute Map.has_key?(error["data"], "max_block_range"), inspect(error)
  end
end
