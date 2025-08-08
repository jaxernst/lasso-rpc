# ChainPulse Dashboard Redesign Specification

## Overview

This specification defines the redesign of the ChainPulse dashboard to focus on practical, real-world use cases while demonstrating the platform's capabilities. The new dashboard emphasizes functionality over purely visual appeal, creating a tool that serves both as a monitoring interface and a demonstration platform.

## Tab Structure & Features

### 1. Live System Tab

**Purpose**: Real-time system monitoring and network topology visualization.

#### Core Features:

**System Metrics Dashboard**
- Real-time system health indicators (CPU, memory, connection counts)
- Active WebSocket connection counter
- Request throughput metrics (requests/second, avg latency)
- Error rate tracking and alerts
- System uptime and availability metrics

**Connected Nodes Display**
- Live list of all active blockchain connections
- Connection status (connected, connecting, failed, reconnecting)
- Last seen timestamp for each connection
- Connection quality metrics (latency, success rate)

**Event Feed**
- Real-time stream of system events:
  - New connections established
  - Connection disconnections
  - RPC method calls (with frequency stats)
  - Provider failovers
  - Error events and recoveries
- Filterable by event type, chain, or provider
- Exportable event logs

**Network Topology View**
- Visual representation of all blockchain RPC providers
- Shows both active connections AND configured providers
- Interactive provider cards with detailed information:
  - Provider name and endpoint
  - Connection status and health metrics
  - Recent performance statistics
  - Configuration details (rate limits, timeouts)
- Toggle button to filter view:
  - "All Configured" - shows all providers in config
  - "Active Connections Only" - shows only live WebSocket connections
- Click on individual providers to drill down into detailed stats

#### Technical Requirements:

```elixir
# Real-time data subscriptions needed:
Phoenix.PubSub.subscribe(ChainPulse.PubSub, "system:metrics")
Phoenix.PubSub.subscribe(ChainPulse.PubSub, "connections:all")
Phoenix.PubSub.subscribe(ChainPulse.PubSub, "events:system")
Phoenix.PubSub.subscribe(ChainPulse.PubSub, "providers:status")
```

### 2. Live Test Tab

**Purpose**: Interactive system testing and demonstration platform.

#### Core Features:

**Test Configuration Panel**
- Provider selection (choose specific RPC providers to test)
- Chain selection (Ethereum, Polygon, Arbitrum, etc.)
- Load configuration:
  - Number of simulated WebSocket connections (1-100)
  - Request rate per connection (1-10 req/sec)
  - Test duration (30s, 1m, 5m, continuous)
  - RPC method distribution (eth_getBlockByNumber, eth_getLogs, etc.)

**Test Execution Controls**
- Start/Stop/Pause test execution
- Real-time test progress indicator
- Emergency stop button for all tests

**Live Test Metrics**
- Concurrent connection counter
- Total requests sent vs responses received
- Average response time per method type
- Success rate percentage
- Error breakdown by type
- Provider performance comparison during test

**Test Results Dashboard**
- Real-time charts showing:
  - Response time distribution
  - Throughput over time
  - Error rates by provider
  - Connection stability metrics
- Pass/fail indicators for each test criteria
- Detailed logs of failed requests

#### Test Scenarios:

**Basic Connectivity Test**
- Establish connections to all configured providers
- Send basic eth_blockNumber requests
- Measure response times and success rates

**Failover Simulation**
- Deliberately disconnect from primary provider
- Verify automatic failover to backup providers
- Measure failover time and success

**Load Testing**
- Ramp up concurrent connections gradually
- Monitor system performance under load
- Identify breaking points and bottlenecks

**Method Coverage Test**
- Test all supported JSON-RPC methods
- Verify response format compliance
- Check error handling for invalid requests

#### Technical Implementation:

```elixir
defmodule ChainPulseWeb.LiveTestRunner do
  # Test orchestration and execution
  def start_test(config) do
    # Spawn test workers based on config
    # Monitor and collect metrics
    # Broadcast results in real-time
  end

  def simulate_connections(count, chain) do
    # Create mock WebSocket connections
    # Generate realistic request patterns
    # Track performance metrics
  end
end
```

### 3. Stream Builder Tab (Stretch Goal)

**Purpose**: Interactive tool for building custom blockchain event streams.

⚠️ **Note**: This is explicitly marked as a stretch goal that requires further product validation and scoping before implementation.

#### Conceptual Features:

**Stream Configuration Interface**
- Chain selection (multi-chain support)
- Event type selection:
  - Token transfers (ERC-20, ERC-721, ERC-1155)
  - Smart contract events
  - Block confirmations
  - Custom log filters
- Address filtering (specific contracts, wallets, or address lists)
- Event parameter filtering (amount ranges, token IDs, etc.)

**Stream Preview**
- Real-time preview of event stream output
- Sample events showing expected data structure
- Volume estimation (events per minute/hour)
- Performance impact assessment

**Stream Generation**
- Generate unique WebSocket URL for the configured stream
- Encode stream parameters in URL for easy sharing
- Provide connection examples for different clients (JavaScript, Python, etc.)
- Test stream connectivity directly in the UI

**Example Use Cases**
- Monitor USDC transfers above $10,000
- Track NFT mints for specific collections
- Watch for specific DeFi protocol interactions
- Create multi-chain event aggregation streams

