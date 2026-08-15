defmodule Lasso.RPC.ParamLimitFailOpenTest do
  use Lasso.Test.LassoIntegrationCase

  alias Lasso.RPC.{RequestOptions, RequestPipeline}

  defp wide_get_logs_params do
    [%{"fromBlock" => "0x0", "toBlock" => "0x2710"}]
  end

  defp execute(chain, params) do
    RequestPipeline.execute_via_channels(chain, "eth_getLogs", params, %RequestOptions{
      profile: "public",
      strategy: :load_balanced,
      timeout_ms: 5_000
    })
  end

  setup %{chain: chain} do
    {:ok, _ids} =
      setup_test_chain_with_providers(
        chain,
        [
          %{
            id: "tight_a",
            behavior: :healthy,
            capabilities: %{limits: %{max_block_range: 10}}
          },
          %{
            id: "tight_b",
            behavior: :healthy,
            capabilities: %{limits: %{max_block_range: 50}}
          }
        ],
        provider_type: :http
      )

    :ok
  end

  test "dispatches with a safety override when limits reject every candidate", %{chain: chain} do
    ref =
      :telemetry_test.attach_event_handlers(self(), [[:lasso, :capabilities, :safety_override]])

    try do
      result = execute(chain, wide_get_logs_params())

      refute match?({:error, %{code: -32_000, message: "No channels available"}, _}, result)
      assert elem(result, 2).attempted_channels != []

      refute_receive {[:lasso, :capabilities, :safety_override], ^ref, _, _}, 50
    after
      :telemetry.detach(ref)
    end
  end
end
