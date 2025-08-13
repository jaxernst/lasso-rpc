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

Edit `config/chains.yml` to set your providers (Infura, Alchemy, etc.). Ensure API keys are present in the URLs or environment variables.

## HTTP vs WebSocket

- Use WebSocket for `eth_subscribe`/`eth_unsubscribe`.
- Both WebSocket and HTTP support read-only JSON-RPC methods via the orchestration layer.

## Provider Selection Strategy

Default strategy is `:leaderboard`. Switch strategies via config or at runtime.

```elixir
# config/config.exs
config :livechain, :provider_selection_strategy, :leaderboard
# Alternatives: :priority | :round_robin
```

At runtime (for demos):

```elixir
# In IEx (attached to the running node)
Application.put_env(:livechain, :provider_selection_strategy, :priority)
Application.put_env(:livechain, :provider_selection_strategy, :round_robin)
Application.put_env(:livechain, :provider_selection_strategy, :leaderboard)
```

## TODO / Next Steps

- Add rate-limit aware selection and backoff (track 429s per provider/method; temporary deprioritization)
- Implement real WS RPC request/response correlation (currently mocked in forwarding path)
- Add cost metadata per provider to support `:cheapest` strategy
- Enhance failover heuristics (jitter, exponential backoff, rolling window health)
- Extend method coverage and add write-ops with proper auth/guardrails

## Examples

```bash
curl -X POST http://localhost:4000/rpc/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```
