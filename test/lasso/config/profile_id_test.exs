defmodule Lasso.Config.ProfileIdTest do
  use ExUnit.Case, async: true

  alias Lasso.Config.ProfileId

  test "system profile identity is its YAML slug" do
    assert ProfileId.for_system("public") == "public"
    assert ProfileId.for_system("testnet") == "testnet"
  end
end
