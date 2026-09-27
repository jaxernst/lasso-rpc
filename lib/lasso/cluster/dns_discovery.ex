defmodule Lasso.Cluster.DNSDiscovery do
  @moduledoc """
  Discovers peers through DNS without using DNS omissions to evict live peers.

  DNS answers identify connection candidates. Erlang distribution owns connection
  liveness, and Topology reports disconnected or unresponsive peers. A partial or
  empty DNS answer must not tear down an established distribution connection.
  Peer retirement requires shutdown or explicit disconnection, not DNS removal alone.
  """

  use GenServer
  use Cluster.Strategy

  alias Cluster.Strategy
  alias Cluster.Strategy.State

  @impl true
  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init([%State{} = state]), do: {:ok, state, {:continue, :poll}}

  @impl true
  def handle_continue(:poll, state), do: {:noreply, poll(state)}

  @impl true
  def handle_info(:poll, state), do: {:noreply, poll(state)}

  defp poll(state) do
    query = Keyword.fetch!(state.config, :query)
    basename = Keyword.fetch!(state.config, :node_basename)
    resolver = Keyword.get(state.config, :resolver, &resolve/1)

    candidates =
      query
      |> resolver.()
      |> Enum.map(&node_name(basename, &1))
      |> Enum.uniq()

    Strategy.connect_nodes(state.topology, state.connect, state.list_nodes, candidates)

    Process.send_after(self(), :poll, Keyword.get(state.config, :polling_interval, 5_000))
    state
  end

  defp node_name(basename, ip) do
    # Distribution requires atoms for newly discovered machines from the private service DNS.
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    :"#{basename}@#{:inet_parse.ntoa(ip)}"
  end

  defp resolve(query) do
    query
    |> String.to_charlist()
    |> Cluster.Strategy.DNSPoll.lookup_all_ips()
  end
end
