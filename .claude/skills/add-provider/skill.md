---
name: add-provider
description: Guide through complete workflow for adding a new RPC provider to Lasso
---

# Add New RPC Provider

Complete end-to-end workflow for integrating a new RPC provider into Lasso.

## Overview

1. Quick connectivity smoke tests
2. Full capability discovery (automated probing)
3. Analyze probe results to determine adapter needs
4. Create provider adapter (if needed)
5. Update configuration
6. Validation and testing

## Step 1: Quick Connectivity Smoke Tests

```bash
# HTTP connectivity
curl -s -X POST <HTTP_URL> \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}'

# WebSocket connectivity
mix lasso.probe <WS_URL> --probes websocket --subscription-wait 5000
```

For multi-chain providers, test URL patterns: `/public/{chain}`, `/{chain}`, `/{chain_id}`.

## Step 2: Full Capability Discovery

```bash
# Standard probe (methods + limits + websocket)
mix lasso.probe <HTTP_URL> --level standard

# HTTP-only
mix lasso.probe <HTTP_URL> --probes methods,limits

# WebSocket-only
mix lasso.probe <WS_URL> --probes websocket

# Full method coverage with JSON output
mix lasso.probe <HTTP_URL> --level full --output json
```

**Probe options:**
- `--probes <list>` — Comma-separated: methods, limits, websocket (default: all)
- `--level <level>` — Method depth: critical (~10), standard (~25), full (~70)
- `--timeout <ms>` — Request timeout (default: 10000)
- `--output <format>` — table or json

**Key capabilities detected:**

| Capability | Adapter Impact |
|------------|---------------|
| Block Range | `max_block_range` config |
| Address Count | `max_addresses` config |
| Batch Requests | May need to disable batching |
| Archive Support | Archive node flag |
| Rate Limits | Circuit breaker tuning |
| Subscriptions | WebSocket capability flags |

## Step 3: Analyze Probe Results

**Needs custom adapter if:**
- Block range limit < 10000
- Address count limit < 50
- Custom error codes (non-standard -32xxx)
- Batch requests not supported

**Can use generic adapter if:**
- No block range limits
- Standard JSON-RPC 2.0 errors
- Batch supported
- All standard methods work

**Existing adapters in `lib/lasso/core/providers/adapters/`:**
Alchemy, PublicNode, LlamaRPC, Merkle, Cloudflare, DRPC, 1RPC

## Step 4: Create Provider Adapter (if needed)

```elixir
# lib/lasso/core/providers/adapters/[provider_name].ex
defmodule Lasso.RPC.Providers.Adapters.[ProviderName] do
  @behaviour Lasso.RPC.ProviderAdapter
  import Lasso.RPC.Providers.AdapterHelpers

  @default_block_range 1000  # Set based on probe results

  @impl true
  def supports_method?(method, _transport, _ctx) do
    method not in []
  end

  @impl true
  def validate_params("eth_getLogs", params, _transport, ctx) do
    limit = get_adapter_config(ctx, :max_block_range, @default_block_range)
    case validate_block_range(params, ctx, limit) do
      :ok -> :ok
      {:error, reason} = err ->
        :telemetry.execute([:lasso, :capabilities, :param_reject], %{count: 1}, %{
          adapter: __MODULE__, method: "eth_getLogs", reason: reason
        })
        err
    end
  end
  def validate_params(_method, _params, _transport, _ctx), do: :ok

  @impl true
  def classify_error(_code, _message), do: :default

  @impl true
  def normalize_request(request, _ctx), do: {:ok, request}

  @impl true
  def normalize_response(response, _ctx), do: {:ok, response}

  @impl true
  def normalize_error(error, _ctx), do: {:ok, error}

  @impl true
  def headers(_ctx), do: []

  @impl true
  def metadata do
    %{
      provider_type: "[provider_name]",
      version: "1.0.0",
      configurable_limits: [
        max_block_range: "Maximum block range for eth_getLogs (default: #{@default_block_range})"
      ]
    }
  end
end
```

Register in `adapter_registry.ex`:
```elixir
@provider_type_mapping %{
  # ... existing
  "[provider_name]" => Lasso.RPC.Providers.Adapters.[ProviderName]
}
```

## Step 5: Update Configuration

Add provider to `config/chains.yml`:

```yaml
ethereum:
  chain_id: 1
  providers:
    - id: "[provider_name]_ethereum"
      name: "[Provider Display Name]"
      url: "https://[provider-endpoint]"
      ws_url: "wss://[provider-ws-endpoint]"  # Optional
      type: "public"
      priority: 5
      adapter_config:
        max_block_range: 1000
```

For multi-chain, add to each chain section.

## Step 6: Validation

```bash
# Compile
mix compile --warnings-as-errors

# Adapter tests (if custom adapter)
mix test test/lasso/core/providers/adapters/[provider_name]_test.exs

# Smoke test
mix phx.server
curl -X POST http://localhost:4000/rpc/provider/[provider_name]_ethereum/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

Verify in dashboard: http://localhost:4000/metrics/ethereum — provider appears, circuit breaker closed.

## Output Format

```
ADDING RPC PROVIDER: [Name]
====================================

STEP 1: Connectivity Tests
  [chain] HTTP: [url] - chainId: [id] [PASS/FAIL]
  [chain] WS: [url] [PASS/FAIL]

STEP 2: Capability Discovery
  Block Range: [unlimited | N]
  Batch Requests: [supported | NOT SUPPORTED]
  Archive Node: [full | partial | none]
  Subscriptions: [list]

STEP 3: Adapter Decision
  Decision: [Custom adapter needed | Generic adapter sufficient]
  Reasons: [list]

STEP 4-6: Implementation & Validation
  [status for each step]

COMPLETE
```
