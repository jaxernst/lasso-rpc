defmodule Lasso.Telemetry do
  @moduledoc """
  Telemetry integration for Lasso observability.

  Provides comprehensive metrics collection, event tracking, and
  performance monitoring for the multi-provider RPC system.
  """

  use Supervisor
  require Logger
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will periodically execute the given period measurements
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Attaches default telemetry handlers for logging operational events.
  Called after the supervisor tree is started.
  """
  def attach_default_handlers do
    Lasso.TelemetryLogger.attach()
  end

  @doc """
  Returns a list of Telemetry.Metrics for LiveDashboard and other metric reporters.
  """
  def metrics do
    [
      # Circuit breaker admission latency (new admit/report flow)
      distribution("lasso.circuit_breaker.admit.latency",
        event_name: [:lasso, :circuit_breaker, :admit],
        measurement: :admit_call_ms,
        unit: {:native, :millisecond},
        description: "Circuit breaker admission call latency",
        tags: [:chain, :provider_id, :transport, :decision],
        reporter_options: [
          buckets: [1, 2, 5, 10, 25, 50, 100, 250, 500, 1000]
        ]
      ),

      # Circuit breaker decision counts
      counter("lasso.circuit_breaker.admit.count",
        event_name: [:lasso, :circuit_breaker, :admit],
        description: "Circuit breaker admission decisions",
        tags: [:chain, :provider_id, :transport, :decision]
      ),

      # HTTP transport I/O latency (actual network time)
      distribution("lasso.http.request.io.latency",
        event_name: [:lasso, :http, :request, :io],
        measurement: :io_ms,
        unit: {:native, :millisecond},
        description: "HTTP request I/O time (network + provider processing)",
        tags: [:provider_id, :method],
        reporter_options: [
          buckets: [10, 25, 50, 100, 250, 500, 1000, 2000, 5000]
        ]
      ),

      # WebSocket request I/O latency (send to response)
      distribution("lasso.ws.request.io.latency",
        event_name: [:lasso, :ws, :request, :io],
        measurement: :io_ms,
        unit: {:native, :millisecond},
        description: "WebSocket request I/O time (send to response)",
        tags: [:provider_id, :method],
        reporter_options: [
          buckets: [10, 25, 50, 100, 250, 500, 1000, 2000, 5000]
        ]
      ),

      # RPC request overall latency
      distribution("lasso.rpc.request.duration",
        event_name: [:lasso, :rpc, :request, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        description: "End-to-end RPC request duration",
        tags: [:chain, :method, :provider_id, :transport, :status],
        reporter_options: [
          buckets: [10, 25, 50, 100, 250, 500, 1000, 2000, 5000, 10_000]
        ]
      ),

      # RPC request counts
      counter("lasso.rpc.request.count",
        event_name: [:lasso, :rpc, :request, :stop],
        description: "RPC request count",
        tags: [:chain, :method, :provider_id, :transport, :status]
      ),

      # Circuit breaker state changes (individual events for each transition type)
      counter("lasso.circuit_breaker.open.count",
        event_name: [:lasso, :circuit_breaker, :open],
        description: "Circuit breaker openings",
        tags: [:chain, :provider_id, :transport, :reason]
      ),
      counter("lasso.circuit_breaker.close.count",
        event_name: [:lasso, :circuit_breaker, :close],
        description: "Circuit breaker closings",
        tags: [:chain, :provider_id, :transport, :reason]
      ),
      counter("lasso.circuit_breaker.half_open.count",
        event_name: [:lasso, :circuit_breaker, :half_open],
        description: "Circuit breaker half-open transitions",
        tags: [:chain, :provider_id, :transport, :reason]
      ),
      counter("lasso.circuit_breaker.proactive_recovery.count",
        event_name: [:lasso, :circuit_breaker, :proactive_recovery],
        description: "Circuit breaker proactive recovery attempts",
        tags: [:chain, :provider_id, :transport]
      ),
      counter("lasso.circuit_breaker.failure.count",
        event_name: [:lasso, :circuit_breaker, :failure],
        description: "Circuit breaker failures by category and state",
        tags: [:chain, :provider_id, :transport, :error_category, :circuit_state]
      ),
      counter("lasso.circuit_breaker.timeout.count",
        event_name: [:lasso, :circuit_breaker, :timeout],
        description: "Circuit breaker request timeouts",
        tags: [:chain, :provider_id, :transport]
      ),

      # WebSocket connection events
      counter("lasso.websocket.connected.count",
        event_name: [:lasso, :websocket, :connected],
        description: "WebSocket connections established",
        tags: [:provider_id, :chain]
      ),
      counter("lasso.websocket.disconnected.count",
        event_name: [:lasso, :websocket, :disconnected],
        description: "WebSocket disconnections",
        tags: [:provider_id, :chain, :unexpected]
      ),

      # WebSocket request latency (existing events)
      distribution("lasso.websocket.request.duration",
        event_name: [:lasso, :websocket, :request, :completed],
        measurement: :duration_ms,
        unit: {:native, :millisecond},
        description: "WebSocket request duration",
        tags: [:provider_id, :method, :status],
        reporter_options: [
          buckets: [10, 25, 50, 100, 250, 500, 1000, 2000, 5000]
        ]
      ),

      # Provider health metrics
      counter("lasso.provider.status.count",
        event_name: [:lasso, :provider, :status],
        description: "Provider status changes",
        tags: [:chain, :provider_id, :status]
      ),

      # Failover events (individual counters for each type)
      counter("lasso.failover.fast_fail.count",
        event_name: [:lasso, :failover, :fast_fail],
        description: "Provider failovers triggered",
        tags: [:chain, :provider_id, :transport, :error_category]
      ),
      counter("lasso.failover.circuit_open.count",
        event_name: [:lasso, :failover, :circuit_open],
        description: "Requests skipped due to open circuit",
        tags: [:chain, :provider_id, :transport]
      ),
      counter("lasso.failover.degraded_mode.count",
        event_name: [:lasso, :failover, :degraded_mode],
        description: "Degraded mode entries (trying half-open circuits)",
        tags: [:chain]
      ),
      counter("lasso.failover.degraded_success.count",
        event_name: [:lasso, :failover, :degraded_success],
        description: "Successful recoveries via degraded mode",
        tags: [:chain, :provider_id, :transport]
      ),
      counter("lasso.failover.exhaustion.count",
        event_name: [:lasso, :failover, :exhaustion],
        description: "All providers exhausted",
        tags: [:chain]
      ),

      # Cluster topology events
      counter("lasso.cluster.topology.node_connected.count",
        event_name: [:lasso, :cluster, :topology, :node_connected],
        description: "Cluster nodes connected",
        tags: [:node]
      ),
      counter("lasso.cluster.topology.node_disconnected.count",
        event_name: [:lasso, :cluster, :topology, :node_disconnected],
        description: "Cluster nodes disconnected",
        tags: [:node]
      ),

      # Dropped events in degraded mode
      counter("lasso.stream.dropped_event.count",
        event_name: [:lasso, :stream, :dropped_event],
        description: "Events dropped in degraded mode",
        tags: [:chain, :reason]
      ),

      # WebSocket pending cleanup
      counter("lasso.websocket.pending_cleanup.count",
        event_name: [:lasso, :websocket, :pending_cleanup],
        description: "WebSocket pending request cleanups",
        tags: [:provider_id]
      ),
      summary("lasso.websocket.pending_cleanup.pending_count",
        event_name: [:lasso, :websocket, :pending_cleanup],
        measurement: :pending_count,
        description: "Number of pending requests cleaned up per disconnect"
      ),

      # Orphaned subscription events
      counter("lasso.upstream_subscriptions.orphaned_event.count",
        event_name: [:lasso, :upstream_subscriptions, :orphaned_event],
        description: "Orphaned subscription events received",
        tags: [:chain]
      ),

      # Dashboard cluster metrics cache
      counter("lasso_web.dashboard.cache.count",
        event_name: [:lasso_web, :dashboard, :cache],
        description: "Dashboard cluster metrics cache operations",
        tags: [:result, :profile, :chain]
      ),

      # Dashboard cluster RPC calls
      distribution("lasso_web.dashboard.cluster_rpc.duration",
        event_name: [:lasso_web, :dashboard, :cluster_rpc],
        measurement: :duration_ms,
        unit: {:native, :millisecond},
        description: "Dashboard cluster RPC call duration",
        tags: [:profile, :chain],
        reporter_options: [
          buckets: [50, 100, 250, 500, 1000, 2000, 5000]
        ]
      ),
      counter("lasso_web.dashboard.cluster_rpc.node_count",
        event_name: [:lasso_web, :dashboard, :cluster_rpc],
        measurement: :node_count,
        description: "Cluster nodes contacted for dashboard metrics"
      ),
      counter("lasso_web.dashboard.cluster_rpc.success_count",
        event_name: [:lasso_web, :dashboard, :cluster_rpc],
        measurement: :success_count,
        description: "Successful node responses for dashboard metrics"
      ),
      counter("lasso_web.dashboard.cluster_rpc.bad_count",
        event_name: [:lasso_web, :dashboard, :cluster_rpc],
        measurement: :bad_count,
        description: "Failed node responses for dashboard metrics"
      ),

      # VM metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      # Periodic system metrics
      {__MODULE__, :measure_vm_memory, []},
      {__MODULE__, :measure_run_queue, []}
    ]
  end

  def measure_vm_memory do
    memory = :erlang.memory()
    total = Keyword.get(memory, :total, 0)
    :telemetry.execute([:vm, :memory], %{total: total}, %{})
  end

  def measure_run_queue do
    total = :erlang.statistics(:run_queue)
    cpu = :erlang.statistics(:run_queue)
    io = :erlang.statistics(:io)

    :telemetry.execute(
      [:vm, :total_run_queue_lengths],
      %{total: total, cpu: cpu, io: elem(io, 0)},
      %{}
    )
  end
end
