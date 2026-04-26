defmodule Lasso.Cluster.HealthTopology do
  @moduledoc """
  Shared cluster-topology helpers for the health endpoint.

  Both the OSS and cloud `HealthController` consume this module so the
  `regions` extraction and standalone-fallback logic stay identical and
  drift-free across repos.
  """

  @type info :: %{
          enabled: boolean(),
          coverage: %{
            connected: pos_integer(),
            responding: pos_integer(),
            expected: pos_integer()
          },
          regions: [String.t()]
        }

  @doc """
  Returns topology info for the running cluster, falling back to a
  standalone shape when the topology GenServer is unavailable or returns
  an unexpected map.
  """
  @spec get() :: info()
  def get do
    topology = Lasso.Cluster.Topology.get_topology()
    self_node_id = topology.self_node_id
    node_ids = [self_node_id | topology.node_ids] |> Enum.uniq()

    %{
      enabled: true,
      coverage: topology.coverage,
      regions: extract_regions(node_ids)
    }
  rescue
    _ -> standalone()
  catch
    :exit, _ -> standalone()
  end

  @doc """
  Topology shape used when clustering is unavailable or unreachable.
  """
  @spec standalone() :: info()
  def standalone do
    %{enabled: false, coverage: %{connected: 1, responding: 1, expected: 1}, regions: []}
  end

  @doc """
  Maps a topology to a high-level status string for liveness/readiness
  checks. `"standalone"` when clustering is off, otherwise based on the
  ratio of responding to connected nodes.
  """
  @spec cluster_status(info()) :: String.t()
  def cluster_status(%{enabled: false}), do: "standalone"

  def cluster_status(%{coverage: %{responding: responding, connected: connected}}) do
    cond do
      responding >= connected -> "healthy"
      responding >= div(connected, 2) -> "degraded"
      true -> "critical"
    end
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
end
