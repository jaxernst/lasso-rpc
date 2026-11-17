defmodule Lasso.Cluster.HealthTopology do
  @moduledoc """
  Shared cluster-topology helpers for the health endpoint.

  Readiness reads the last node-local publication. Missing or stale cluster
  diagnostics do not require a call to the topology worker.
  """

  @type info :: %{
          enabled: boolean(),
          coverage: %{
            connected: non_neg_integer(),
            responding: non_neg_integer(),
            expected: pos_integer()
          },
          regions: [String.t()],
          snapshot_status: :current | :stale | :unavailable | :standalone,
          snapshot_age_ms: non_neg_integer() | nil
        }

  @max_snapshot_age_ms 5_000

  @doc """
  Returns cached topology diagnostics, retaining missing configured peers
  when the worker has not published usable state.
  """
  @spec get() :: info()
  def get do
    case Lasso.Cluster.Topology.health_snapshot() do
      {:ok, topology, age_ms} ->
        node_ids = [topology.self_node_id | topology.node_ids] |> Enum.uniq()

        %{
          enabled: clustering_enabled?(),
          coverage:
            Map.put(topology.coverage, :expected, expected_nodes(topology.coverage.connected)),
          regions: extract_regions(node_ids),
          snapshot_status: if(age_ms <= @max_snapshot_age_ms, do: :current, else: :stale),
          snapshot_age_ms: age_ms
        }

      :unavailable ->
        unavailable()
    end
  end

  @doc """
  Topology shape used when clustering is not configured and no snapshot exists.
  """
  @spec standalone() :: info()
  def standalone do
    %{
      enabled: false,
      coverage: %{connected: 1, responding: 1, expected: 1},
      regions: [],
      snapshot_status: :standalone,
      snapshot_age_ms: nil
    }
  end

  @doc """
  Maps a topology to a high-level status string for liveness/readiness
  checks. `"standalone"` when clustering is off, otherwise based on the
  ratio of responding to expected nodes.
  """
  @spec cluster_status(info()) :: String.t()
  def cluster_status(%{enabled: false}), do: "standalone"
  def cluster_status(%{snapshot_status: :unavailable}), do: "unavailable"
  def cluster_status(%{snapshot_status: :stale}), do: "stale"

  def cluster_status(%{coverage: %{responding: responding, expected: expected}}) do
    cond do
      responding >= expected -> "healthy"
      responding >= div(expected + 1, 2) -> "degraded"
      true -> "critical"
    end
  end

  defp unavailable do
    if clustering_enabled?() do
      %{
        enabled: true,
        coverage: %{connected: 1, responding: 1, expected: expected_nodes(1)},
        regions: [],
        snapshot_status: :unavailable,
        snapshot_age_ms: nil
      }
    else
      standalone()
    end
  end

  defp clustering_enabled? do
    expected_nodes(1) > 1 or Node.list() != [] or
      Application.get_env(:libcluster, :topologies, []) != []
  end

  defp expected_nodes(connected) do
    case Application.get_env(:lasso, :expected_cluster_nodes) do
      desired when is_integer(desired) and desired > 0 -> max(connected, desired)
      _ -> connected
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
