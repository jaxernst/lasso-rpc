defmodule Lasso.Observability.Prometheus do
  @moduledoc """
  Bounded, node-local Prometheus evidence for the standalone operator.

  Request observations use fixed ETS slots and a short probe budget. An
  unfamiliar method is folded into `other`; exhausted slots are counted rather
  than allocating more series on the request path. Circuit and head gauges are
  read from current local state when scraped.
  """

  use GenServer

  alias Lasso.BlockSync.Registry, as: BlockRegistry
  alias Lasso.Config.ConfigStore
  alias Lasso.Core.Support.CircuitBreaker.Snapshot
  alias Lasso.Providers.Catalog

  @event [:lasso, :rpc, :request, :stop]
  @handler_id "lasso-prometheus-request-stop"
  @requests :lasso_prometheus_requests
  @stats :lasso_prometheus_stats
  @max_series 4_096
  @max_probes 16
  @max_routes 2_048
  @methods ~w(
    eth_blockNumber eth_call eth_chainId eth_estimateGas eth_feeHistory
    eth_getBalance eth_getBlockByHash eth_getBlockByNumber eth_getCode
    eth_getLogs eth_getStorageAt eth_getTransactionByHash
    eth_getTransactionCount eth_getTransactionReceipt eth_sendRawTransaction
    eth_subscribe eth_unsubscribe net_version web3_clientVersion
  )

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@requests, [:named_table, :set, :public, write_concurrency: true])
    :ets.new(@stats, [:named_table, :set, :public, write_concurrency: true])
    :ets.insert(@stats, {:dropped, 0})
    :telemetry.detach(@handler_id)
    :ok = :telemetry.attach(@handler_id, @event, &__MODULE__.handle_event/4, nil)
    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
    :ok
  end

  @doc false
  @spec handle_event([atom()], map(), map(), term()) :: :ok
  def handle_event(@event, _measurement, metadata, _config) do
    key = {
      Map.get(metadata, :chain_id),
      provider_label(Map.get(metadata, :provider_id)),
      method_label(Map.get(metadata, :method)),
      outcome_label(Map.get(metadata, :result))
    }

    if is_integer(elem(key, 0)) and elem(key, 0) > 0 do
      record(key)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Current node-local request series occupancy and dropped observations."
  @spec stats() :: %{series: non_neg_integer(), dropped: non_neg_integer()}
  def stats do
    %{series: :ets.info(@requests, :size), dropped: :ets.lookup_element(@stats, :dropped, 2)}
  rescue
    ArgumentError -> %{series: 0, dropped: 0}
  end

  @doc "Prometheus text exposition for local request and route evidence."
  @spec scrape() :: String.t()
  def scrape do
    request_lines =
      @requests
      |> :ets.tab2list()
      |> Enum.sort_by(fn {_slot, key, _count} -> key end)
      |> Enum.map(fn {_slot, {chain, provider, method, outcome}, count} ->
        sample("lasso_rpc_requests_total", count,
          chain: chain,
          provider: provider,
          method: method,
          outcome: outcome
        )
      end)

    {circuit_lines, lag_lines} =
      Enum.reduce(routes(), {[], []}, fn route, {circuits, lags} ->
        {route_circuits, route_lag} = route_samples(route)
        {route_circuits ++ circuits, route_lag ++ lags}
      end)

    ([
       "# HELP lasso_rpc_requests_total Completed routed RPC requests on this node",
       "# TYPE lasso_rpc_requests_total counter"
     ] ++
       request_lines ++
       [
         "# HELP lasso_rpc_request_observations_dropped_total Request observations omitted by the series cap",
         "# TYPE lasso_rpc_request_observations_dropped_total counter",
         sample("lasso_rpc_request_observations_dropped_total", stats().dropped, []),
         "# HELP lasso_circuit_state Current local circuit state, one active state per transport",
         "# TYPE lasso_circuit_state gauge"
       ] ++
       Enum.reverse(circuit_lines) ++
       [
         "# HELP lasso_provider_head_lag_blocks Fresh provider blocks behind local consensus",
         "# TYPE lasso_provider_head_lag_blocks gauge"
       ] ++ Enum.reverse(lag_lines))
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  rescue
    ArgumentError -> "# Prometheus observer unavailable\n"
  end

  defp record(key) do
    first = :erlang.phash2(key, @max_series)

    result =
      Enum.reduce_while(0..(@max_probes - 1), :full, fn offset, _acc ->
        slot = rem(first + offset, @max_series)

        case :ets.lookup(@requests, slot) do
          [{^slot, ^key, _count}] ->
            :ets.update_counter(@requests, slot, {3, 1})
            {:halt, :ok}

          [] ->
            if :ets.insert_new(@requests, {slot, key, 0}) do
              :ets.update_counter(@requests, slot, {3, 1})
              {:halt, :ok}
            else
              {:cont, :full}
            end

          _occupied ->
            {:cont, :full}
        end
      end)

    if result == :full, do: :ets.update_counter(@stats, :dropped, {2, 1})
    :ok
  end

  defp routes do
    ConfigStore.list_profiles()
    |> Stream.flat_map(fn profile ->
      ConfigStore.list_chains_for_profile(profile)
      |> Stream.flat_map(fn chain ->
        case ConfigStore.get_providers(profile, chain) do
          {:ok, providers} -> Enum.map(providers, &{profile, chain, &1.id})
          _ -> []
        end
      end)
    end)
    |> Enum.take(@max_routes)
  end

  defp route_samples({profile, chain, provider}) do
    instance_id = Catalog.lookup_instance_id(profile, chain, provider)

    circuits =
      for transport <- [:http, :ws], state <- [:closed, :open, :half_open] do
        observed = circuit_state(instance_id, transport)

        sample("lasso_circuit_state", if(observed == state, do: 1, else: 0),
          profile: profile,
          chain: chain,
          provider: provider,
          transport: transport,
          state: state
        )
      end

    lag =
      case instance_id && BlockRegistry.get_provider_lag(chain, instance_id) do
        {:ok, blocks} ->
          [
            sample("lasso_provider_head_lag_blocks", max(-blocks, 0),
              profile: profile,
              chain: chain,
              provider: provider
            )
          ]

        _ ->
          []
      end

    {circuits, lag}
  end

  defp circuit_state(id, transport) when is_binary(id) do
    case Snapshot.lookup({id, transport}) do
      {:ok, %{control_health: :degraded}} -> :half_open
      {:ok, %{state: state}} -> state
      :missing -> :unknown
    end
  end

  defp circuit_state(_id, _transport), do: :unknown

  defp provider_label(provider) when is_binary(provider), do: String.slice(provider, 0, 64)
  defp provider_label(_provider), do: "unknown"
  defp method_label(method) when method in @methods, do: method
  defp method_label(_method), do: "other"
  defp outcome_label(result) when result in [:success, :error], do: Atom.to_string(result)
  defp outcome_label(_result), do: "other"

  defp sample(name, value, labels) do
    encoded = Enum.map_join(labels, ",", fn {key, item} -> ~s(#{key}="#{escape(item)}") end)

    if encoded == "", do: "#{name} #{value}", else: "#{name}{#{encoded}} #{value}"
  end

  defp escape(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\n", "\\n")
    |> String.replace("\"", "\\\"")
  end
end
