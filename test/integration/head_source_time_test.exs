defmodule Lasso.RPC.HeadSourceTimeTest do
  use ExUnit.Case, async: false

  alias Lasso.BlockSync.{Observation, Registry, Worker}
  alias Lasso.Observations.HeadObservation

  @moduletag :integration

  test "queued source reports retain their observation time without regressing newer head evidence" do
    chain_id = System.unique_integer([:positive])
    instance_id = "source-time-#{chain_id}"
    Registry.clear_chain(chain_id)
    on_exit(fn -> Registry.clear_chain(chain_id) end)
    worker = start_supervised!({Worker, {chain_id, instance_id}})

    http_at = System.system_time(:millisecond) - 300
    ws_at = http_at + 100

    send(worker, {:block_height, instance_id, 100, %{latency_ms: 1, observed_at_ms: http_at}})
    assert {:ok, _status} = GenServer.call(worker, :get_status)

    assert {:ok, %HeadObservation{height: 100, observed_at_ms: ^http_at}} =
             Registry.get_observation(chain_id, instance_id, :http)

    assert {:ok, {100, ^http_at, :http, _metadata}} =
             Registry.get_height(chain_id, instance_id)

    send(worker, {:block_height, instance_id, 105, %{hash: "0xabc", observed_at_ms: ws_at}})
    assert {:ok, _status} = GenServer.call(worker, :get_status)

    send(
      worker,
      {:block_height, instance_id, 101, %{latency_ms: 1, observed_at_ms: http_at + 50}}
    )

    assert {:ok, _status} = GenServer.call(worker, :get_status)

    assert {:ok, %HeadObservation{height: 101, observed_at_ms: newer_http_at}} =
             Registry.get_observation(chain_id, instance_id, :http)

    assert newer_http_at == http_at + 50

    assert {:ok, %HeadObservation{height: 105, observed_at_ms: ^ws_at}} =
             Registry.get_observation(chain_id, instance_id, :ws)

    assert {:ok, {105, ^ws_at, :ws, _metadata}} = Registry.get_height(chain_id, instance_id)
    assert {:ok, 105} = Registry.get_consensus_height(chain_id)

    assert {:ok, %{height: 101, source: :http}} =
             Observation.read_transport(chain_id, instance_id, :http, ws_at, 90_000)

    send(worker, {:block_height, instance_id, 99, %{latency_ms: 1, observed_at_ms: http_at - 50}})
    assert {:ok, _status} = GenServer.call(worker, :get_status)

    assert {:ok, %HeadObservation{height: 101, observed_at_ms: ^newer_http_at}} =
             Registry.get_observation(chain_id, instance_id, :http)

    assert {:ok, {105, ^ws_at, :ws, _metadata}} = Registry.get_height(chain_id, instance_id)

    newer_http_at = ws_at + 100

    send(
      worker,
      {:block_height, instance_id, 102, %{latency_ms: 1, observed_at_ms: newer_http_at}}
    )

    assert {:ok, _status} = GenServer.call(worker, :get_status)

    assert {:ok, {102, ^newer_http_at, :http, _metadata}} =
             Registry.get_height(chain_id, instance_id)

    assert {:ok, %{height: 105, source: :ws}} =
             Observation.read_transport(chain_id, instance_id, :ws, newer_http_at, 90_000)
  end
end
