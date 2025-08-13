defmodule LivechainWeb.RPCControllerStrategyTest do
  use ExUnit.Case, async: true

  alias LivechainWeb.RPCController

  test "parse_strategy maps strings to atoms" do
    assert :leaderboard == :erlang.apply(RPCController, :parse_strategy, ["leaderboard"])
    assert :priority == :erlang.apply(RPCController, :parse_strategy, ["priority"])
    assert :round_robin == :erlang.apply(RPCController, :parse_strategy, ["round_robin"])
    assert :latency == :erlang.apply(RPCController, :parse_strategy, ["latency"])
    assert :latency == :erlang.apply(RPCController, :parse_strategy, ["latency_based"])
    assert :latency == :erlang.apply(RPCController, :parse_strategy, ["fastest"])
    assert :cheapest == :erlang.apply(RPCController, :parse_strategy, ["cheapest"])
    assert nil == :erlang.apply(RPCController, :parse_strategy, ["unknown"])
  end
end
