defmodule LivechainTest do
  use ExUnit.Case
  doctest Livechain

  test "greets the world" do
    assert Livechain.hello() == :world
  end
end
