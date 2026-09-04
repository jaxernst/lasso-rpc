defmodule Lasso.BlockSync.ObservationProjectionTest do
  use ExUnit.Case, async: true

  alias Lasso.BlockSync.ObservationProjection

  test "credits a fresh HTTP sample for elapsed blocks within its observation window" do
    observation = %{
      height: 1_000,
      lag: -200,
      source: :http,
      observed_at_ms: 980_000,
      stale_after_ms: 180_000
    }

    assert %{
             raw_height: 1_000,
             height: 1_200,
             raw_lag: -200,
             lag: 0,
             credit_blocks: 200,
             estimated?: true,
             evidence: :estimated
           } = ObservationProjection.project(observation, 100, 1_000_000)
  end

  test "caps HTTP credit at the explicit observation window" do
    observation = %{
      height: 300,
      lag: -700,
      source: :http,
      observed_at_ms: 900_000,
      stale_after_ms: 300_000,
      credit_window_ms: 60_000
    }

    assert ObservationProjection.projected_lag(observation, 100, 1_000_000) == -100
  end

  test "never infers a sampled provider past observed evidence" do
    observation = %{
      height: 995,
      lag: -5,
      source: :http,
      observed_at_ms: 900_000,
      stale_after_ms: 180_000
    }

    assert %{height: 1_000, lag: 0, credit_blocks: 5} =
             ObservationProjection.project(observation, 100, 1_000_000)
  end

  test "stale samples receive no advancement credit" do
    observation = %{
      height: 900,
      lag: -100,
      source: :http,
      observed_at_ms: 819_999,
      stale_after_ms: 180_000
    }

    assert %{height: 900, lag: -100, credit_blocks: 0, evidence: :stale} =
             ObservationProjection.project(observation, 100, 1_000_000)
  end

  test "clock skew cannot produce negative age or advancement" do
    observation = %{
      height: 995,
      lag: -5,
      source: :http,
      observed_at_ms: 1_000_100,
      stale_after_ms: 180_000
    }

    assert %{height: 995, lag: -5, age_ms: 0, credit_blocks: 0, evidence: :observed} =
             ObservationProjection.project(observation, 100, 1_000_000)
  end

  test "does not estimate event-driven WebSocket observations" do
    observation = %{
      height: 996,
      lag: -4,
      source: :ws,
      observed_at_ms: 900_000,
      stale_after_ms: 180_000
    }

    assert %{height: 996, lag: -4, credit_blocks: 0, evidence: :observed} =
             ObservationProjection.project(observation, 100, 1_000_000)
  end

  test "aligns sampled evidence toward but never beyond an observed height" do
    observation = %{
      height: 1_000,
      source: :http,
      observed_at_ms: 980_000,
      stale_after_ms: 180_000
    }

    assert %{height: 1_200, lag: 0, estimated?: true} =
             ObservationProjection.align_height(observation, 1_200, 100, 1_000_000)
  end

  test "does not move WebSocket evidence while aligning observations" do
    observation = %{
      height: 1_000,
      source: :ws,
      observed_at_ms: 980_000,
      stale_after_ms: 180_000
    }

    assert %{height: 1_000, lag: -200, estimated?: false} =
             ObservationProjection.align_height(observation, 1_200, 100, 1_000_000)
  end
end
