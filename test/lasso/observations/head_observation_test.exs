defmodule Lasso.Observations.HeadObservationTest do
  use ExUnit.Case, async: true

  alias Lasso.Observations.{HeadObservation, HeadReference}

  test "normalizes a newHeads payload into typed head evidence" do
    assert {:ok, observation} =
             HeadObservation.new_head(
               1,
               "ethereum:primary",
               %{
                 "number" => "0x10",
                 "hash" => "0xabc",
                 "parentHash" => "0xdef",
                 "timestamp" => "0x20"
               },
               1_000
             )

    assert observation.transport == :ws
    assert observation.height == 16
    assert observation.block_hash == "0xabc"
    assert observation.parent_hash == "0xdef"
    assert observation.block_timestamp == 32
  end

  test "rejects malformed or incomplete quantities without raising" do
    assert {:error, {:invalid_quantity, "number", nil}} =
             HeadObservation.new_head(1, "ethereum:primary", %{}, 1_000)

    assert {:error, {:invalid_quantity, "number", "0xnot-hex"}} =
             HeadObservation.new_head(
               1,
               "ethereum:primary",
               %{"number" => "0xnot-hex"},
               1_000
             )
  end

  test "does not accept comparison policy as observation fields" do
    assert {:ok, observation} =
             HeadObservation.http(
               chain_id: 1,
               instance_id: "ethereum:primary",
               height: 100,
               observed_at_ms: 1_000
             )

    refute Map.has_key?(observation, :stale_after_ms)
    refute Map.has_key?(observation, :max_lag_blocks)
  end

  test "rejects a poll reference from another chain or the future" do
    reference = %HeadReference{chain_id: 2, height: 100, revision: 1, captured_at_ms: 900}

    attrs = %{
      chain_id: 1,
      instance_id: "ethereum:primary",
      height: 100,
      observed_at_ms: 1_000,
      poll_references: [reference]
    }

    assert {:error, {:invalid_field, :poll_references, [^reference]}} =
             HeadObservation.http(attrs)

    future_reference = %{reference | chain_id: 1, captured_at_ms: 1_001}

    assert {:error, {:invalid_field, :poll_references, [^future_reference]}} =
             HeadObservation.http(%{attrs | poll_references: [future_reference]})
  end

  test "rejects malformed fields inside a poll reference" do
    attrs = %{
      chain_id: 1,
      instance_id: "ethereum:primary",
      height: 100,
      observed_at_ms: 1_000
    }

    for reference <- [
          %HeadReference{chain_id: 1, height: -1, revision: 1, captured_at_ms: 900},
          %HeadReference{chain_id: 1, height: 100, revision: -1, captured_at_ms: 900},
          %HeadReference{
            chain_id: 1,
            height: 100,
            revision: 1,
            captured_at_ms: 900,
            observed_at_ms: 901
          },
          %HeadReference{
            chain_id: 1,
            height: 100,
            revision: 1,
            captured_at_ms: 900,
            scope_id: "not-a-scope"
          }
        ] do
      assert {:error, {:invalid_field, :poll_references, [^reference]}} =
               HeadObservation.http(Map.put(attrs, :poll_references, [reference]))
    end
  end

  test "rejects negative observation times and WebSocket poll references" do
    attrs = %{
      chain_id: 1,
      instance_id: "ethereum:primary",
      height: 100,
      observed_at_ms: -1
    }

    assert {:error, {:invalid_field, :observed_at_ms, -1}} = HeadObservation.http(attrs)

    reference = %HeadReference{chain_id: 1, height: 100, revision: 1, captured_at_ms: 900}

    assert {:error, {:invalid_field, :poll_references, [^reference]}} =
             HeadObservation.new(
               Map.merge(attrs, %{
                 transport: :ws,
                 observed_at_ms: 1_000,
                 poll_references: [reference]
               })
             )
  end

  test "unary WS evidence accepts request references but rejects malformed attributes" do
    reference = %HeadReference{chain_id: 1, height: 100, revision: 1, captured_at_ms: 900}

    attrs = %{
      chain_id: 1,
      instance_id: "ethereum:primary",
      transport: :ws,
      height: 100,
      observed_at_ms: 1_000,
      attributes: %{collection: :client},
      poll_references: [reference]
    }

    assert {:ok, observation} = HeadObservation.new(attrs)
    assert HeadObservation.request_observation?(observation)
    assert HeadObservation.poll_reference_for(observation, nil) == reference

    for invalid <- [nil, 7, "client"] do
      assert {:error, {:invalid_field, :attributes, ^invalid}} =
               HeadObservation.new(%{attrs | attributes: invalid, poll_references: []})
    end
  end
end
