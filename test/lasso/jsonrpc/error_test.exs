defmodule Lasso.JSONRPC.ErrorTest do
  use ExUnit.Case, async: true

  alias Lasso.JSONRPC.Error, as: JError

  describe "new/3 nil-aware defaults" do
    test "explicit breaker_penalty?: false is preserved (not overridden by ||)" do
      jerr = JError.new(-32_005, "Rate limited", breaker_penalty?: false)
      assert jerr.breaker_penalty? == false
    end

    test "explicit retriable?: false is preserved" do
      jerr = JError.new(-32_005, "Rate limited", retriable?: false)
      assert jerr.retriable? == false
    end

    test "explicit breaker_penalty?: true is preserved" do
      jerr = JError.new(-32_602, "Invalid params", breaker_penalty?: true)
      assert jerr.breaker_penalty? == true
    end

    test "explicit retriable?: true is preserved" do
      jerr = JError.new(-32_602, "Invalid params", retriable?: true)
      assert jerr.retriable? == true
    end

    test "omitted breaker_penalty? falls through to ErrorClassification" do
      # :rate_limit category → breaker_penalty? false (after our fix)
      jerr = JError.new(-32_005, "Rate limited")
      assert jerr.category == :rate_limit
      assert jerr.breaker_penalty? == false
    end

    test "omitted retriable? falls through to ErrorClassification" do
      # -32_602 is :invalid_params → retriable? false
      jerr = JError.new(-32_602, "Invalid params")
      assert jerr.retriable? == false
    end

    test "rate limit error has correct classification" do
      jerr = JError.new(-32_005, "Rate limited")
      assert jerr.category == :rate_limit
      assert jerr.retriable? == true
      assert jerr.breaker_penalty? == false
    end

    test "capability violation has correct classification" do
      jerr = JError.new(-32_000, "block range too large")
      assert jerr.category == :capability_violation
      assert jerr.retriable? == true
      assert jerr.breaker_penalty? == false
    end

    test "server error has correct classification" do
      jerr = JError.new(-32_000, "Internal server error")
      assert jerr.category == :server_error
      assert jerr.retriable? == true
      assert jerr.breaker_penalty? == true
    end

    test "HTTP 429 is normalized to -32_005 rate limit" do
      jerr = JError.new(429, "Too Many Requests")
      assert jerr.code == -32_005
      assert jerr.original_code == 429
      assert jerr.category == :rate_limit
      assert jerr.breaker_penalty? == false
    end
  end
end
