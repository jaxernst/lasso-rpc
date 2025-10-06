defmodule Lasso.RPC.ContinuityPolicyTest do
  use ExUnit.Case, async: true

  alias Lasso.RPC.ContinuityPolicy

  describe "needed_block_range/4" do
    test "returns :none when head is at last_seen + 1" do
      assert ContinuityPolicy.needed_block_range(100, 101, 32, :best_effort) == {:none}
    end

    test "returns :none when head is behind last_seen" do
      assert ContinuityPolicy.needed_block_range(100, 99, 32, :best_effort) == {:none}
      assert ContinuityPolicy.needed_block_range(100, 100, 32, :best_effort) == {:none}
    end

    test "returns :range when gap is within max_backfill_blocks" do
      assert ContinuityPolicy.needed_block_range(100, 110, 32, :best_effort) ==
               {:range, 101, 110}

      assert ContinuityPolicy.needed_block_range(100, 132, 32, :best_effort) ==
               {:range, 101, 132}
    end

    test "returns :exceeded when gap exceeds max_backfill_blocks" do
      # Gap of 35 blocks (101-135) exceeds max of 32
      assert ContinuityPolicy.needed_block_range(100, 136, 32, :best_effort) ==
               {:exceeded, 101, 132}

      # Gap of 50 blocks exceeds max of 32
      assert ContinuityPolicy.needed_block_range(100, 150, 32, :best_effort) ==
               {:exceeded, 101, 132}
    end

    test "respects max_backfill_blocks limit" do
      # With max=10, gap of 15 should be capped at 10
      assert ContinuityPolicy.needed_block_range(100, 115, 10, :best_effort) ==
               {:exceeded, 101, 110}
    end

    test "returns :none when last_seen is nil" do
      assert ContinuityPolicy.needed_block_range(nil, 100, 32, :best_effort) == {:none}
    end

    test "policy parameter is currently unused but accepted" do
      # Verify all policies produce same result (policy logic not yet differentiated)
      assert ContinuityPolicy.needed_block_range(100, 110, 32, :best_effort) ==
               ContinuityPolicy.needed_block_range(100, 110, 32, :strict_abort)

      assert ContinuityPolicy.needed_block_range(100, 110, 32, :warn_only) ==
               ContinuityPolicy.needed_block_range(100, 110, 32, :best_effort)
    end

    test "edge case: exactly at max_backfill_blocks boundary" do
      # Gap is exactly 32 blocks (101-132)
      assert ContinuityPolicy.needed_block_range(100, 132, 32, :best_effort) ==
               {:range, 101, 132}

      # Gap is 33 blocks (101-133) - exceeds by 1
      assert ContinuityPolicy.needed_block_range(100, 133, 32, :best_effort) ==
               {:exceeded, 101, 132}
    end
  end
end
