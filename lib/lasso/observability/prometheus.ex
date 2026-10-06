defmodule Lasso.Observability.Prometheus do
  @moduledoc """
  Bounded, node-local Prometheus evidence for the standalone operator.

  Request observations use fixed ETS slots and a short probe budget. An
  unfamiliar method is folded into `other`; exhausted slots are counted rather
  than allocating more series on the request path. Circuit and head gauges are
  read from current local state when scraped. Head lag is routing's own
  per-transport assessment against each route's routing plan.

  Exact per-route request totals come from `Lasso.RPC.RequestAggregate`, which
  counts every request before detail sampling; the duration histogram and the
  per-provider request counter are observation-based and sampled above
  256 successes per second per scope.
  """

  use GenServer

  alias Lasso.BlockSync.Registry, as: BlockRegistry
  alias Lasso.Config.ConfigStore
  alias Lasso.Core.Support.CircuitBreaker.Snapshot
  alias Lasso.Providers.{Catalog, LagCalculation}

  alias Lasso.Observability.{
    MetricsScope,
    PrometheusMetrics,
    PrometheusRuntime,
    RouteTotals
  }

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
    MetricsScope.install()
    PrometheusMetrics.init()
    :telemetry.detach(@handler_id)

    :ok =
      :telemetry.attach_many(
        @handler_id,
        PrometheusMetrics.events(),
        &__MODULE__.handle_event/4,
        nil
      )

    {:ok, %{route_totals: RouteTotals.new()}}
  end

  @impl true
  def handle_call(:route_totals, _from, state) do
    route_totals =
      case Catalog.snapshot() do
        %{request_aggregates: sets} when is_map(sets) ->
          RouteTotals.advance(state.route_totals, sets)

        _unpublished ->
          state.route_totals
      end

    {:reply, RouteTotals.totals(route_totals), %{state | route_totals: route_totals}}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
    :ok
  end

  @doc false
  @spec handle_event([atom()], map(), map(), term()) :: :ok
  def handle_event(@event, measurements, metadata, config) do
    PrometheusMetrics.handle_event(@event, measurements, metadata, config)
    metadata = MetricsScope.impl().bound(metadata)

    key = {
      Map.get(metadata, :chain_id),
      provider_label(Map.get(metadata, :provider_id)),
      method_label(Map.get(metadata, :method)),
      outcome_label(Map.get(metadata, :result))
    }

    if (is_integer(elem(key, 0)) and elem(key, 0) > 0) or is_binary(elem(key, 0)) do
      record(key)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  def handle_event(event, measurements, metadata, config) do
    PrometheusMetrics.handle_event(event, measurements, metadata, config)
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

    route_scan = routes()
    chain_scan = chains()
    routes = Enum.take(route_scan, @max_routes)

    {circuit_lines, lag_lines} =
      Enum.reduce(routes, {[], []}, fn route, {circuits, lags} ->
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
       ] ++
       Enum.reverse(lag_lines) ++
       route_total_lines() ++
       PrometheusMetrics.scrape() ++
       PrometheusRuntime.scrape() ++
       PrometheusRuntime.readiness_samples(Enum.take(chain_scan, @max_routes)) ++
       PrometheusRuntime.family(
         "lasso_observer_route_scan_truncated",
         :gauge,
         "Configured route scan exceeded its cap",
         [{if(length(route_scan) > @max_routes, do: 1, else: 0), []}]
       ) ++
       PrometheusRuntime.family(
         "lasso_observer_chain_scan_truncated",
         :gauge,
         "Configured chain readiness scan exceeded its cap",
         [{if(length(chain_scan) > @max_routes, do: 1, else: 0), []}]
       ))
    |> group_families()
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  rescue
    ArgumentError ->
      "# HELP lasso_observer_available Local metrics observer is available\n# TYPE lasso_observer_available gauge\nlasso_observer_available 0\n"
  end

  # Route and chain builders can repeat a family. Emit each declaration once,
  # before all of that family's samples, including histogram suffix series.
  defp group_families(lines) do
    names =
      for "# TYPE " <> rest <- lines, into: MapSet.new() do
        rest |> String.split(" ", parts: 2) |> hd()
      end

    lines
    |> Enum.group_by(fn
      "# HELP " <> rest ->
        rest |> String.split(" ", parts: 2) |> hd()

      "# TYPE " <> rest ->
        rest |> String.split(" ", parts: 2) |> hd()

      line ->
        name = line |> String.split(["{", " "], parts: 2) |> hd()
        base = String.replace(name, ~r/_(bucket|sum|count)$/, "")
        if MapSet.member?(names, name), do: name, else: base
    end)
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.flat_map(fn {_name, family} ->
      {headers, samples} = Enum.split_with(family, &String.starts_with?(&1, "#"))
      Enum.sort(Enum.uniq(headers)) ++ samples
    end)
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

  defp route_total_lines do
    totals = GenServer.call(__MODULE__, :route_totals, 5_000)

    families = [
      {"lasso_rpc_route_requests_total",
       "Completed routed requests, counted exactly before detail sampling",
       fn counts -> [success: counts.successes, error: counts.total - counts.successes] end},
      {"lasso_rpc_route_duration_seconds_total", "Summed completion time of routed requests",
       fn counts -> [nil: counts.elapsed_us / 1_000_000] end},
      {"lasso_rpc_route_detail_sampled_out_total",
       "Successful requests excluded from detail telemetry by the sampling budget",
       fn counts -> [nil: counts.sampled_out] end}
    ]

    for {name, help, values} <- families,
        line <- family_lines(name, help, totals, values),
        do: line
  catch
    :exit, _reason -> []
  end

  defp family_lines(name, help, totals, values) do
    samples =
      for {{profile, chain, origin}, counts} <- Enum.sort(totals),
          {outcome, value} <- values.(counts) do
        labels = [profile: profile, chain: chain, origin: origin]
        sample(name, value, if(outcome, do: labels ++ [outcome: outcome], else: labels))
      end

    ["# HELP #{name} #{help}", "# TYPE #{name} counter" | samples]
  end

  defp chains do
    ConfigStore.list_profiles()
    |> Stream.filter(&MetricsScope.impl().export_route?/1)
    |> Stream.flat_map(fn profile ->
      ConfigStore.list_chains_for_profile(profile) |> Stream.map(&{profile, &1})
    end)
    |> Enum.take(@max_routes + 1)
  end

  defp routes do
    ConfigStore.list_profiles()
    |> Stream.filter(&MetricsScope.impl().export_route?/1)
    |> Stream.flat_map(fn profile ->
      ConfigStore.list_chains_for_profile(profile)
      |> Stream.flat_map(fn chain ->
        case ConfigStore.get_providers(profile, chain) do
          {:ok, providers} -> Enum.map(providers, &{profile, chain, &1.id})
          _ -> []
        end
      end)
    end)
    |> Enum.take(@max_routes + 1)
  end

  defp route_samples({profile, chain, provider}) do
    instance_id = Catalog.lookup_instance_id(profile, chain, provider)

    circuits =
      for transport <- [:http, :ws],
          observed = circuit_state(instance_id, transport),
          state <- [:closed, :open, :half_open] do
        sample("lasso_circuit_state", if(observed == state, do: 1, else: 0),
          profile: profile,
          chain: chain,
          provider: provider,
          transport: transport,
          state: state
        )
      end

    lag =
      for transport <- [:http, :ws],
          {:ok, blocks} <- [blocks_behind(profile, chain, instance_id, transport)] do
        sample("lasso_provider_head_lag_blocks", blocks,
          profile: profile,
          chain: chain,
          provider: provider,
          transport: transport
        )
      end

    evidence = PrometheusRuntime.route_samples(profile, chain, provider, instance_id, lag != [])
    {circuits ++ evidence, lag}
  end

  # Routing reports lag as the signed offset from the reference, so an upstream behind it is negative.
  defp blocks_behind(profile, chain, instance_id, transport) when is_binary(instance_id) do
    now_ms = System.system_time(:millisecond)

    with %{generation: generation} = catalog <- Catalog.snapshot(),
         {:ok, plan} <- Catalog.get_routing_plan(catalog, profile, chain),
         true <- instance_id in plan.head_scope.instance_ids,
         %{} = route <- Enum.find(plan.providers, &(&1.instance_id == instance_id)),
         {:ok, snapshot} <- BlockRegistry.get_head_snapshot(plan.head_scope, generation, now_ms),
         %{status: status, lag: lag} when status in [:eligible, :lagging] and is_integer(lag) <-
           LagCalculation.assess_transport(
             chain,
             instance_id,
             transport,
             snapshot,
             0,
             now_ms,
             get_in(route, [:head_freshness_ms, transport])
           ) do
      {:ok, max(-lag, 0)}
    else
      _unassessable -> :unknown
    end
  end

  defp blocks_behind(_profile, _chain, _instance_id, _transport), do: :unknown

  defp circuit_state(id, transport) when is_binary(id) do
    case Snapshot.lookup({id, transport}) do
      {:ok, %{control_health: :degraded}} -> :half_open
      {:ok, %{state: state}} -> state
      :missing -> :unknown
    end
  end

  defp circuit_state(_id, _transport), do: :unknown

  defp provider_label(provider) when is_binary(provider),
    do: Lasso.RPC.BoundedIdentifier.encode(provider)

  defp provider_label(_provider), do: "unknown"
  defp method_label(method) when method in @methods, do: method
  defp method_label(_method), do: "other"
  defp outcome_label(result) when result in [:success, :error], do: Atom.to_string(result)
  defp outcome_label(_result), do: "other"

  defp sample(name, value, labels), do: PrometheusMetrics.sample(name, value, labels)
end
