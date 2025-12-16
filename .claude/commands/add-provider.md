---
description: Guide through complete workflow for adding a new RPC provider to Lasso
---

# Add New RPC Provider

Complete end-to-end workflow for integrating a new RPC provider into Lasso.

## Overview

Adding a provider involves:
1. Quick connectivity smoke tests
2. Full capability discovery (automated probing)
3. Analyzing probe results to determine adapter needs
4. Creating provider adapter (if needed)
5. Updating configuration
6. Validation and testing

## Step 1: Quick Connectivity Smoke Tests

Before deep probing, verify basic connectivity across chains.

**HTTP connectivity test:**
```bash
# Test basic RPC connectivity
curl -s -X POST <HTTP_URL> \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}'
```

**WebSocket connectivity test:**
```bash
# Quick WebSocket probe (connection + basic requests)
mix lasso.probe <WS_URL> --probes websocket --subscription-wait 5000
```

**Multi-chain discovery:**
If the provider supports multiple chains, test URL patterns:
- Common patterns: `/public/{chain}`, `/{chain}`, `/{chain_id}`
- WS patterns may differ: `wss://{chain}.provider.com` vs `wss://provider.com/public/{chain}`

Run quick tests across all target chains before proceeding.

## Step 2: Full Capability Discovery

Use `mix lasso.probe` for comprehensive capability detection.

**Full probe (all capabilities):**
```bash
mix lasso.probe <HTTP_URL> --level standard
```

**Probe options:**
- `--probes <list>` - Comma-separated: methods, limits, websocket (default: all)
- `--level <level>` - Method depth: critical (~10), standard (~25), full (~70 methods)
- `--timeout <ms>` - Request timeout (default: 10000)
- `--output <format>` - Output: table, json (default: table)
- `--subscription-wait <ms>` - WebSocket event wait time (default: 15000)

**Example probe commands:**
```bash
# Standard probe (methods + limits + websocket)
mix lasso.probe https://provider.com/rpc

# HTTP-only probe (methods and limits)
mix lasso.probe https://provider.com/rpc --probes methods,limits

# WebSocket-only probe
mix lasso.probe wss://provider.com/ws --probes websocket

# Full method coverage with JSON output
mix lasso.probe https://provider.com/rpc --level full --output json
```

**Key capabilities detected:**

| Capability | What It Tests | Adapter Impact |
|------------|---------------|----------------|
| Block Range | eth_getLogs range limits | `max_block_range` config |
| Address Count | Multi-address query limits | `max_addresses` config |
| Batch Requests | JSON-RPC batching support | May need to disable batching |
| Archive Support | Historical state queries | Archive node flag |
| Rate Limits | Concurrent request handling | Circuit breaker tuning |
| Block Params | safe/finalized/pending support | Method filtering |
| Subscriptions | newHeads, logs, pendingTx | WebSocket capability flags |

## Step 3: Analyze Probe Results

Review the probe output to determine adapter requirements.

**Needs custom adapter if probe shows:**
- Block range limit < 10000 blocks
- Address count limit < 50
- Custom error codes (non-standard -32xxx codes)
- Batch requests not supported
- Specific methods unsupported

**Can use generic adapter if:**
- No block range limits detected
- Standard JSON-RPC 2.0 error codes
- Batch requests supported
- All standard methods work

**Existing adapters in `lib/lasso/core/providers/adapters/`:**
- Alchemy (eth_getLogs block range: 10)
- PublicNode (address count limits)
- LlamaRPC (block range: 1000)
- Merkle (block range: 1000)
- Cloudflare (no restrictions)
- DRPC (custom error codes)
- 1RPC (custom rate limit errors)

## Step 4: Create Provider Adapter (if needed)

**If custom adapter needed, create from template:**

```elixir
# lib/lasso/core/providers/adapters/[provider_name].ex

defmodule Lasso.RPC.Providers.Adapters.[ProviderName] do
  @moduledoc """
  Provider adapter for [Provider Name].

  Discovered via `mix lasso.probe`:
  - Block range: [unlimited | limited to N]
  - Batch requests: [supported | not supported]
  - Archive: [full | partial | none]

  Configuration options:
  - `:max_block_range` - Maximum block range for eth_getLogs
  """

  @behaviour Lasso.RPC.ProviderAdapter

  import Lasso.RPC.Providers.AdapterHelpers

  # Limits discovered via probing
  @default_block_range 1000  # Set based on probe results

  @impl true
  def supports_method?(method, _transport, _ctx) do
    # Based on probe results - list unsupported methods
    method not in [
      # "debug_traceTransaction",  # If probe showed unsupported
    ]
  end

  @impl true
  def validate_params("eth_getLogs", params, _transport, ctx) do
    limit = get_adapter_config(ctx, :max_block_range, @default_block_range)

    case validate_block_range(params, ctx, limit) do
      :ok -> :ok
      {:error, reason} = err ->
        :telemetry.execute([:lasso, :capabilities, :param_reject], %{count: 1}, %{
          adapter: __MODULE__,
          method: "eth_getLogs",
          reason: reason
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

**Register adapter in `adapter_registry.ex`:**

```elixir
# Add to @provider_type_mapping
@provider_type_mapping %{
  # ... existing
  "[provider_name]" => Lasso.RPC.Providers.Adapters.[ProviderName]
}
```

## Step 5: Update Configuration

**Add provider to `config/chains.yml`:**

```yaml
ethereum:
  chain_id: 1
  providers:
    # ... existing providers
    - id: "[provider_name]_ethereum"
      name: "[Provider Display Name]"
      url: "https://[provider-endpoint]"
      ws_url: "wss://[provider-ws-endpoint]"  # Optional
      type: "public"  # or "private"
      priority: 5
      adapter_config:
        max_block_range: 1000  # Based on probe results
        # disable_batching: true  # If batch not supported
