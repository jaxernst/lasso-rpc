# Getting Started

## Prerequisites

- Elixir/OTP 26+
- Node.js (for assets in dev)

## Setup

```bash
mix deps.get
mix ecto.setup # if applicable
mix phx.server
```

## Configure Providers

Edit `config/chains.yml` to set your providers. You can define multiple providers per chain with different priorities.

Example for Ethereum:

```yaml
chains:
  ethereum:
    chain_id: 1
    name: "Ethereum Mainnet"
    block_time: 12000
    providers:
      - id: "ethereum_ankr"
        name: "Ankr Public"
        priority: 1
        type: "public"
        url: "https://rpc.ankr.com/eth"
        ws_url: "wss://rpc.ankr.com/eth/ws"
        api_key_required: false
    connection:
      heartbeat_interval: 30000
      reconnect_interval: 5000
      max_reconnect_attempts: 10
    aggregation:
      deduplication_window: 2000
      min_confirmations: 1
      max_providers: 3
      max_cache_size: 10000
```

## Provider Selection Strategy

Default strategy is `:cheapest` (prefers free providers). You can change it in your `config/config.exs`:

```elixir
config :livechain, :provider_selection_strategy, :cheapest
# Alternatives: :fastest (performance-based), :priority (static), :round_robin (load balanced)
```

## TODO / Next Steps

- Add rate-limit aware selection and backoff (track 429s per provider/method; temporary deprioritization)
- Add cost metadata per provider to support `:cheapest` strategy
- Enhance failover heuristics (jitter, exponential backoff, rolling window health)
- Extend method coverage and add write-ops with proper auth/guardrails

## Examples

```bash
curl -X POST http://localhost:4000/rpc/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```
