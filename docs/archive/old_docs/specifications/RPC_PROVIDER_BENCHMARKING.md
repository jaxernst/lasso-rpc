# RPC Provider Benchmarking System

## Overview

ChainPulse includes a comprehensive passive benchmarking system that tracks real-world performance of RPC providers without synthetic load testing. The system captures racing metrics from event delivery competitions and RPC call performance data to provide actionable insights for provider selection and optimization.

## Key Features

### ✅ **Passive Performance Tracking**
- **Event Racing Metrics**: Tracks which provider delivers blockchain events fastest
- **RPC Call Benchmarking**: Measures latency and success rates for JSON-RPC methods
- **Zero Synthetic Load**: All metrics collected from actual usage patterns
- **Real-time Analysis**: Live performance scoring and rankings

### ✅ **Comprehensive Data Collection**
- **Per-Chain Metrics**: Separate benchmarking for each blockchain network
- **Event Type Granularity**: Track performance by event type (`newHeads`, `logs`, `pendingTransactions`, etc.)
- **RPC Method Granularity**: Track performance by RPC method (`eth_getLogs`, `eth_getBalance`, etc.)
- **Historical Persistence**: Automatic snapshots for trend analysis

### ✅ **Live Dashboard Integration**
- **Racing Leaderboard**: Real-time provider rankings with win rates and margins
- **RPC Performance Matrix**: Latency and success rate visualization
- **Chain Selection**: Switch between different blockchain networks
- **Interactive Controls**: Filter and explore performance data

## Architecture

### Core Components

```
┌─────────────────────────────────────────┐
│           Benchmarking System           │
├─────────────────────────────────────────┤
│                                         │
│  ┌─────────────┐    ┌─────────────────┐ │
│  │ MessageAgg- │    │  WSConnection   │ │
│  │   regator   │    │  RPC Methods    │ │
│  │  (Racing)   │    │ (RPC Timing)    │ │
│  └─────────────┘    └─────────────────┘ │
│         │                     │         │
│         └──────────┬──────────┘         │
│                    │                    │
│           ┌─────────▼─────────┐         │
│           │  BenchmarkStore   │         │
│           │   ETS Tables      │         │
│           └─────────┬─────────┘         │
│                     │                   │
│           ┌─────────▼─────────┐         │
│           │   Persistence     │         │
│           │  JSON Snapshots   │         │
│           └───────────────────┘         │
│                                         │
├─────────────────────────────────────────┤
│                                         │
│           LiveView Dashboard            │
│         Benchmarks Visualization        │
│                                         │
└─────────────────────────────────────────┘
```

### Data Flow

1. **Event Racing**: `MessageAggregator` tracks which provider delivers events first
2. **RPC Timing**: `WSConnection` measures request-response latency for all RPC calls
3. **Metric Storage**: `BenchmarkStore` aggregates data in ETS tables with memory management
4. **Persistence**: Hourly snapshots saved to JSON files for historical analysis
5. **Visualization**: LiveView dashboard displays real-time performance data

## Data Model

### Racing Metrics
```elixir
# Detailed racing entries (24hr retention)
{timestamp, provider_id, event_type, result, margin_ms}

# Examples:
{1640995200000, "infura_ethereum", "newHeads", :win, 0}
{1640995200050, "alchemy_ethereum", "newHeads", :loss, 50}
```

### RPC Call Metrics
```elixir
# Detailed RPC entries (24hr retention)
{timestamp, provider_id, method, duration_ms, result}

# Examples:
{1640995200000, "infura_ethereum", "eth_getLogs", 150, :success}
{1640995201000, "alchemy_ethereum", "eth_getBalance", 89, :success}
```

### Aggregated Scores
```elixir
# Provider performance summaries
{provider_id, event_type, :racing} => {wins, total_races, avg_margin, last_updated}
{provider_id, method, :rpc} => {successes, total_calls, avg_duration, last_updated}
```

## Performance Metrics

### Racing Performance
- **Win Rate**: Percentage of events delivered first
- **Average Margin**: Time difference when losing races (lower is better)  
- **Total Races**: Volume of events participated in
- **Score**: Composite performance score combining win rate, margin, and confidence

### RPC Performance
- **Average Latency**: Mean response time per method
- **Success Rate**: Percentage of successful responses
- **Total Calls**: Volume of RPC requests
- **P95/P99 Latency**: Response time percentiles (planned)

## Dashboard Features

### Racing Leaderboard
- Real-time provider rankings per chain
- Win rate percentages and race statistics
- Average margin when losing races
- Visual performance indicators

### RPC Performance Matrix
- Latency by provider and method
- Success rates and failure tracking
- Historical trend indicators
- Interactive filtering and sorting

### Chain Selection
- Switch between Ethereum, Polygon, Arbitrum, BSC
- Per-chain performance isolation
- Cross-chain provider comparison (future)

## Configuration

