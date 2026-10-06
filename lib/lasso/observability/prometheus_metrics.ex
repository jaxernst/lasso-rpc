defmodule Lasso.Observability.PrometheusMetrics do
  @moduledoc """
  Bounded node-local telemetry counters, gauges and classic histograms.

  Each observation updates one ETS row atomically. Histograms retain integer
  microseconds and disjoint bucket counts; a scrape reads a consistent row and
  emits cumulative buckets in seconds. No request IDs, URLs, error messages,
  wallet addresses or subscription keys become labels.
  """

  alias Lasso.Observability.MetricsScope
  alias Lasso.RPC.BoundedIdentifier

  @table :lasso_prometheus_observations
  @stats :lasso_prometheus_observation_stats
  @capacity 4_096
  @probes 16
  @buckets [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30]
  @methods ~w(eth_blockNumber eth_call eth_chainId eth_estimateGas eth_feeHistory
    eth_getBalance eth_getBlockByHash eth_getBlockByNumber eth_getCode eth_getLogs
    eth_getStorageAt eth_getTransactionByHash eth_getTransactionCount
    eth_getTransactionReceipt eth_sendRawTransaction eth_subscribe eth_unsubscribe
    net_version web3_clientVersion)
  @enums ~w(http ws both client system unknown success error other usable_success
    service_failure timeout capacity_rejection neutral_error cancelled closed open
    half_open manual_open manual_close recovery_success failure_threshold timeout_threshold
    failure_threshold_exceeded recovery_attempt proactive_recovery attempt_recovery
    reopen_due_to_failure resolved
    rate_limit authentication authorization server_error network_error connection_error
    block_not_available capability_violation method_not_found method_error auth_error
    chain_error invalid_params parse_error user_error client_error execution_revert
    deterministic ambiguous capability local_safety
    provider_error provider_failure protocol_error unknown_error unclassified_server_error
    internal_error invalid_request unsupported_method local_capacity_rejection
    circuit_open deadline_exceeded healthy degraded exhausted admission_rejected
    fast_fail degraded_mode degraded_success exhaustion initiated resubscribe_initiated
    completed stale_head_dropped disconnected connected slow_consumer
    continuity_resource_exhausted dropped_event orphaned_event rejected
    stream_bytes delivery_bytes delivery_messages
    node_limit stream_limit client_limit client_message_limit budget_unavailable
    event_buffer_overflow event_too_large invalid_header invalid_log stale_provider
    message_limit mailbox_limit owner_messages owner_bytes node_capacity contention recipient_down
    released active recovered
    critical warning available unavailable not_found)

  @route_labels [:profile, :chain, :provider, :method, :transport, :origin, :outcome]
  @definitions [
    {"lasso_rpc_request_duration_seconds", :histogram,
     "Routed completion duration, including failovers"},
    {"lasso_upstream_attempts_total", :counter,
     "Non-success dispatched attempt diagnostics; successes are not emitted"},
    {"lasso_rpc_failovers_total", :counter, "Failover count reported by routed completions"},
    {"lasso_circuit_transitions_total", :counter, "Circuit transitions by bounded reason"},
    {"lasso_circuit_failures_total", :counter, "Circuit failures by bounded category"},
    {"lasso_circuit_recovery_attempts_total", :counter, "Proactive circuit recovery attempts"},
    {"lasso_websocket_connections_total", :counter,
     "Upstream WebSocket connection lifecycle events"},
    {"lasso_subscription_events_total", :counter,
     "Subscription failover, drops and slow consumer events"},
    {"lasso_subscription_recovery_duration_seconds", :histogram,
     "Subscription failover or canonical repair duration"},
    {"lasso_stream_budget_bytes", :gauge, "Reserved continuity bytes by kind"},
    {"lasso_stream_budget_messages", :gauge, "Queued downstream delivery messages"},
    {"lasso_stream_budget_owners", :gauge, "Processes retaining continuity bytes"},
    {"lasso_stream_ingress_bytes", :gauge, "Internal ingress reserved bytes"},
    {"lasso_stream_ingress_messages", :gauge, "Internal ingress admitted messages"},
    {"lasso_stream_ingress_rejections_total", :counter_value,
     "Cumulative ingress admission rejections"},
    {"lasso_stream_memory_bytes", :gauge, "Combined stream reservations and configured limit"},
    {"lasso_stream_budget_rejections_total", :counter, "Continuity admission rejections"},
    {"lasso_credential_health_events_total", :counter,
     "Managed upstream credential health transitions"}
  ]
  @events [
    [:lasso, :rpc, :request, :stop],
    [:lasso, :rpc, :attempt, :terminal],
    [:lasso, :circuit_breaker, :open],
    [:lasso, :circuit_breaker, :close],
    [:lasso, :circuit_breaker, :half_open],
    [:lasso, :circuit_breaker, :failure],
    [:lasso, :circuit_breaker, :proactive_recovery],
    [:lasso, :websocket, :connected],
    [:lasso, :websocket, :disconnected],
    [:lasso, :subs, :failover, :initiated],
    [:lasso, :subs, :failover, :resubscribe_initiated],
    [:lasso, :subs, :failover, :completed],
    [:lasso, :subs, :failover, :degraded],
    [:lasso, :subs, :reorg_repair, :started],
    [:lasso, :subs, :reorg_repair, :completed],
    [:lasso, :subs, :reorg_repair, :stale_head_dropped],
    [:lasso, :stream, :dropped_event],
    [:lasso, :stream, :slow_consumer],
    [:lasso, :stream, :continuity_resource_exhausted],
    [:lasso, :upstream_subscriptions, :orphaned_event],
    [:lasso, :stream, :continuity_budget, :snapshot],
    [:lasso, :stream, :continuity_budget, :rejected],
    [:lasso, :stream, :ingress, :snapshot],
    [:lasso, :stream, :memory, :snapshot],
    [:lasso, :provider, :credential_health]
  ]

  @doc "Telemetry events the exporter observes."
  def events, do: @events

  @doc "Creates the observation tables; called once by `Lasso.Observability.Prometheus`."
  def init do
    :ets.new(@table, [:named_table, :set, :public, write_concurrency: true])
    :ets.new(@stats, [:named_table, :set, :public, write_concurrency: true])
    :ets.insert(@stats, [{:dropped, 0}, {:invalid, 0}])
  end

  @doc "Telemetry handler that records one bounded observation."
  def handle_event(event, measurements, metadata, _config) do
    observe(event, measurements, MetricsScope.impl().bound(metadata))
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp observe([:lasso, :rpc, :request, :stop], ms, meta) do
    labels = route_labels(meta)
    histogram("lasso_rpc_request_duration_seconds", labels, ms[:duration])
    counter("lasso_rpc_failovers_total", Keyword.delete(labels, :outcome), meta[:failovers] || 0)
  end

  defp observe([:lasso, :rpc, :attempt, :terminal], _ms, meta) do
    labels = [
      profile: identity(meta[:profile]),
      chain: chain(meta),
      provider: identity(meta[:provider_id]),
      transport: enum(meta[:transport]),
      origin: enum(meta[:request_origin]),
      outcome: enum(meta[:outcome]),
      category: enum(meta[:error_category])
    ]

    counter("lasso_upstream_attempts_total", labels)
  end

  defp observe([:lasso, :circuit_breaker, kind], _ms, meta) do
    labels = [
      instance_id: instance_identity(meta[:instance_id]),
      transport: enum(meta[:transport])
    ]

    case kind do
      state when state in [:open, :close, :half_open] ->
        counter(
          "lasso_circuit_transitions_total",
          labels ++ [state: to_string(state), reason: enum(meta[:reason])]
        )

      :failure ->
        counter(
          "lasso_circuit_failures_total",
          labels ++ [category: enum(meta[:error_category]), state: enum(meta[:circuit_state])]
        )

      :proactive_recovery ->
        counter("lasso_circuit_recovery_attempts_total", labels)
    end
  end

  defp observe([:lasso, :websocket, kind], _ms, meta) do
    counter("lasso_websocket_connections_total",
      chain: chain(meta),
      instance_id: instance_identity(meta[:provider_id]),
      event: enum(kind)
    )
  end

  defp observe([:lasso, :subs, family, kind], ms, meta) do
    labels = [profile: identity(meta[:profile]), chain: chain(meta), kind: "#{family}_#{kind}"]
    counter("lasso_subscription_events_total", labels)

    if kind == :completed,
      do: histogram("lasso_subscription_recovery_duration_seconds", labels, ms[:duration_ms])
  end

  defp observe([:lasso, :stream, :continuity_budget, :snapshot], ms, _meta) do
    for kind <- [:used_bytes, :stream_bytes, :delivery_bytes, :peak_bytes] do
      gauge("lasso_stream_budget_bytes", [kind: to_string(kind)], ms[kind])
    end

    gauge("lasso_stream_budget_messages", [], ms[:delivery_messages])
    gauge("lasso_stream_budget_owners", [], ms[:owners])
  end

  defp observe([:lasso, :stream, :continuity_budget, :rejected], ms, meta) do
    counter(
      "lasso_stream_budget_rejections_total",
      [kind: enum(meta[:kind]), reason: enum(meta[:reason])],
      ms[:count] || 1
    )
  end

  defp observe([:lasso, :stream, :ingress, :snapshot], ms, _meta) do
    gauge("lasso_stream_ingress_bytes", [], ms[:used_bytes])
    gauge("lasso_stream_ingress_messages", [], ms[:messages])
    gauge("lasso_stream_ingress_rejections_total", [], ms[:rejected])
  end

  defp observe([:lasso, :stream, :memory, :snapshot], ms, _meta) do
    gauge("lasso_stream_memory_bytes", [kind: "used"], ms[:used_bytes])
    gauge("lasso_stream_memory_bytes", [kind: "limit"], ms[:limit_bytes])
  end

  defp observe([:lasso, :stream, kind], _ms, meta) do
    counter(
      "lasso_subscription_events_total",
      basic_labels(meta) ++ [kind: enum(kind), reason: enum(meta[:reason])]
    )
  end

  defp observe([:lasso, :upstream_subscriptions, :orphaned_event], _ms, meta) do
    counter("lasso_subscription_events_total", basic_labels(meta) ++ [kind: "orphaned_event"])
  end

  defp observe([:lasso, :provider, :credential_health], _ms, meta) do
    counter("lasso_credential_health_events_total",
      provider: identity(meta[:provider_id]),
      status: enum(meta[:status])
    )
  end

  defp observe(_event, _ms, _meta), do: :ok

  defp basic_labels(meta) do
    [
      profile: identity(meta[:profile]),
      chain: chain(meta),
      provider: identity(meta[:provider_id])
    ]
  end

  defp route_labels(meta) do
    values = [
      profile: identity(meta[:profile]),
      chain: chain(meta),
      provider: identity(meta[:provider_id]),
      method: method(meta[:method]),
      transport: enum(meta[:transport]),
      origin: enum(meta[:request_origin]),
      outcome: enum(meta[:outcome] || meta[:result])
    ]

    Keyword.take(values, @route_labels)
  end

  defp chain(meta) do
    case meta[:chain_id] || meta[:chain] do
      id when is_integer(id) and id > 0 -> Integer.to_string(id)
      label when is_binary(label) -> identity(label)
      _ -> "unknown"
    end
  end

  # Physical IDs include a credential fingerprint; truncation can merge upstreams.
  defp instance_identity(value) when is_binary(value), do: value
  defp instance_identity(_), do: "unknown"

  defp identity(value) when is_binary(value), do: BoundedIdentifier.encode(value)
  defp identity(_), do: "unknown"
  defp method(value) when value in @methods, do: value
  defp method(_), do: "other"
  defp enum(nil), do: "unknown"
  defp enum(value) when is_atom(value), do: enum(Atom.to_string(value))
  defp enum(value) when value in @enums, do: value
  defp enum(_), do: "other"

  defp counter(name, labels, count \\ 1)

  defp counter(name, labels, count) when is_integer(count) and count > 0 do
    update(name, labels, [{3, count}])
  end

  defp counter(_name, _labels, 0), do: :ok
  defp counter(_name, _labels, _value), do: invalid()

  defp gauge(name, labels, value) when is_integer(value) and value >= 0 do
    with {:ok, slot} <- slot({name, labels}), do: :ets.update_element(@table, slot, {4, value})
  end

  defp gauge(_name, _labels, _value), do: invalid()

  defp histogram(name, labels, ms) when is_number(ms) and ms >= 0 do
    us = round(ms * 1000)
    bucket = Enum.find_index(@buckets, &(us <= round(&1 * 1_000_000))) || length(@buckets)
    update(name, labels, [{3, 1}, {4, us}, {5 + bucket, 1}])
  end

  defp histogram(_name, _labels, _ms), do: invalid()

  defp update(name, labels, updates) do
    with {:ok, slot} <- slot({name, labels}), do: :ets.update_counter(@table, slot, updates)
  end

  defp slot(key) do
    first = :erlang.phash2(key, @capacity)

    Enum.reduce_while(0..(@probes - 1), :full, fn offset, _acc ->
      position = rem(first + offset, @capacity)

      case :ets.lookup(@table, position) do
        [] ->
          row = List.to_tuple([position, key, 0, 0 | List.duplicate(0, length(@buckets) + 1)])

          if :ets.insert_new(@table, row) do
            {:halt, {:ok, position}}
          else
            case :ets.lookup(@table, position) do
              [row] when elem(row, 1) == key -> {:halt, {:ok, position}}
              _ -> {:cont, :full}
            end
          end

        [row] when elem(row, 1) == key ->
          {:halt, {:ok, position}}

        _ ->
          {:cont, :full}
      end
    end)
    |> case do
      :full ->
        :ets.update_counter(@stats, :dropped, {2, 1})
        :full

      found ->
        found
    end
  end

  defp invalid, do: :ets.update_counter(@stats, :invalid, {2, 1})

  @doc "Observer occupancy and admission losses."
  def stats do
    %{
      series: :ets.info(@table, :size),
      capacity: @capacity,
      dropped: :ets.lookup_element(@stats, :dropped, 2),
      invalid: :ets.lookup_element(@stats, :invalid, 2)
    }
  rescue
    ArgumentError -> %{series: 0, capacity: @capacity, dropped: 0, invalid: 0}
  end

  @doc "Additional bounded metric families as Prometheus text lines."
  def scrape do
    rows = :ets.tab2list(@table)

    families =
      Enum.flat_map(@definitions, fn {name, type, help} ->
        wire_type = if type == :counter_value, do: :counter, else: type

        [
          "# HELP #{name} #{help}",
          "# TYPE #{name} #{wire_type}"
          | Enum.flat_map(rows, fn row ->
              case elem(row, 1) do
                {^name, labels} -> render(name, type, labels, row)
                _ -> []
              end
            end)
        ]
      end)

    s = stats()

    families ++
      [
        "# HELP lasso_observer_available Local metrics observer is available",
        "# TYPE lasso_observer_available gauge",
        sample("lasso_observer_available", 1, []),
        "# HELP lasso_observer_series Current bounded observation rows",
        "# TYPE lasso_observer_series gauge",
        sample("lasso_observer_series", s.series, []),
        "# HELP lasso_observer_capacity Maximum observation rows",
        "# TYPE lasso_observer_capacity gauge",
        sample("lasso_observer_capacity", s.capacity, []),
        "# HELP lasso_observer_dropped_total Observations omitted by bounded admission",
        "# TYPE lasso_observer_dropped_total counter",
        sample("lasso_observer_dropped_total", s.dropped, []),
        "# HELP lasso_observer_invalid_total Invalid numeric observations omitted",
        "# TYPE lasso_observer_invalid_total counter",
        sample("lasso_observer_invalid_total", s.invalid, [])
      ]
  end

  defp render(name, :counter, labels, row), do: [sample(name, elem(row, 2), labels)]

  defp render(name, type, labels, row) when type in [:gauge, :counter_value],
    do: [sample(name, elem(row, 3), labels)]

  defp render(name, :histogram, labels, row) do
    {lines, _count} =
      Enum.map_reduce(Enum.with_index(@buckets), 0, fn {boundary, index}, count ->
        count = count + elem(row, 4 + index)
        {sample(name <> "_bucket", count, labels ++ [le: boundary]), count}
      end)

    lines ++
      [
        sample(name <> "_bucket", elem(row, 2), labels ++ [le: "+Inf"]),
        sample(name <> "_count", elem(row, 2), labels),
        sample(name <> "_sum", elem(row, 3) / 1_000_000, labels)
      ]
  end

  @doc "Formats one exposition line, encoding profile and provider labels."
  def sample(name, value, labels) do
    encoded =
      Enum.map_join(labels, ",", fn {key, item} ->
        item = if key in [:profile, :provider], do: identity(item), else: item
        ~s(#{key}="#{escape(item)}")
      end)

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
