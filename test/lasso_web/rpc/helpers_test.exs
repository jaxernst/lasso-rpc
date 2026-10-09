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

    test "supports balanced-fast and its latency-weighted alias" do
      assert Helpers.normalize_strategy_token("balanced-fast") == :balanced_fast
      assert Helpers.normalize_strategy_token("balanced_fast") == :balanced_fast
      assert Helpers.normalize_strategy_token("latency-weighted") == :balanced_fast
      assert Helpers.normalize_strategy_token("latency_weighted") == :balanced_fast
    end

    test "returns nil for unknown strategy" do
      assert Helpers.normalize_strategy_token("foo") == nil
      assert Helpers.normalize_strategy_token(nil) == nil
    end
  end
end
