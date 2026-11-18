defmodule Lasso.Integration.GetLogsRetainedHistoryTest do
  use Lasso.Test.LassoIntegrationCase
  alias Lasso.JSONRPC.Error, as: JError

  for {label, filter, capabilities} <- [
        {"one block", %{fromBlock: "0x1", toBlock: "0x1"}, %{}},
        {"one block with configured cap", %{fromBlock: "0x1", toBlock: "0x1"},
         %{limits: %{max_block_range: 128}}},
        {"blockHash", %{blockHash: "0x" <> String.duplicate("1", 64)}, %{}}
      ] do
    test "HTTP serves #{label} from a fallback after a retention refusal", %{chain: chain} do
      observer = self()

      setup_providers([
        refusing_provider("pruned_reader", 1, unquote(Macro.escape(capabilities)), observer),
        %{
          id: "history_reader",
          priority: 2,
          background_observations: false,
          behavior: {:conditional, fn "eth_getLogs", _, _ -> {:ok, []} end}
        }
      ])

      assert request(chain, unquote(Macro.escape(filter)))["result"] == []
      assert_receive {:refused, "pruned_reader"}
    end

    test "HTTP gives no range advice when all providers refuse #{label}", %{chain: chain} do
      observer = self()
      caps = unquote(Macro.escape(capabilities))

      setup_providers([
        refusing_provider("pruned_reader", 1, caps, observer),
        refusing_provider("other_reader", 2, caps, observer)
      ])

      error = request(chain, unquote(Macro.escape(filter)))["error"]
      assert is_map(error)
      refute get_in(error, ["data", "action"]) == "reduce_block_range", inspect(error)
      refute get_in(error, ["data", "reason"]) == "log_range_too_large", inspect(error)
      assert_receive {:refused, "pruned_reader"}
      assert_receive {:refused, "other_reader"}
    end
  end

  test "HTTP preserves advice for a real multi-block refusal", %{chain: chain} do
    setup_providers([refusing_provider("limited_reader", 1, %{}, self())])
    error = request(chain, %{fromBlock: "0x1", toBlock: "0x100"})["error"]
    assert error["code"] == -32_005
    assert error["data"]["action"] == "reduce_block_range"
  end

  defp refusing_provider(id, priority, capabilities, observer) do
    %{
      id: id,
      priority: priority,
      background_observations: false,
      capabilities: capabilities,
      behavior:
        {:conditional,
         fn "eth_getLogs", _, _ ->
           send(observer, {:refused, id})

           {:error,
            JError.new(
              -32_000,
              "requested range is too large: max 128 blocks of history retained; older blocks are pruned"
            )}
         end}
    }
  end

  defp request(chain, filter) do
    {:ok, _} = Application.ensure_all_started(:inets)
    port = LassoWeb.Endpoint.config(:http)[:port]
    url = String.to_charlist("http://127.0.0.1:#{port}/rpc/priority/#{chain}")

    body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "eth_getLogs",
        params: [filter]
      })

    assert {:ok, {{_, 200, _}, _, response}} =
             :httpc.request(:post, {url, [], ~c"application/json", body}, [], [])

    Jason.decode!(to_string(response))
  end
end
