defmodule LassoWeb.RPC.HelpersTest do
  use ExUnit.Case, async: true

  alias LassoWeb.RPC.Helpers

  describe "normalize_strategy_token/1" do
    test "supports fastest" do
      assert Helpers.normalize_strategy_token("fastest") == :fastest
    end

    test "supports load balanced aliases" do
      assert Helpers.normalize_strategy_token("load-balanced") == :load_balanced
      assert Helpers.normalize_strategy_token("load_balanced") == :load_balanced
      assert Helpers.normalize_strategy_token("round-robin") == :load_balanced
      assert Helpers.normalize_strategy_token("round_robin") == :load_balanced
    end

    test "supports latency weighted aliases" do
      assert Helpers.normalize_strategy_token("latency-weighted") == :latency_weighted
      assert Helpers.normalize_strategy_token("latency_weighted") == :latency_weighted
    end

    test "returns nil for unknown strategy" do
      assert Helpers.normalize_strategy_token("foo") == nil
      assert Helpers.normalize_strategy_token(nil) == nil
    end
  end
end