```

**For multi-chain providers, add to each chain:**

```yaml
base:
  chain_id: 8453
  providers:
    - id: "[provider_name]_base"
      name: "[Provider Display Name]"
      url: "https://[provider-endpoint]/base"
      ws_url: "wss://[provider-ws-endpoint]/base"
      type: "public"
      priority: 5
```

## Step 6: Validation

**Run validation checks:**

```bash
# 1. Compile and check for warnings
mix compile --warnings-as-errors

# 2. Run adapter tests (if custom adapter created)
mix test test/lasso/core/providers/adapters/[provider_name]_test.exs

# 3. Start server and smoke test
mix phx.server

# In another terminal:
curl -X POST http://localhost:4000/rpc/provider/[provider_name]_ethereum/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

**Verify in dashboard:**
- Open: http://localhost:4000/metrics/ethereum
- Confirm provider appears in leaderboard
- Check circuit breaker status (should be :closed)

## Output Format

Provide clear progress report:

```
ADDING RPC PROVIDER: [Provider Name]
====================================

STEP 1: Connectivity Tests
  ✅ ethereum HTTP: https://[endpoint] - chainId: 0x1
  ✅ ethereum WS: wss://[endpoint] - connected
  ✅ base HTTP: https://[endpoint]/base - chainId: 0x2105
  ✅ base WS: wss://[endpoint]/base - connected

STEP 2: Capability Discovery (via mix lasso.probe)
  Block Range:      unlimited (tested 10k+)
  Address Count:    unlimited (tested 100+)
  Batch Requests:   NOT SUPPORTED
  Archive Node:     full archive
  Rate Limits:      ~400 req/s, 89% success under load
  Subscriptions:    newHeads ✅, logs ✅, pendingTx ✅

STEP 3: Adapter Decision
  Decision: Custom adapter needed
  Reasons:
    - Batch requests disabled
    - Custom rate limit handling recommended

STEP 4: Implementation
  ✅ Created: lib/lasso/core/providers/adapters/[name].ex
  ✅ Registered in adapter_registry.ex
  ✅ Disables batch request forwarding

STEP 5: Configuration
  ✅ Added to config/chains.yml:
     - [provider_name]_ethereum
     - [provider_name]_base

STEP 6: Validation
  ✅ Compilation: PASS (0 warnings)
  ✅ Smoke test: eth_blockNumber successful
  ✅ Dashboard: Provider visible, circuit breaker closed

COMPLETE ✅
```

## Probe-Driven Workflow Example

Here's a real example workflow:

```bash
# 1. Quick connectivity check
curl -s -X POST https://gateway.tenderly.co/public/mainnet \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}'
# Returns: {"id":1,"jsonrpc":"2.0","result":"0x1"}

# 2. Check other chains
curl -s -X POST https://gateway.tenderly.co/public/base ...
curl -s -X POST https://gateway.tenderly.co/public/sepolia ...

# 3. WebSocket quick test
mix lasso.probe wss://mainnet.gateway.tenderly.co --probes websocket --subscription-wait 5000

# 4. Full capability probe
mix lasso.probe https://gateway.tenderly.co/public/mainnet --level standard

# 5. Review output for:
#    - PROVIDER LIMITS section (block range, batch support)
#    - METHOD SUPPORT section (unsupported methods)
#    - RECOMMENDATIONS section (suggested adapter config)
```

## When to Use

- Adding new RPC providers to Lasso
- Migrating from one provider to another
- Expanding multi-chain support
- Testing provider compatibility
- Diagnosing provider-specific issues

## Notes

- Always run probes before creating adapters - let data drive decisions
- Test across multiple chains if provider supports them
- Document probe results in adapter moduledoc
- Monitor circuit breaker behavior after deployment
- Re-probe periodically as providers may change limits
