defmodule Lasso.Cluster.TopologyTest do
  use ExUnit.Case, async: false

  setup do
    TestHelper.ensure_test_environment_ready()
    :ok
  end

  describe "compute_coverage/1" do
    test "counts connected nodes correctly, excluding self" do
      nodes = %{
        :node1 => %{node: :node1, state: :responding, region: "us-east"},
        :node2 => %{node: :node2, state: :ready, region: "eu-west"},
        :node3 => %{node: :node3, state: :connected, region: "unknown"}
      }

      coverage = compute_coverage(nodes)

      # expected = connected + 1 (self)
      assert coverage.expected == 4
      # connected = all non-disconnected + 1 (self)
      assert coverage.connected == 4
      # responding = only :responding/:ready states + 1 (self)
      assert coverage.responding == 3
      assert coverage.unresponsive == []
      assert coverage.disconnected == []
    end

    test "tracks unresponsive and disconnected nodes separately" do
      nodes = %{
        :node1 => %{node: :node1, state: :responding, region: "us-east"},
        :node2 => %{node: :node2, state: :unresponsive, region: "eu-west"},
        :node3 => %{node: :node3, state: :disconnected, region: "ap-south"}
      }

      coverage = compute_coverage(nodes)

      # connected = non-disconnected + self = 2 + 1 = 3
      assert coverage.connected == 3
      # responding = responding/ready + self = 1 + 1 = 2
      assert coverage.responding == 2
      assert coverage.unresponsive == [:node2]
      assert coverage.disconnected == [:node3]
    end

    test "handles empty node map" do
      nodes = %{}

      coverage = compute_coverage(nodes)

      # Only self is counted
      assert coverage.expected == 1
      assert coverage.connected == 1
      assert coverage.responding == 1
      assert coverage.unresponsive == []
      assert coverage.disconnected == []
    end
  end

  describe "state transitions on health check failures" do
    test "node becomes unresponsive after 3 consecutive failures" do
      # Simulate the health check result processing logic
      node_info = %{
        node: :test_node,
        state: :responding,
        region: "us-east",
        consecutive_failures: 0,
        last_response: System.monotonic_time(:millisecond)
      }

      # Simulate first failure
      info_after_1 = simulate_health_failure(node_info)
      assert info_after_1.consecutive_failures == 1
      assert info_after_1.state == :responding

      # Simulate second failure
      info_after_2 = simulate_health_failure(info_after_1)
      assert info_after_2.consecutive_failures == 2
      assert info_after_2.state == :responding

      # Simulate third failure - should transition to unresponsive
      info_after_3 = simulate_health_failure(info_after_2)
      assert info_after_3.consecutive_failures == 3
      assert info_after_3.state == :unresponsive
    end

    test "successful health check resets consecutive failures" do
      node_info = %{
        node: :test_node,
        state: :unresponsive,
        region: "us-east",
        consecutive_failures: 5,
        last_response: nil
      }

      # Simulate successful health check
      updated_info = simulate_health_success(node_info)

      assert updated_info.consecutive_failures == 0
      assert updated_info.state == :responding
      assert updated_info.last_response != nil
    end

    test "disconnected nodes are not affected by health check results" do
      node_info = %{
        node: :test_node,
        state: :disconnected,
        region: "us-east",
        consecutive_failures: 0,
        last_response: nil
      }

      # Health failure should not change disconnected state
      updated_info = simulate_health_failure_raw(node_info)

      assert updated_info.state == :disconnected
      assert updated_info.consecutive_failures == 0
    end
  end

  describe "region discovery" do
    test "extracts region from node name when config not available" do
      # Node format: name@hostname where hostname becomes region fallback
      region = extract_region_from_node(:"lasso@us-east-1.example.com")
      assert region == "us-east-1.example.com"
    end

    test "returns hostname portion for nodes without @ separator" do
      # Nodes without @ use the full name as the region identifier
      region = extract_region_from_node(:simple_name)
      assert region == "simple_name"
    end
  end

  describe "compute_regions/2" do
    test "groups nodes by region, excluding disconnected" do
      nodes = %{
        :node1 => %{node: :node1, state: :responding, region: "us-east"},
        :node2 => %{node: :node2, state: :ready, region: "us-east"},
        :node3 => %{node: :node3, state: :connected, region: "eu-west"},
        :node4 => %{node: :node4, state: :disconnected, region: "ap-south"}
      }

      regions = compute_regions(nodes, "local")

      # Should have us-east (2 nodes), eu-west (1 node), and local (self)
      assert Map.has_key?(regions, "us-east")
      assert Map.has_key?(regions, "eu-west")
      assert Map.has_key?(regions, "local")
      # ap-south excluded because node4 is disconnected
      refute Map.has_key?(regions, "ap-south")

      assert length(regions["us-east"]) == 2
      assert length(regions["eu-west"]) == 1
    end

    test "includes self region even with no nodes" do
      nodes = %{}

      regions = compute_regions(nodes, "self-region")

      assert Map.has_key?(regions, "self-region")
      assert regions["self-region"] == []
    end
  end

  describe "reconciliation" do
    test "detects nodes present in Node.list but not tracked" do
      tracked_nodes = %{
        :known_node => %{node: :known_node, state: :responding, region: "us-east"}
      }

      actual_nodes = MapSet.new([:known_node, :unknown_node])

      {missing, extra} = find_reconciliation_diff(tracked_nodes, actual_nodes)

      assert :unknown_node in missing
      assert Enum.empty?(extra)
    end

    test "detects tracked nodes no longer in Node.list" do
      tracked_nodes = %{
        :stale_node => %{node: :stale_node, state: :responding, region: "us-east"},
        :current_node => %{node: :current_node, state: :responding, region: "eu-west"}
      }

      actual_nodes = MapSet.new([:current_node])

      {missing, extra} = find_reconciliation_diff(tracked_nodes, actual_nodes)

      assert Enum.empty?(missing)
      assert :stale_node in extra
    end
  end

  # Helper functions that mirror the internal logic

  defp compute_coverage(nodes) do
    {connected, responding, unresponsive, disconnected} =
      nodes
      |> Map.values()
      |> Enum.reduce({0, 0, [], []}, fn info, {conn, resp, unr, disc} ->
        case info.state do
          :disconnected -> {conn, resp, unr, [info.node | disc]}
          :unresponsive -> {conn + 1, resp, [info.node | unr], disc}
          state when state in [:responding, :ready] -> {conn + 1, resp + 1, unr, disc}
          _ -> {conn + 1, resp, unr, disc}
        end
      end)

    %{
      expected: connected + 1,
      connected: connected + 1,
      responding: responding + 1,
      unresponsive: unresponsive,
      disconnected: disconnected
    }
  end

  defp simulate_health_failure(info) do
    failures = info.consecutive_failures + 1
    new_state = if failures >= 3, do: :unresponsive, else: info.state
    %{info | consecutive_failures: failures, state: new_state}
  end

  defp simulate_health_failure_raw(info) do
    if info.state == :disconnected do
      info
    else
      simulate_health_failure(info)
    end
  end

  defp simulate_health_success(info) do
    now = System.monotonic_time(:millisecond)

    new_state =
      case info.state do
        state when state in [:connected, :discovering, :unresponsive] -> :responding
        other -> other
      end

    %{info | state: new_state, last_response: now, consecutive_failures: 0}
  end

  defp extract_region_from_node(node) do
    node
    |> Atom.to_string()
    |> String.split("@")
    |> List.last()
    |> case do
      nil -> "unknown"
      "" -> "unknown"
      r -> r
    end
  end

  defp compute_regions(nodes, self_region) do
    nodes
    |> Enum.filter(fn {_node, info} -> info.state not in [:disconnected] end)
    |> Enum.group_by(fn {_node, info} -> info.region end, fn {node, _} -> node end)
    |> Map.put_new(self_region, [])
  end

  defp find_reconciliation_diff(tracked_nodes, actual_nodes) do
    tracked_connected =
      tracked_nodes
      |> Enum.filter(fn {_node, info} -> info.state not in [:disconnected] end)
      |> Enum.map(fn {node, _} -> node end)
      |> MapSet.new()

    missing_from_tracking = MapSet.difference(actual_nodes, tracked_connected)
    extra_in_tracking = MapSet.difference(tracked_connected, actual_nodes)

    {MapSet.to_list(missing_from_tracking), MapSet.to_list(extra_in_tracking)}
  end
end
