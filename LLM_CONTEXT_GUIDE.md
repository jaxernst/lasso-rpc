# ChainPulse: LLM Context Guide

## Complete Project Context for AI Development Assistance

---

## 🎯 **PROJECT VISION & HACKATHON GOALS**

### **Core Value Proposition**

ChainPulse is a **blockchain RPC orchestration platform** that provides intelligent multi-provider management, real-time event streaming, automatic failover, and performance optimization for crypto development teams.

### **Key Capabilities**

1. **Real-time Event Streaming**: Sub-second blockchain event delivery with curated feeds
2. **Intelligent RPC Orchestration**: Multi-provider racing, load balancing, and automatic failover
3. **Standard JSON-RPC Compatibility**: Drop-in replacement for Infura/Alchemy with enhanced capabilities
4. **Passive Performance Intelligence**: Real-world provider benchmarking without synthetic load
5. **Multi-Chain Support**: Unified API across 15+ blockchain networks
6. **Fault-Tolerant Architecture**: Elixir/OTP supervision with circuit breakers

### **Competitive Advantages**

- **vs The Graph**: Real-time (sub-second) vs minutes of indexing delay, free internal hosting vs $100+/month
- **vs Alchemy/Infura**: Multi-provider failover vs single-point-of-failure, built-in analytics vs external tools needed
- **vs Custom Solutions**: 10x faster time-to-market, self-healing OTP architecture, Phoenix handles 10,000+ connections

### **Hackathon Demo Focus**

1. **RPC Orchestration Excellence**: Show provider racing, failover, and load balancing
2. **Real-time Event Intelligence**: Curated blockchain event feeds with sub-second latency
3. **Developer Experience**: Viem/ethers.js compatibility as drop-in Infura replacement
4. **Performance Insights**: Business intelligence for infrastructure optimization
5. **Elixir/BEAM Showcase**: Fault tolerance, scalability, and observability at scale

---

## 🏗️ **SYSTEM ARCHITECTURE**

### **Core Components**

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   Real Providers │    │   ChainPulse     │    │   Frontend      │
│   (Infura/Alchemy) │──→│   Orchestration  │──→│   Apps          │
│                 │    │   Platform       │    │   (ethers.js)   │
└─────────────────┘    └──────────────────┘    └─────────────────┘
                              │
                              ▼
                       ┌──────────────────┐
                       │   LiveView       │
                       │   Orchestration  │
                       │   Dashboard      │
                       └──────────────────┘
```

### **Platform Capabilities**

1. **RPC Orchestration**: Multi-provider racing, intelligent routing, automatic failover
2. **Event Streaming**: Real-time blockchain event feeds with sub-second latency
3. **JSON-RPC Compatibility**: Standard API endpoints for seamless integration
4. **Performance Intelligence**: Passive benchmarking and optimization insights
5. **Multi-Chain Support**: Unified interface across 15+ blockchain networks
6. **Fault Tolerance**: Circuit breakers, supervision trees, graceful degradation

### **Key Algorithms**

1. **Provider Racing**: Multiple providers compete for fastest event delivery
2. **Message Aggregation**: Event deduplication with first-wins timing measurement
3. **Circuit Breaker**: Automatic failover on provider failures with recovery logic
4. **Load Balancing**: Intelligent request routing based on real-time performance
5. **Event Curation**: Raw log transformation into structured, actionable events
6. **Performance Scoring**: Multi-factor provider ranking with confidence intervals

### **Technology Stack**

- **Backend**: Elixir/OTP with Phoenix Framework for fault-tolerant orchestration
- **Frontend**: Phoenix LiveView for real-time dashboards and monitoring
- **Storage**: ETS tables for high-performance metrics, JSON snapshots for persistence
- **Communication**: WebSockets for RPC/events, PubSub for internal messaging
- **API Layer**: Hybrid JSON-RPC + enhanced streaming endpoints

---

## 📁 **CODEBASE STRUCTURE**

### **Critical Files**

```
lib/
├── livechain/                      # Core business logic
│   ├── benchmarking/
│   │   ├── benchmark_store.ex      # ✅ Racing metrics & provider scoring
│   │   └── persistence.ex          # ✅ JSON snapshots & historical data
│   ├── rpc/
│   │   ├── chain_supervisor.ex     # 🚨 BROKEN: Missing subscription_topics
│   │   ├── message_aggregator.ex   # ✅ Racing algorithm implementation
│   │   ├── circuit_breaker.ex      # ✅ Automatic failover logic
│   │   ├── ws_connection.ex        # 🟡 Core provider connection (needs testing)
│   │   └── real_endpoints.ex       # 🟡 Provider configurations (incomplete)
│   └── telemetry.ex                # 🟡 Metrics collection (basic)
├── livechain_web/                  # Web interface
│   ├── live/
│   │   ├── dashboard.ex            # 🚨 EMPTY: Main demo dashboard
│   │   ├── orchestration_live.ex   # 🟡 Has benchmarks tab, needs more
│   │   ├── network_live.ex         # 🟡 Network topology view
│   │   └── table_live.ex           # 🟡 Data table view
│   ├── channels/
│   │   ├── rpc_channel.ex          # ✅ JSON-RPC WebSocket handler
│   │   └── blockchain_channel.ex   # ✅ Event subscription handler
│   └── controllers/                # ✅ HTTP API endpoints
└── config/
    └── chains.yml                  # 🚨 BROKEN: Missing subscription_topics
