defmodule Lasso.RPC.ExecutionEnvelopeTest do
  use ExUnit.Case, async: true

  alias Lasso.RPC.ExecutionEnvelope

  test "one absolute deadline bounds every attempt" do
    envelope =
      ExecutionEnvelope.new("request-1", "eth_blockNumber", 100, started_at_us: 1_000_000)

    assert {:ok, first, 60} =
             ExecutionEnvelope.reserve_dispatch(envelope, "upstream-1", :http, 1_000_000)

    assert first.deadline_us == envelope.deadline_us

    assert {:ok, second, 49} =
             ExecutionEnvelope.reserve_dispatch(first, "upstream-2", :http, 1_051_000)

    assert second.deadline_us == envelope.deadline_us

    assert {:error, :deadline_exhausted} =
             ExecutionEnvelope.reserve_dispatch(second, "upstream-3", :http, 1_076_000)
  end

  test "replay-safe work dispatches at most three distinct channels" do
    envelope = ExecutionEnvelope.new("request-1", "eth_call", 1_000, started_at_us: 0)

    assert {:ok, envelope, _} = ExecutionEnvelope.reserve_dispatch(envelope, "one", :http, 0)
    assert {:ok, envelope, _} = ExecutionEnvelope.reserve_dispatch(envelope, "two", :http, 0)
    assert {:ok, envelope, _} = ExecutionEnvelope.reserve_dispatch(envelope, "three", :ws, 0)

    assert {:error, :dispatch_budget_exhausted} =
             ExecutionEnvelope.reserve_dispatch(envelope, "four", :http, 0)
  end

  test "a concrete upstream transport is dispatched once" do
    envelope = ExecutionEnvelope.new("request-1", "eth_call", 1_000, started_at_us: 0)
    assert {:ok, envelope, _} = ExecutionEnvelope.reserve_dispatch(envelope, "one", :http, 0)

    assert {:error, :duplicate_dispatch} =
             ExecutionEnvelope.reserve_dispatch(envelope, "one", :http, 0)
  end

  test "unsafe and unknown methods permit one dispatch" do
    for method <- [
          "eth_sendTransaction",
          "eth_newFilter",
          "eth_getFilterChanges",
          "eth_uninstallFilter",
          "vendor_privateMethod"
        ] do
      envelope = ExecutionEnvelope.new(method, method, 1_000, started_at_us: 0)
      assert {:ok, envelope, _} = ExecutionEnvelope.reserve_dispatch(envelope, "one", :http, 0)

      assert {:error, :dispatch_budget_exhausted} =
               ExecutionEnvelope.reserve_dispatch(envelope, "two", :http, 0)
    end
  end

  test "raw transactions remain single-dispatch until broadcast arbitration owns completion" do
    envelope = ExecutionEnvelope.new("tx", "eth_sendRawTransaction", 1_000, started_at_us: 0)
    assert {:ok, envelope, _} = ExecutionEnvelope.reserve_dispatch(envelope, "one", :http, 0)

    assert {:error, :dispatch_budget_exhausted} =
             ExecutionEnvelope.reserve_dispatch(envelope, "two", :http, 0)
  end

  test "candidate admission is capped at sixteen" do
    envelope = ExecutionEnvelope.new("request-1", "eth_call", 1_000, started_at_us: 0)

    envelope =
      Enum.reduce(1..16, envelope, fn _, current ->
        assert {:ok, next} = ExecutionEnvelope.admit_candidate(current, 0)
        next
      end)

    assert {:error, :candidate_budget_exhausted} = ExecutionEnvelope.admit_candidate(envelope, 0)
  end

  test "candidate admission stops at the absolute deadline" do
    envelope = ExecutionEnvelope.new("request-1", "eth_call", 100, started_at_us: 1_000)
    assert {:error, :deadline_exhausted} = ExecutionEnvelope.admit_candidate(envelope, 101_000)
  end

  test "zero timeout constructs an expired envelope" do
    envelope = ExecutionEnvelope.new("request-1", "eth_call", 0, started_at_us: 1_000)
    assert {:error, :deadline_exhausted} = ExecutionEnvelope.admit_candidate(envelope, 1_000)
  end

  test "registered non-read work is not assumed replay-safe" do
    for method <- ["eth_submitWork", "eth_submitHashrate", "eth_accounts"] do
      assert ExecutionEnvelope.classify(method) == :unknown
    end
  end
end
