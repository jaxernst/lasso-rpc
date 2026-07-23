defmodule Lasso.Config.ChainAliasTest do
  use ExUnit.Case, async: true

  alias Lasso.Config.ChainAlias

  describe "canonical_slug/2" do
    test "uses the first configured alias" do
      assert ChainAlias.canonical_slug(1, ["mainnet", "ethereum"]) == "mainnet"
    end

    test "ignores invalid configured aliases" do
      assert ChainAlias.canonical_slug(1, [nil, "", "ethereum"]) == "ethereum"
    end

    test "falls back to the decimal chain ID" do
      assert ChainAlias.canonical_slug(1) == "1"
      assert ChainAlias.canonical_slug(999_999, []) == "999999"
    end
  end

  describe "aliases/1" do
    test "returns only the universal decimal alias" do
      assert ChainAlias.aliases(1) == ["1"]
      assert ChainAlias.aliases(999_999) == ["999999"]
    end
  end

  describe "display_name/2" do
    test "uses and trims a configured label" do
      assert ChainAlias.display_name(1, "  My Mainnet  ") == "My Mainnet"
    end

    test "missing or empty labels use a generic chain-ID fallback" do
      assert ChainAlias.display_name(1, nil) == "Chain 1"
      assert ChainAlias.display_name(1, "   ") == "Chain 1"
      assert ChainAlias.display_name(999_999) == "Chain 999999"
    end

    test "invalid IDs render safely" do
      assert ChainAlias.display_name(nil) == "Unknown chain"
    end
  end
end