```

### **Status Legend**

- ✅ **Working**: Implemented and tested
- 🟡 **Partial**: Exists but incomplete/untested
- 🚨 **Broken**: Critical issues preventing functionality

---

## 💥 **CRITICAL BLOCKING ISSUES**

### **1. Configuration System Crash**

**File**: `config/chains.yml`
**Problem**: Missing `subscription_topics` field in ALL chain configurations
**Error**: `(KeyError) key :subscription_topics not found`
**Impact**: Provider connections fail to start

**Fix Required**:

```yaml
# Add to every chain in chains.yml
connection:
  heartbeat_interval: 30000
  reconnect_interval: 5000
  max_reconnect_attempts: 10
  subscription_topics: ["newHeads", "logs", "newPendingTransactions"] # ← ADD THIS
```

### **2. Empty Dashboard**

**File**: `lib/livechain_web/live/dashboard.ex`
**Problem**: Main demo dashboard has literally empty content
**Current State**:

```elixir
def live_feed_tab_content(assigns) do
  ~H"""
  <div class="flex h-full w-full flex-col">
    <div class="flex flex-col"></div>  # ← EMPTY DIV
  </div>
  """
end
```

**Demo Requirements**: This is the PRIMARY DEMO INTERFACE - must showcase all capabilities

### **3. Real Provider Integration**

**Problem**: System defaults to mock providers, real provider connections incomplete
**Issues**:

- Environment variable substitution not working
- API key handling incomplete
- No clear mock/real toggle

---

## 🎯 **DEMO REQUIREMENTS**

### **Observability Dashboard Specifications**

#### **Provider Racing Visualization**

- **Win Rate Matrix**: Real-time heatmap showing which providers win races
- **Racing Timeline**: Live stream of racing events with timing margins
- **Performance Leaderboard**: Provider rankings with scores and confidence intervals
- **Latency Histograms**: Distribution charts for each provider's response times

#### **BEAM/Elixir System Metrics**

- **Process Tree Visualization**: Live OTP supervision tree with process counts
- **Memory Dashboard**: ETS table sizes, heap usage, total BEAM memory
- **Message Queue Monitor**: Mailbox sizes for critical GenServer processes
- **Scheduler Utilization**: Multi-core BEAM scheduler usage graphs
- **Garbage Collection Metrics**: GC frequency, pause times, memory reclamation

#### **Client Connection Analytics**

- **WebSocket Connection Map**: Real-time client connection visualization
- **Subscription Patterns**: Charts showing which blockchain events clients request
- **End-to-End Latency**: Provider → ChainPulse → Client timing measurement
- **Failover Event Log**: Timeline of automatic provider switching events

#### **Business Intelligence**

- **Cost Optimization**: Provider performance vs cost analysis
- **Reliability Scoring**: Composite reliability metrics with statistical confidence
- **SLA Compliance**: Uptime and performance target tracking
- **Traffic Load Balancing**: Request distribution efficiency metrics

### **Interactive Demo Features**

1. **Live Provider Racing**: Real Infura vs Alchemy competition on Ethereum mainnet
2. **Manual Failover**: Click to disable providers and watch automatic recovery
3. **Load Testing**: Simulate high traffic and show system scaling
4. **Cost Calculator**: Input provider pricing and see optimization recommendations

---

## 🔧 **TECHNICAL REQUIREMENTS**

### **Files Requiring Implementation**

#### **A. New Files to Create**

```elixir
# System metrics collection
lib/livechain/telemetry/system_metrics.ex
lib/livechain/telemetry/client_metrics.ex
lib/livechain/analytics/cost_optimizer.ex

# Dashboard components
lib/livechain_web/live/components/charts.ex
lib/livechain_web/live/components/metrics_display.ex

# Test files
test/livechain_web/live/dashboard_test.exs
test/livechain/telemetry/system_metrics_test.exs
```

#### **B. Critical Functions to Implement**

```elixir
# Dashboard content (replace empty divs)
def live_feed_tab_content(assigns)      # Real-time event stream
def network_tab_content(assigns)        # Provider status visualization
def simulator_tab_content(assigns)      # Racing simulation controls

