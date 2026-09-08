defmodule Lasso.DecimalSecurityTest do
  use ExUnit.Case, async: true

  test "the Decimal advisory exception applies only to the reviewed release" do
    assert to_string(Application.spec(:decimal, :vsn)) == "3.1.1",
           "Re-review CVE-2026-32686 and remove or revise its audit exception when Decimal changes"
  end

  test "untrusted large exponents are rejected before decimal arithmetic" do
    for input <- ["1e1000000000", "1e-1000000000"] do
      assert Decimal.parse(input) == :error
      assert Decimal.cast(input) == :error
    end
  end

  test "expanded output is bounded even for directly constructed decimals" do
    assert_raise ArgumentError, fn ->
      Decimal.to_string(%Decimal{sign: 1, coef: 1, exp: 1_000_000_000}, :normal)
    end
  end
end