### Memory Management
```elixir
# ETS table limits and cleanup
@max_entries_per_chain 86_400    # ~1 entry per second for 24 hours
@cleanup_interval 3_600_000      # 1 hour in milliseconds
```

### Event Type Classification
- `newHeads`: New block notifications
- `logs`: Transaction event logs
- `pendingTransactions`: Pending transaction notifications  
- `syncing`: Sync status updates
- `subscription`: Generic subscription events

### RPC Method Tracking
- `eth_getLogs`: Event log queries
- `eth_getBalance`: Balance queries
- `eth_getBlockByNumber`: Block data queries
- `eth_blockNumber`: Latest block queries
- Additional methods as configured

## API Interface

### BenchmarkStore Public API
```elixir
# Recording metrics (called automatically)
BenchmarkStore.record_event_race_win(chain_name, provider_id, event_type, timestamp)
BenchmarkStore.record_event_race_loss(chain_name, provider_id, event_type, timestamp, margin_ms)
BenchmarkStore.record_rpc_call(chain_name, provider_id, method, duration_ms, result)

# Querying data (for dashboard)
BenchmarkStore.get_provider_leaderboard(chain_name)
BenchmarkStore.get_provider_metrics(chain_name, provider_id)  
BenchmarkStore.get_realtime_stats(chain_name)
```

### Persistence API
```elixir
# Snapshot management
Persistence.save_snapshot(chain_name, snapshot_data)
Persistence.load_snapshots(chain_name, hours_back)
Persistence.get_snapshot_summary()
```

## Integration Points

### Automatic Data Collection
- **MessageAggregator**: Racing metrics collected on every event deduplication
- **WSConnection**: RPC timing captured on all JSON-RPC method calls  
- **No Code Changes**: Existing RPC and event flows automatically benchmarked

### Memory Management
- **24-Hour Retention**: Detailed metrics kept for last 24 hours in ETS
- **Hourly Cleanup**: Automatic removal of old entries with snapshot creation
- **Bounded Memory**: Configurable limits prevent memory growth

### Historical Storage
- **JSON Snapshots**: Hourly performance summaries saved to files
- **7-Day Retention**: Old snapshots automatically cleaned up
- **Future Database**: Schema documented for PostgreSQL migration

## Future Enhancements

### Provider Selection Integration
```elixir
# Planned: Benchmark-aware provider selection
case load_balancing_strategy do
  "benchmark_optimized" ->
    providers
    |> Enum.map(&add_benchmark_score(&1, chain_name))
    |> Enum.sort_by(&(&1.benchmark_score), :desc)
    |> List.first()
end
```

### Advanced Analytics
- **Cost/Performance Analysis**: Track provider cost efficiency
- **Geographic Performance**: Regional latency analysis
- **Predictive Failover**: Use performance trends for early failover
- **SLA Monitoring**: Alert on provider performance degradation

### Database Migration
When adding Ecto to the project:
- Migrate JSON snapshots to PostgreSQL
- Add real-time analytics queries
- Enable complex performance reporting
- Support multi-user dashboard views

## Value Proposition

### For Development Teams
- **Data-Driven Decisions**: Choose providers based on actual performance vs marketing claims
- **Cost Optimization**: Identify when expensive providers don't deliver value
- **Performance Monitoring**: Track provider SLA compliance automatically  
- **Debugging Aid**: Correlate application issues with provider performance

### For Operations
- **Proactive Monitoring**: Detect provider degradation before complete failure
- **Capacity Planning**: Understand traffic patterns and provider limits
- **Incident Response**: Historical data for post-mortem analysis
- **Provider Negotiations**: Performance data for contract discussions

### For Business
- **Service Reliability**: Better provider selection improves application uptime
- **Cost Control**: Optimize provider mix for performance per dollar
- **Competitive Advantage**: Sub-second event delivery through optimal routing
- **Risk Mitigation**: Multi-provider performance data reduces single points of failure

## Technical Benefits

### Passive Collection
- **Zero Test Traffic**: All metrics from real usage patterns
- **No Performance Impact**: Lightweight metric collection
- **Accurate Data**: Real-world performance vs synthetic benchmarks
- **Comprehensive Coverage**: Every RPC call and event automatically tracked

### Real-Time Insights
- **Live Dashboards**: Performance data updated in real-time
- **Immediate Feedback**: Provider issues detected within seconds
- **Interactive Analysis**: Filter and explore performance data
- **Visual Trends**: Charts and graphs for pattern recognition

### Production Ready
- **Memory Bounded**: ETS tables with automatic cleanup prevent memory leaks
- **Fault Tolerant**: GenServer supervision prevents benchmark failures from affecting core functionality
- **Scalable Architecture**: Per-chain isolation supports multiple blockchain networks
- **Persistent Storage**: Automatic snapshots preserve historical data

This benchmarking system provides ChainPulse with unique competitive advantages by transforming provider selection from guesswork into data-driven optimization.