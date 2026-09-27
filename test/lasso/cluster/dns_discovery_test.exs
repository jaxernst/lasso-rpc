defmodule Lasso.Cluster.DNSDiscoveryTest do
  use ExUnit.Case, async: true

  alias Cluster.Strategy.State
  alias Lasso.Cluster.DNSDiscovery

  @ips [{10, 0, 0, 1}, {10, 0, 0, 2}, {10, 0, 0, 3}]
  @nodes [:"lasso@10.0.0.1", :"lasso@10.0.0.2", :"lasso@10.0.0.3"]

  setup do
    inventory =
      start_supervised!(
        {Agent, fn -> %{dns: @ips, connected: [], disconnected: [], fail: []} end}
      )

    state = %State{
      topology: :test_dns,
      connect: {__MODULE__, :connect, [inventory]},
      disconnect: {__MODULE__, :disconnect, [inventory]},
      list_nodes: {__MODULE__, :connected, [inventory]},
      config: [
        query: "lasso.internal",
        node_basename: "lasso",
        polling_interval: 60_000,
        resolver: fn "lasso.internal" -> Agent.get(inventory, & &1.dns) end
      ]
    }

    %{inventory: inventory, state: state}
  end

  test "partial and empty DNS responses retain live connections", context do
    pid = start_supervised!({DNSDiscovery, [context.state]})
    :sys.get_state(pid)
    assert Enum.sort(connected(context.inventory)) == @nodes

    for answer <- [Enum.take(@ips, 2), [], [], @ips] do
      Agent.update(context.inventory, &%{&1 | dns: answer})
      poll(pid)
      assert Enum.sort(connected(context.inventory)) == @nodes
      assert Agent.get(context.inventory, & &1.disconnected) == []
    end
  end

  test "distribution loss stays disconnected until rediscovered", context do
    pid = start_supervised!({DNSDiscovery, [context.state]})
    :sys.get_state(pid)
    missing = List.last(@nodes)

    Agent.update(context.inventory, fn state ->
      %{state | connected: List.delete(state.connected, missing), dns: Enum.take(@ips, 2)}
    end)

    poll(pid)
    refute missing in connected(context.inventory)

    Agent.update(context.inventory, &%{&1 | dns: @ips})
    poll(pid)
    assert missing in connected(context.inventory)
  end

  test "failed candidates are retried and new candidates are discovered", context do
    missing = List.last(@nodes)
    Agent.update(context.inventory, &%{&1 | fail: [missing]})
    pid = start_supervised!({DNSDiscovery, [context.state]})
    :sys.get_state(pid)
    refute missing in connected(context.inventory)

    Agent.update(context.inventory, &%{&1 | fail: [], dns: [{10, 0, 0, 4} | @ips]})
    poll(pid)
    assert missing in connected(context.inventory)
    assert :"lasso@10.0.0.4" in connected(context.inventory)
  end

  test "the previous DNS strategy disconnects a live peer on the same partial answer", context do
    pid = start_supervised!({Cluster.Strategy.DNSPoll, [context.state]})
    Agent.update(context.inventory, &%{&1 | dns: Enum.take(@ips, 2)})
    poll(pid)
    assert Agent.get(context.inventory, & &1.disconnected) == [List.last(@nodes)]
  end

  defp poll(pid) do
    send(pid, :poll)
    :sys.get_state(pid)
  end

  def connected(inventory), do: Agent.get(inventory, & &1.connected)

  def connect(inventory, node) do
    Agent.get_and_update(inventory, fn state ->
      if node in state.fail do
        {false, state}
      else
        {true, %{state | connected: Enum.uniq([node | state.connected])}}
      end
    end)
  end

  def disconnect(inventory, node) do
    Agent.update(inventory, fn state ->
      %{
        state
        | connected: List.delete(state.connected, node),
          disconnected: [node | state.disconnected]
      }
    end)

    true
  end
end