# Real-time data handlers
def handle_info({:benchmark_update, data}, socket)
def handle_info({:system_metrics, metrics}, socket)
def handle_info({:provider_failover, event}, socket)

# System metrics collection
def collect_process_metrics()           # OTP process counts
def collect_memory_metrics()            # BEAM memory usage
def collect_scheduler_metrics()         # Scheduler utilization
def measure_end_to_end_latency()        # Client timing

# Business intelligence
def calculate_provider_cost_efficiency()
def generate_optimization_recommendations()
def compute_sla_compliance_scores()
```

### **Environment Configuration**

```bash
# Required environment variables for real provider demo
INFURA_API_KEY=your_infura_key
ALCHEMY_API_KEY=your_alchemy_key
DEMO_MODE=real  # or 'mock' for development
```

---

## 📊 **TEST COVERAGE REQUIREMENTS**

### **Priority Areas (0% → Target%)**

- `LivechainWeb.Dashboard`: 0% → 80%+ (main demo interface)
- `LivechainWeb.OrchestrationLive`: 0% → 70%+ (orchestration dashboard)
- `Livechain.RPC.WSConnection`: 0% → 85%+ (provider connections)
- `Livechain.Telemetry.*`: 0% → 75%+ (observability)
- `Livechain.Analytics.*`: 0% → 70%+ (business intelligence)

### **Test Scenarios Required**

1. **Dashboard Functionality**: All tabs render with real data
2. **Provider Racing**: Multiple providers compete, timing accuracy
3. **Failover Testing**: Automatic recovery on provider failures
4. **Load Testing**: System performance under high traffic
5. **Real Provider Integration**: Infura/Alchemy connections work
6. **Metrics Collection**: All observability data accurate

---

## 🚀 **SUCCESS CRITERIA**

### **Demo Must Demonstrate**

1. **Live Provider Racing**: Real-time competition between Infura/Alchemy
2. **Automatic Failover**: Kill provider, watch seamless recovery
3. **BEAM Observability**: Showcase Elixir/OTP system internals
4. **Business Value**: Cost optimization and performance insights
5. **Technical Credibility**: Production-ready architecture and error handling

### **Technical Validation**

- Provider connections start without errors
- Dashboard displays real data (no hardcoded values)
- Racing algorithm produces accurate timing measurements
- System handles provider failures gracefully
- Observability metrics reflect actual system state

---

## 💡 **IMPLEMENTATION PRIORITIES**

### **Phase 1: Fix Blocking Issues**

1. Add `subscription_topics` to chains.yml (prevents system startup)
2. Implement basic dashboard content (currently empty)
3. Enable real provider connections (environment variables)
4. Fix PubSub data flow (many subscriptions commented out)

### **Phase 2: Core Demo Features**

1. Provider racing visualization (show live competition)
2. BEAM system metrics display (process counts, memory, schedulers)
3. Interactive failover demonstration (manual provider control)
4. Real-time performance analytics (charts and metrics)

### **Phase 3: Polish & Advanced Features**

1. Cost optimization intelligence (business recommendations)
2. Load testing capabilities (demonstrate scalability)
3. Comprehensive test coverage (validate all functionality)
4. Visual polish and demo narrative (compelling presentation)

---

## 🔍 **KEY ALGORITHMS TO UNDERSTAND**

### **Message Racing Algorithm**

```elixir
# Location: lib/livechain/rpc/message_aggregator.ex
# Concept: First provider to deliver event "wins", others tracked as "losses" with timing margin
# Business Value: Passive performance measurement without synthetic load
```

### **Provider Scoring Formula**

```elixir
# Location: lib/livechain/benchmarking/benchmark_store.ex:656-663
# Formula: win_rate * margin_penalty * confidence_factor
# Confidence: Logarithmic scaling based on sample size
# Margin penalty: Penalizes slow wins (timing matters)
```

### **Circuit Breaker State Machine**

```elixir
# Location: lib/livechain/rpc/circuit_breaker.ex
# States: :closed, :open, :half_open
# Triggers: Failure thresholds, timeout recovery, success confirmation
```

---

## 📋 **COMMON PITFALLS TO AVOID**

1. **Don't assume existing dashboard works** - Most tabs are empty placeholders
2. **Fix configuration before anything else** - subscription_topics KeyError blocks everything
3. **Test with real providers early** - Mock providers hide integration issues
4. **Focus on observability** - BEAM metrics are key demo differentiator
5. **Validate racing accuracy** - Timing precision is core value proposition
6. **Handle provider failures gracefully** - Fault tolerance is selling point

---

**Bottom Line**: ChainPulse has solid technical foundations but needs significant implementation work to become demo-ready. The vision is compelling and technically sound - focus on fixing blocking issues first, then building the observability features that showcase Elixir/BEAM capabilities.
