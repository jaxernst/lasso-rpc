defmodule Lasso.Integration.GetLogsExhaustionTest do
  use Lasso.Test.LassoIntegrationCase

  alias Lasso.JSONRPC.Error, as: JError

  setup do
    previous_audit = Application.get_env(:lasso, :claim_audit_mode, :off)
    Application.put_env(:lasso, :claim_audit_mode, :on)
    on_exit(fn -> Application.put_env(:lasso, :claim_audit_mode, previous_audit) end)
    previous = Application.get_env(:lasso, :method_timeouts, %{})
    Application.put_env(:lasso, :method_timeouts, Map.put(previous, "eth_getLogs", 800))
    on_exit(fn -> Application.put_env(:lasso, :method_timeouts, previous) end)
    :ok
  end

  for {label, failures, expected_cap} <- [
        {"deadline", [10_000, :always_timeout], nil},
        {"claim audit deadline", [10_000, :invalid_params, :always_timeout], nil},
        {"rate limit", [10_000, :rate_limit], nil},
        {"dispatch budget", [10_000, :rate_limit, :rate_limit], nil},
        {"smaller then larger stated number", [10_000, 20_000, :rate_limit], nil},
        {"larger then smaller stated number", [10_000, 5_000, :rate_limit], nil},
        {"uncapped refusal", [10_000, :uncapped, :rate_limit], nil},
        {"no advertised cap", [:uncapped, :rate_limit], nil},
        {"result count", [:result_limit, :rate_limit], nil}
      ] do
    test "HTTP retains range advice after #{label}", %{chain: chain} do
      failures = unquote(Macro.escape(failures))
      observer = self()

      providers =
        failures
        |> Enum.with_index(1)
        |> Enum.map(fn {failure, index} ->
          %{
            id: "reader_#{index}",
            priority: index,
            background_observations: false,
            behavior:
              {:conditional,
               fn method, params, state ->
                 send(observer, {:attempt, index, method})
                 behavior = behavior(failure)

                 Lasso.Testing.MockProviderBehavior.execute_behavior(
                   behavior,
                   method,
                   params,
                   state
                 )
               end}
          }
        end)

      setup_providers(providers)
      {:ok, _} = Application.ensure_all_started(:inets)
      port = LassoWeb.Endpoint.config(:http)[:port]
      url = String.to_charlist("http://127.0.0.1:#{port}/rpc/priority/#{chain}")

      body =
        Jason.encode!(%{
          jsonrpc: "2.0",
          method: "eth_getLogs",
          params: [%{fromBlock: "0x1000000", toBlock: "0x1010000"}],
          id: 1
        })

      assert {:ok, {{_, 200, _}, _, response}} =
               :httpc.request(:post, {url, [], ~c"application/json", body}, [], [])

      error = Jason.decode!(to_string(response))["error"]
      assert error["code"] == -32_005
      assert error["data"]["action"] == "reduce_block_range"

      assert error["data"]["max_block_range"] == unquote(expected_cap)
      refute Map.has_key?(error["data"], "retry_after_ms")
      for index <- 1..length(failures), do: assert_receive({:attempt, ^index, "eth_getLogs"})
    end
  end

  defp behavior(10_000),
    do: {:error, JError.new(-32_000, "range too large, max 10,000 blocks")}

  defp behavior(cap) when is_integer(cap),
    do: {:error, JError.new(-32_000, "range too large, max #{cap} blocks")}

  defp behavior(:invalid_params),
    do: {:error, JError.new(-32_602, "invalid params")}

  defp behavior(:result_limit),
    do: {:error, JError.new(-32_000, "query returned more than 10000 results")}

  defp behavior(:uncapped), do: {:error, JError.new(-32_000, "range too large")}

  defp behavior(:rate_limit),
    do:
      {:error,
       JError.new(-32_005, "rate limit exceeded",
         category: :rate_limit,
         retriable?: true,
         data: %{retry_after_ms: 60_000}
       )}

  defp behavior(:always_timeout), do: :always_timeout
end
