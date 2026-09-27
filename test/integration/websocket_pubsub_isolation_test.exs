defmodule Lasso.WebSocketPubSubIsolationTest do
  use ExUnit.Case, async: false

  alias Lasso.Core.Streaming.{InstanceEventBus, InstanceSubscriptionManager}
  alias Lasso.Testing.ClusterPubSubForwarder
  @moduletag :integration
  @moduletag timeout: 90_000

  test "physical WebSocket control facts never cross BEAM nodes" do
    {cluster, node_a, node_b} = start_cluster()
    on_exit(fn -> stop_cluster(cluster) end)

    unique = System.unique_integer([:positive])
    chain_id = 8_000_000 + rem(unique, 1_000_000)
    instance_id = "cluster-ws-isolation-#{unique}"
    connection_topic = Lasso.Topics.ws_conn_instance(instance_id)
    subscription_topic = Lasso.Topics.ws_subs_instance(instance_id)
    restart_topic = Lasso.Topics.instance_sub_manager_restarted(chain_id)
    projected_topic = "cluster-ws-isolation:projected:#{unique}"
    topics = [connection_topic, subscription_topic, restart_topic, projected_topic]

    forwarder_a = start_forwarder(node_a, self(), :node_a, topics)
    forwarder_b = start_forwarder(node_b, self(), :node_b, topics)
    assert_receive {:forwarder_ready, :node_a, ^forwarder_a}
    assert_receive {:forwarder_ready, :node_b, ^forwarder_b}

    manager_a = start_manager(node_a, chain_id, instance_id)
    assert_receive {:node_a, {:instance_sub_manager_restarted, ^instance_id}}
    refute_receive {:node_b, {:instance_sub_manager_restarted, ^instance_id}}, 200

    manager_b = start_manager(node_b, chain_id, instance_id)
    assert_receive {:node_b, {:instance_sub_manager_restarted, ^instance_id}}
    refute_receive {:node_a, {:instance_sub_manager_restarted, ^instance_id}}, 200

    connected = {:ws_connected, instance_id, "connection-a"}
    assert :ok = :rpc.call(node_a, InstanceEventBus, :broadcast, [connection_topic, connected])
    assert_receive {:node_a, ^connected}
    refute_receive {:node_b, ^connected}, 200

    wait_until(fn ->
      match?(
        %{connection_state: %{status: :connected, connection_id: "connection-a"}},
        manager_status(node_a, instance_id)
      )
    end)

    assert %{connection_state: nil} = manager_status(node_b, instance_id)

    payload_event =
      {:subscription_event, instance_id, "remote-subscription-id", %{"number" => "0x1"},
       System.system_time(:millisecond)}

    assert :ok =
             :rpc.call(node_a, InstanceEventBus, :broadcast, [subscription_topic, payload_event])

    assert_receive {:node_a, ^payload_event}
    refute_receive {:node_b, ^payload_event}, 200

    wait_until(fn -> manager_state(node_a, instance_id).orphan_event_count == 1 end)
    assert manager_state(node_b, instance_id).orphan_event_count == 0

    projected = {:provider_projection, instance_id}

    assert :ok =
             :rpc.call(node_a, Phoenix.PubSub, :broadcast, [
               Lasso.PubSub,
               projected_topic,
               projected
             ])

    assert_receive {:node_a, ^projected}
    assert_receive {:node_b, ^projected}

    stop_manager(node_a, manager_a)
    stop_manager(node_b, manager_b)
  end

  def start_forwarder(node, owner, tag, topics) do
    :rpc.call(node, ClusterPubSubForwarder, :start, [owner, tag, topics])
  end

  defp start_cluster do
    {_output, 0} = System.cmd("epmd", ["-daemon"])
    :ok = LocalCluster.start()

    endpoint_config =
      :lasso
      |> Application.get_env(LassoWeb.Endpoint)
      |> Keyword.put(:server, false)
      |> Keyword.put(:http, ip: {127, 0, 0, 1}, port: 0)

    {:ok, cluster} =
      LocalCluster.start_link(2,
        prefix: "wsisolation#{System.unique_integer([:positive])}",
        applications: [:lasso],
        environment: [lasso: [{LassoWeb.Endpoint, endpoint_config}]]
      )

    {:ok, [node_a, node_b]} = LocalCluster.nodes(cluster)
    assert :pong = Node.ping(node_a)
    assert :pong = Node.ping(node_b)
    {cluster, node_a, node_b}
  end

  defp start_manager(node, chain_id, instance_id) do
    assert {:ok, pid} =
             :rpc.call(node, DynamicSupervisor, :start_child, [
               Lasso.Providers.InstanceDynamicSupervisor,
               {InstanceSubscriptionManager, {chain_id, instance_id}}
             ])

    pid
  end

  defp stop_manager(node, pid) do
    assert :ok =
             :rpc.call(node, DynamicSupervisor, :terminate_child, [
               Lasso.Providers.InstanceDynamicSupervisor,
               pid
             ])
  end

  defp manager_status(node, instance_id) do
    :rpc.call(node, InstanceSubscriptionManager, :get_status, [instance_id])
  end

  defp manager_state(node, instance_id) do
    :rpc.call(node, :sys, :get_state, [InstanceSubscriptionManager.via(instance_id)])
  end

  defp wait_until(fun, attempts \\ 50)
  defp wait_until(fun, 0), do: assert(fun.())

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  defp stop_cluster(cluster) do
    if Process.alive?(cluster), do: GenServer.stop(cluster, :normal, 30_000)
  end
end
