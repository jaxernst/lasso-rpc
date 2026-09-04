defmodule Lasso.BlockSync.ObservationTest do
  use ExUnit.Case, async: false

  alias Lasso.BlockSync.{Observation, Registry}

  setup do
    chain_id = System.unique_integer([:positive])
    Registry.clear_chain(chain_id)
    on_exit(fn -> Registry.clear_chain(chain_id) end)
    {:ok, chain_id: chain_id}
  end

  test "evaluates freshness against the observation-specific window" do
    now_ms = 1_000_000

    assert Observation.fresh?(
             %{observed_at_ms: now_ms - 19_999, stale_after_ms: 20_000},
             now_ms
           )

    refute Observation.fresh?(
             %{observed_at_ms: now_ms - 20_001, stale_after_ms: 20_000},
             now_ms
           )
  end

  test "accepts the timestamp shape used by dashboard observations" do
    assert Observation.fresh?(%{timestamp: 10_000, stale_after_ms: 5_000}, 15_000)
    refute Observation.fresh?(%{timestamp: 10_000, stale_after_ms: 5_000}, 15_001)
  end

  test "uses the freshness contract stored with a worker observation", %{chain_id: chain_id} do
    instance_id = "stored-freshness"
    observed_at_ms = System.system_time(:millisecond) - 45_000

    :ets.insert(
      :block_sync_registry,
      {{:height, chain_id, instance_id}, {123, observed_at_ms, :http, %{stale_after_ms: 90_000}}}
    )

    assert {:ok, %{height: 123, stale_after_ms: 90_000}} =
             Observation.read(chain_id, instance_id)
  end

  test "rejects observations beyond their stored freshness contract", %{chain_id: chain_id} do
    instance_id = "stale-observation"
    observed_at_ms = System.system_time(:millisecond) - 90_001

    :ets.insert(
      :block_sync_registry,
      {{:height, chain_id, instance_id}, {123, observed_at_ms, :ws, %{stale_after_ms: 90_000}}}
    )

    assert {:error, {:stale, %{height: 123}}} = Observation.read(chain_id, instance_id)
  end
end