#### Product Questions to Address:

1. **Market Validation**: Do developers actually need this capability?
2. **Technical Feasibility**: Can we efficiently support arbitrary event filtering?
3. **Resource Management**: How do we prevent resource-intensive streams?
4. **Monetization**: Is this a feature users would pay for?
5. **Maintenance**: What's the ongoing support burden for custom streams?

## Additional Tab Suggestions

### 4. Analytics & Insights Tab
- Historical performance trends
- Provider reliability rankings
- Cost analysis and optimization recommendations
- Usage patterns and peak traffic analysis
- Predictive health monitoring

### 5. Configuration Management Tab
- Live provider configuration editing
- Chain configuration management
- Rate limiting and timeout adjustments
- Feature flags and experimental toggles
- System configuration backup/restore

### 6. API Documentation & Testing Tab
- Interactive API documentation
- Built-in API testing interface (Postman-like)
- Example code generation
- Rate limiting and authentication testing
- WebSocket connection testing tools

## Technical Architecture

### LiveView Structure

```elixir
# Main dashboard router
live "/dashboard", DashboardLive
live "/dashboard/system", DashboardLive, :system
live "/dashboard/testing", DashboardLive, :testing
live "/dashboard/streams", DashboardLive, :streams

# Component hierarchy
DashboardLive
├── SystemTabComponent
│   ├── MetricsComponent
│   ├── ConnectionsComponent
│   ├── EventFeedComponent
│   └── NetworkTopologyComponent
├── TestingTabComponent
│   ├── TestConfigComponent
│   ├── TestControlsComponent
│   ├── TestMetricsComponent
│   └── TestResultsComponent
└── StreamBuilderComponent (stretch goal)
    ├── StreamConfigComponent
    ├── StreamPreviewComponent
    └── StreamGeneratorComponent
```

### Data Flow Integration

```elixir
# Required PubSub subscriptions per tab
defmodule ChainPulseWeb.DashboardLive do
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Core system subscriptions
      Phoenix.PubSub.subscribe(ChainPulse.PubSub, "system:health")
      Phoenix.PubSub.subscribe(ChainPulse.PubSub, "connections:status")
      Phoenix.PubSub.subscribe(ChainPulse.PubSub, "providers:metrics")
      Phoenix.PubSub.subscribe(ChainPulse.PubSub, "events:feed")
      
      # Testing subscriptions
      Phoenix.PubSub.subscribe(ChainPulse.PubSub, "testing:results")
      Phoenix.PubSub.subscribe(ChainPulse.PubSub, "testing:progress")
    end
    
    {:ok, initialize_dashboard(socket)}
  end
end
```

### Backend Services Required

**System Monitoring Service**
- Collect real-time system metrics
- Track connection status and health
- Aggregate provider performance data
- Generate system events feed

**Testing Service**
- Orchestrate test execution
- Simulate realistic load patterns
- Collect and analyze test results
- Provide real-time test metrics

**Provider Management Service**
- Maintain provider configuration
- Monitor provider health and performance
- Handle failover logic
- Track usage statistics

## Implementation Priority

### Phase 1: Live System Tab (Weeks 1-2)
- Basic system metrics display
- Connection status monitoring  
- Simple event feed
- Static network topology view

### Phase 2: Enhanced Live System (Weeks 3-4)
- Interactive network topology
- Detailed provider information
- Advanced event filtering
- Real-time performance charts

### Phase 3: Live Test Tab (Weeks 5-7)
- Test configuration interface
- Basic load testing capability
- Real-time test metrics
- Test result analysis

### Phase 4: Advanced Testing (Weeks 8-9)
- Multiple test scenarios
- Automated test suites
- Performance benchmarking
- Detailed reporting

### Phase 5: Stream Builder (Future - Stretch Goal)
- Market validation and scoping required
- Technical feasibility assessment
- Resource allocation planning
- Product-market fit validation

## Success Metrics

### Live System Tab
- **Utility**: System administrators can monitor health effectively
- **Adoption**: Used daily by development team for system insights
- **Performance**: Page loads in <2 seconds, updates in real-time
- **Accuracy**: Metrics match actual system state 99%+ of the time

### Live Test Tab
- **Functionality**: Can successfully test all major RPC providers
- **Reliability**: Tests run consistently without framework failures
- **Insights**: Reveals actual performance differences between providers
- **Usability**: Non-technical stakeholders can run basic tests

### Overall Dashboard
- **Engagement**: Average session duration >3 minutes
- **Adoption**: 80% of team uses dashboard weekly
- **Demonstration**: Effectively showcases platform capabilities in demos
- **Performance**: Handles 50+ concurrent users without degradation

## Future Expansion Opportunities

1. **Multi-tenant Support**: Custom dashboards for different teams/clients
2. **Alerting System**: Configurable alerts for system events
3. **Historical Analytics**: Long-term trend analysis and reporting
4. **Mobile App**: Native mobile dashboard for on-the-go monitoring
5. **API Integration**: Third-party integrations with monitoring tools
6. **Machine Learning**: Predictive analytics and anomaly detection

This specification provides a clear roadmap for building a practical, demonstration-ready dashboard that serves real operational needs while showcasing ChainPulse's capabilities to potential users and stakeholders.