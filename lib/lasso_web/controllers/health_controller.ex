defmodule LassoWeb.HealthController do
  @moduledoc """
  Health check endpoint for load balancers and monitoring.

  Returns cluster topology status, node counts, regions, and overall service health.
  """

  use LassoWeb, :controller

  @spec health(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def health(conn, _params) do
    uptime_ms =
      System.monotonic_time(:millisecond) -
        Application.get_env(:lasso, :start_time, System.monotonic_time(:millisecond))

    uptime_seconds = div(uptime_ms, 1000)
    topology = get_topology_info()

    health_status = %{
      status: "healthy",
      timestamp: DateTime.utc_now(),
      uptime_seconds: uptime_seconds,
      version: Application.spec(:lasso, :vsn) |> to_string(),
      cluster: %{
        enabled: topology.enabled,
        nodes_connected: topology.coverage.connected,
        nodes_responding: topology.coverage.responding,
        nodes_total: topology.coverage.expected,
        regions: topology.regions,
        status: determine_cluster_status(topology)
      }
    }

    json(conn, health_status)
  end

  defp get_topology_info do
    topology = Lasso.Cluster.Topology.get_topology()
    self_node_id = topology.self_node_id
    node_ids = [self_node_id | topology.node_ids] |> Enum.uniq()
    regions = extract_regions(node_ids)

    %{
      enabled: true,
      coverage: topology.coverage,
      regions: regions
    }
  rescue
    _ -> standalone_topology()
  catch
    :exit, _ -> standalone_topology()
  end

  defp standalone_topology do
    %{enabled: false, coverage: %{connected: 1, responding: 1, expected: 1}, regions: []}
  end

  defp extract_regions(node_ids) do
    node_ids
    |> Enum.map(&extract_region/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp extract_region(node_id) when is_binary(node_id) do
    case String.split(node_id, "-", parts: 2) do
      [region, _rest] when byte_size(region) in 2..4 -> region
      _ -> nil
    end
  end

  defp extract_region(_), do: nil

  defp determine_cluster_status(topology) do
    cond do
      not topology.enabled ->
        "standalone"

      topology.coverage.responding >= topology.coverage.connected ->
        "healthy"

      topology.coverage.responding >= div(topology.coverage.connected, 2) ->
        "degraded"

      true ->
        "critical"
    end
  end
end
