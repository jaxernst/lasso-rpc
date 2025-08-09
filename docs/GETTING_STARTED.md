# Getting Started with ChainPulse

## Quick Setup

### **Prerequisites**

- Elixir 1.18+
- API keys for RPC providers (Infura, Alchemy, etc.)

### **Installation**

```bash
# Clone and setup
git clone <repository-url>
cd livechain
mix deps.get
mix compile

# Start the application
mix phx.server
```

### **View Dashboard**

Open http://localhost:4000/orchestration to see the real-time monitoring interface.

---

## Configuration

### **Provider API Keys**

Add your RPC provider credentials to environment or config:

```elixir
# config/dev.exs or config/prod.exs
config :livechain,
  infura_api_key: System.get_env("INFURA_API_KEY"),
  alchemy_api_key: System.get_env("ALCHEMY_API_KEY")
```

### **Environment Variables**

```bash
export INFURA_API_KEY="your_infura_project_id"
export ALCHEMY_API_KEY="your_alchemy_api_key"
```

---

## Testing the System

### **Health Check**

```bash
curl http://localhost:4000/api/health
```

### **Provider Status**

```bash
curl http://localhost:4000/api/status
```

### **JSON-RPC Endpoints**

```bash
# Test Ethereum endpoint
curl -X POST http://localhost:4000/rpc/ethereum \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

---

## Dashboard Features

### **Orchestration Tab**

- Real-time connection status
- Provider health monitoring
- Connection statistics

### **Benchmarks Tab** (Demo Focus)

- Live provider racing leaderboard
- Performance metrics by provider
- Chain selection and comparison

### **Network Tab**

- Network topology visualization
- Provider pool management
- Connection details

---

## Development Mode

The system runs with mock providers by default for development. To enable real provider connections:

1. Add API keys to configuration
2. Update provider endpoints in chain configuration
3. Restart the application

### **Mock vs Real Providers**

- **Mock mode**: Uses simulated blockchain data for development
- **Real mode**: Connects to actual Infura, Alchemy, and other RPC providers
- **Demo mode**: Real providers with racing visualization

---

## Troubleshooting

### **Common Issues**

#### **Connection Errors**

```
KeyError: key :subscription_topics not found
```

**Fix**: Ensure chain configuration includes subscription_topics for each provider.

#### **Missing Function Errors**

```
UndefinedFunctionError: function get_chain_name/1 is undefined
```

**Fix**: This is a known issue being addressed in the current development cycle.

#### **Dashboard Shows No Data**

- Verify providers are connected and receiving events
- Check that BenchmarkStore is running and collecting metrics
- Ensure dashboard is loading real data (not hardcoded placeholders)

### **Log Analysis**

```bash
# Watch application logs
tail -f _build/dev/lib/livechain/ebin/application.log

# Check provider connection status
iex -S mix
iex> Livechain.RPC.WSSupervisor.list_connections()
```

---

## Next Steps

1. **Configure real providers** - Add API keys and test connections
2. **Monitor racing metrics** - Watch the benchmarks tab for provider performance
3. **Test failover scenarios** - Simulate provider failures to see circuit breakers
4. **Explore the API** - Test JSON-RPC endpoints with your frontend applications

For technical details, see [Architecture](ARCHITECTURE.md).
For demo features, see [Demo Technical Spec](DEMO_TECHNICAL_SPEC.md).
