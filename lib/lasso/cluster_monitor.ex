defmodule Lasso.ClusterMonitor do
  @moduledoc """
  Monitors cluster node connections and disconnections.

  Subscribes to Erlang's `:net_kernel` node events and emits telemetry
  for observability. Provides cluster state queries for health endpoints.
  """
  use GenServer
  require Logger

  @type cluster_info :: %{
          enabled: boolean(),
          nodes_connected: non_neg_integer(),
          nodes_total: non_neg_integer(),
          regions: [String.t()],
          nodes: [node()]
        }

  # Client API

  @doc """
  Returns the current cluster state.
  """
  @spec get_cluster_info() :: cluster_info()
  def get_cluster_info do
    connected_nodes = Node.list()

    %{
      enabled: cluster_enabled?(),
      nodes_connected: length(connected_nodes),
      nodes_total: length(connected_nodes) + 1,
      regions: get_cluster_regions(),
      nodes: connected_nodes
    }
  end

  @doc """
  Returns true if clustering is enabled (libcluster topologies configured).
  """
  @spec cluster_enabled?() :: boolean()
  def cluster_enabled? do
    case Application.get_env(:libcluster, :topologies, []) do
      [] -> false
      topologies when is_list(topologies) -> length(topologies) > 0
      _ -> false
    end
  end

  @doc """
  Returns list of unique regions across all connected nodes.
  """
  @spec get_cluster_regions() :: [String.t()]
  def get_cluster_regions do
    [node() | Node.list()]
    |> Enum.map(&get_node_region/1)
    |> Enum.uniq()
  end

  @doc """
  Gets the region for a specific node.
  """
  @spec get_node_region(node()) :: String.t()
  def get_node_region(node_name) when node_name == node() do
    System.get_env("CLUSTER_REGION") || "unknown"
  end

  def get_node_region(node_name) do
    case :rpc.call(node_name, System, :get_env, ["CLUSTER_REGION"], 1_000) do
      region when is_binary(region) -> region
      _ -> "unknown"
    end
  end

  # Server implementation

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Subscribe to node events
    :net_kernel.monitor_nodes(true, node_type: :visible)

    Logger.info("Cluster monitor started on node #{node()}")

    if cluster_enabled?() do
      Logger.info("Clustering enabled with topologies: #{inspect(Application.get_env(:libcluster, :topologies, []) |> Keyword.keys())}")
    else
      Logger.info("Clustering not enabled (no libcluster topologies configured)")
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info({:nodeup, node_name, _info}, state) do
    node_count = length(Node.list()) + 1
    region = get_node_region(node_name)

    Logger.info("Node connected: #{node_name} (region: #{region}, total nodes: #{node_count})")

    :telemetry.execute(
      [:lasso, :cluster, :node, :connected],
      %{node_count: node_count},
      %{node: node_name, region: region}
    )

    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, node_name, _info}, state) do
    node_count = length(Node.list()) + 1

    Logger.warning("Node disconnected: #{node_name} (total nodes: #{node_count})")

    :telemetry.execute(
      [:lasso, :cluster, :node, :disconnected],
      %{node_count: node_count},
      %{node: node_name}
    )

    {:noreply, state}
  end
end
