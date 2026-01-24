# BEAM VM Analysis for Lasso RPC Dashboard Clustering Architecture
# This script analyzes process mailbox, GC, and message copying characteristics

# Sample RoutingDecision struct
routing_decision = %{
  __struct__: Lasso.Events.RoutingDecision,
  ts: 1706123456789,
  request_id: "req_abc123def456ghi789",
  profile: "default",
  source_node: :"node1@10.0.1.5",
  source_region: "us-west-2",
  chain: "ethereum_mainnet",
  method: "eth_getBlockByNumber",
  strategy: "fastest_responder",
  provider_id: "alchemy_primary",
  transport: :http,
  duration_ms: 45,
  result: :success,
  failover_count: 0
}

# Calculate struct size in words (BEAM memory unit)
struct_size_words = :erts_debug.flat_size(routing_decision)
struct_size_bytes = struct_size_words * :erlang.system_info(:wordsize)

IO.puts("=== RoutingDecision Struct Memory Analysis ===")
IO.puts("Size in words: #{struct_size_words}")
IO.puts("Size in bytes: #{struct_size_bytes}")
IO.puts("Word size: #{:erlang.system_info(:wordsize)} bytes")
IO.puts("")

# Simulate a batch of 100 events
batch_100 = List.duplicate(routing_decision, 100)
batch_size_words = :erts_debug.flat_size(batch_100)
batch_size_bytes = batch_size_words * :erlang.system_info(:wordsize)

IO.puts("=== Batch of 100 Events ===")
IO.puts("Total size (words): #{batch_size_words}")
IO.puts("Total size (bytes): #{batch_size_bytes}")
IO.puts("Total size (KB): #{Float.round(batch_size_bytes / 1024, 2)}")
IO.puts("")

# Simulate provider metrics broadcast
provider_metrics = %{
  provider_id: "alchemy_primary",
  chain: "ethereum_mainnet",
  aggregate: %{
    total_calls: 1500,
    success_rate: 98.5,
    error_count: 22,
    p50_latency: 45,
    p95_latency: 120,
    traffic_pct: 35.2,
    events_per_second: 25.0,
    block_height: 19_123_456,
    block_lag: -2,
    regions_reporting: ["us-west-2", "us-east-1", "eu-west-1"]
  },
  by_region: %{
    "us-west-2" => %{
      total_calls: 800,
      success_rate: 99.1,
      error_count: 7,
      p50_latency: 38,
      p95_latency: 95,
      traffic_pct: 53.3,
      events_per_second: 13.3,
      block_height: 19_123_456,
      block_lag: 0,
      circuit: %{http: :closed, ws: :closed}
    },
    "us-east-1" => %{
      total_calls: 450,
      success_rate: 97.8,
      error_count: 10,
      p50_latency: 52,
      p95_latency: 145,
      traffic_pct: 30.0,
      events_per_second: 7.5,
      block_height: 19_123_454,
      block_lag: -2,
      circuit: %{http: :closed, ws: :closed}
    },
    "eu-west-1" => %{
      total_calls: 250,
      success_rate: 98.0,
      error_count: 5,
      p50_latency: 48,
      p95_latency: 130,
      traffic_pct: 16.7,
      events_per_second: 4.2,
      block_height: 19_123_455,
      block_lag: -1,
      circuit: %{http: :closed, ws: :closed}
    }
  },
  updated_at: 1706123456789
}

metrics_size_words = :erts_debug.flat_size(provider_metrics)
metrics_size_bytes = metrics_size_words * :erlang.system_info(:wordsize)

IO.puts("=== Provider Metrics Broadcast Message ===")
IO.puts("Size (words): #{metrics_size_words}")
IO.puts("Size (bytes): #{metrics_size_bytes}")
IO.puts("Size (KB): #{Float.round(metrics_size_bytes / 1024, 2)}")
IO.puts("")

# Simulate full metrics update with 10 providers
full_metrics_update = %{}
|> Map.put("alchemy_primary", provider_metrics)
|> Map.put("infura_primary", provider_metrics)
|> Map.put("quicknode_1", provider_metrics)
|> Map.put("ankr_1", provider_metrics)
|> Map.put("llamarpc_1", provider_metrics)
|> Map.put("alchemy_fallback", provider_metrics)
|> Map.put("infura_fallback", provider_metrics)
|> Map.put("blastapi_1", provider_metrics)
|> Map.put("publicnode_1", provider_metrics)
|> Map.put("cloudflare_1", provider_metrics)

full_update_size_words = :erts_debug.flat_size(full_metrics_update)
full_update_size_bytes = full_update_size_words * :erlang.system_info(:wordsize)

IO.puts("=== Full Metrics Update (10 providers) ===")
IO.puts("Size (words): #{full_update_size_words}")
IO.puts("Size (bytes): #{full_update_size_bytes}")
IO.puts("Size (KB): #{Float.round(full_update_size_bytes / 1024, 2)}")
IO.puts("")

IO.puts("=== Load Scenario Analysis ===")
IO.puts("")

scenarios = [
  %{name: "Easy", nodes: 3, liveviews: 5, events_per_sec: 50},
  %{name: "Medium", nodes: 5, liveviews: 15, events_per_sec: 400},
  %{name: "Worst", nodes: 7, liveviews: 20, events_per_sec: 3000}
]

