defmodule LassoWeb.Plugs.RequestTimingPlugTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Lasso.RPC.RequestContext
  alias LassoWeb.Plugs.RequestTimingPlug

  test "records response-boundary timing without executing observability handlers" do
    test_pid = self()
    handler_id = "request-timing-no-sync-sink-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:lasso, :observability, :request_completed],
        fn _event, _measurements, _metadata, _config ->
          send(test_pid, :synchronous_observability_handler_ran)
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    ctx = RequestContext.new(1, "eth_blockNumber", [])

    response =
      conn(:post, "/rpc/1")
      |> RequestTimingPlug.call([])
      |> put_private(:lasso_request_context, ctx)
      |> send_resp(204, "")

    assert is_float(RequestTimingPlug.get_e2e_latency_ms(response))
    refute_receive :synchronous_observability_handler_ran, 0
  end
end