for scenario <- scenarios do
  IO.puts("=== #{scenario.name} Scenario ===")
  IO.puts("Nodes: #{scenario.nodes}, LiveViews: #{scenario.liveviews}, Events/sec: #{scenario.events_per_sec}")

  # Events per 500ms batch window
  batch_window_events = div(scenario.events_per_sec, 2)

  # Total events the aggregator processes per second (all nodes)
  aggregator_events_per_sec = scenario.events_per_sec * scenario.nodes

  # Mailbox pressure on aggregator
  aggregator_batch_events = div(aggregator_events_per_sec, 2)
  aggregator_batch_kb = (aggregator_batch_events * struct_size_bytes) / 1024

  # Metrics broadcasts per second (2 per second, 500ms interval)
  metrics_broadcasts_per_sec = 2

  # Total metrics broadcast traffic to all LiveViews
  metrics_traffic_per_lv = (metrics_broadcasts_per_sec * full_update_size_bytes) / 1024
  total_metrics_kb_per_sec = metrics_traffic_per_lv * scenario.liveviews

  # LiveView mailbox pressure (events bypass aggregator, direct from PubSub)
  # Each LiveView receives routing decisions from ALL nodes
  lv_events_per_sec = scenario.events_per_sec * scenario.nodes
  lv_event_kb_per_sec = (lv_events_per_sec * struct_size_bytes) / 1024

  # Combined LiveView mailbox pressure
  lv_total_kb_per_sec = lv_event_kb_per_sec + metrics_traffic_per_lv

  IO.puts("")
  IO.puts("  Aggregator:")
  IO.puts("    Events/sec from all nodes: #{aggregator_events_per_sec}")
  IO.puts("    Events/batch (500ms): #{aggregator_batch_events}")
  IO.puts("    Batch size: #{Float.round(aggregator_batch_kb, 2)} KB")
  IO.puts("    Mailbox growth rate: #{Float.round(aggregator_batch_kb * 2, 2)} KB/sec")

  IO.puts("")
  IO.puts("  Each LiveView:")
  IO.puts("    Direct RoutingDecision events/sec: #{lv_events_per_sec}")
  IO.puts("    Event traffic: #{Float.round(lv_event_kb_per_sec, 2)} KB/sec")
  IO.puts("    Metrics traffic: #{Float.round(metrics_traffic_per_lv, 2)} KB/sec")
  IO.puts("    TOTAL mailbox growth: #{Float.round(lv_total_kb_per_sec, 2)} KB/sec")

  IO.puts("")
  IO.puts("  All #{scenario.liveviews} LiveViews combined:")
  IO.puts("    Total metrics broadcast: #{Float.round(total_metrics_kb_per_sec, 2)} KB/sec")
  IO.puts("    Total event traffic: #{Float.round(lv_event_kb_per_sec * scenario.liveviews, 2)} KB/sec")
  IO.puts("    TOTAL cluster traffic: #{Float.round((lv_event_kb_per_sec + metrics_traffic_per_lv) * scenario.liveviews, 2)} KB/sec")

  # Message copying calculations
  # Every send() to a different process copies the message
  copies_per_event = scenario.liveviews  # Each event copied to each LV
  total_copies_per_sec = lv_events_per_sec * copies_per_event
  copy_overhead_kb_per_sec = (total_copies_per_sec * struct_size_bytes) / 1024

  IO.puts("")
  IO.puts("  Message Copying Overhead:")
  IO.puts("    Event copies/sec: #{total_copies_per_sec}")
  IO.puts("    Copy bandwidth: #{Float.round(copy_overhead_kb_per_sec, 2)} KB/sec")

  # GC pressure estimation
  # Events are created, copied, processed, then discarded
  # In 60s window, we keep max 200 events per provider/chain/region
  # But we're creating much more
  events_created_per_min = aggregator_events_per_sec * 60
  events_retained = 200 * 5  # Assume 5 provider/chain/region keys
  events_garbage_per_min = events_created_per_min - events_retained
  gc_garbage_kb_per_min = (events_garbage_per_min * struct_size_bytes) / 1024

  IO.puts("")
  IO.puts("  GC Pressure (Aggregator):")
  IO.puts("    Events created/min: #{events_created_per_min}")
  IO.puts("    Events retained: #{events_retained}")
  IO.puts("    Events GC'd/min: #{events_garbage_per_min}")
  IO.puts("    GC work: #{Float.round(gc_garbage_kb_per_min, 2)} KB/min")

  IO.puts("")
  IO.puts("---")
  IO.puts("")
end

IO.puts("=== BEAM VM Scheduler Information ===")
IO.puts("Schedulers online: #{:erlang.system_info(:schedulers_online)}")
IO.puts("Schedulers available: #{:erlang.system_info(:schedulers)}")
IO.puts("")

IO.puts("=== Message Passing Characteristics ===")
IO.puts("Messages between processes are copied (not shared)")
IO.puts("Large binaries (>64 bytes) are reference-counted, but struct fields are copied")
IO.puts("String fields in RoutingDecision are binaries, so only references are copied")
IO.puts("This significantly reduces actual copying overhead")
IO.puts("")

IO.puts("=== Recommendations ===")
IO.puts("1. Consider batching PubSub broadcasts to LiveViews")
IO.puts("2. Use process_flag(:message_queue_data, :off_heap) for high-traffic processes")
IO.puts("3. Monitor mailbox sizes with Process.info(pid, :message_queue_len)")
IO.puts("4. Consider ETS for shared state instead of message passing")
IO.puts("5. Use :observer.start() to watch scheduler utilization")
