---
description: Run smoke tests against a Lasso RPC endpoint (local/staging/prod) to validate functionality and performance
---

# Lasso RPC Smoke Test

Execute basic smoke tests against a Lasso RPC endpoint to validate:
- Core RPC methods work correctly
- Response times are acceptable
- Routing strategies function properly
- No obvious regressions

## Usage

Specify the target environment:
- **local**: http://localhost:4000
- **staging**: https://staging-lasso-rpc.fly.dev (if exists)
- **prod**: https://lasso-rpc.fly.dev

Default: local

## Test Scenarios

### 1. Basic RPC Methods (Default Strategy)

Test these essential methods against `/rpc/ethereum`:

```bash
# Test eth_blockNumber
curl -s -X POST "$HOST/rpc/ethereum" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# Test eth_chainId
curl -s -X POST "$HOST/rpc/ethereum" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":2}'

# Test eth_gasPrice
curl -s -X POST "$HOST/rpc/ethereum" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_gasPrice","params":[],"id":3}'
```

**Validate:**
- Each returns valid JSON-RPC response with `result` field
- `eth_blockNumber` returns hex number (e.g., "0x12d4f5c")
- `eth_chainId` returns "0x1" for ethereum
- Response time < 500ms P95

### 2. Routing Strategy Tests

Test each strategy endpoint with `eth_blockNumber`:

```bash
# Round-robin
curl -s -X POST "$HOST/rpc/round-robin/ethereum" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# Fastest
curl -s -X POST "$HOST/rpc/fastest/ethereum" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# Latency-weighted
curl -s -X POST "$HOST/rpc/latency-weighted/ethereum" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

**Validate:**
- All strategies return successful responses
- Block numbers are consistent (within 1-2 blocks)
- No routing errors

### 3. HTTP Batching

```bash
curl -s -X POST "$HOST/rpc/ethereum" \
  -H 'Content-Type: application/json' \
  -d '[
    {"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1},
    {"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":2},
    {"jsonrpc":"2.0","method":"eth_gasPrice","params":[],"id":3}
  ]'
```

**Validate:**
- Returns array with 3 responses
- Each response has correct `id` matching request
- All responses successful

### 4. Observability Metadata

```bash
# Test metadata in headers
curl -s -X POST "$HOST/rpc/ethereum?include_meta=headers" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  -i | grep -E "X-Lasso-(Request-ID|Meta)"

# Test metadata in body
curl -s -X POST "$HOST/rpc/ethereum?include_meta=body" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

**Validate:**
- Headers mode: `X-Lasso-Request-ID` and `X-Lasso-Meta` headers present
- Body mode: Response contains `lasso_meta` field with routing info

### 5. Multi-Chain Support

Test Base chain if available:

```bash
curl -s -X POST "$HOST/rpc/base" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}'
```

**Validate:**
- Returns "0x2105" (8453 in hex) for Base
- Response time similar to Ethereum

### 6. Performance Baseline

Run 10 requests and measure latency distribution:

```bash
for i in {1..10}; do
  curl -s -w "%{time_total}\n" -o /dev/null -X POST "$HOST/rpc/ethereum" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
done
```

**Validate:**
- P50 < 300ms
- P95 < 500ms
- P99 < 1000ms
- No requests timeout or error

## Output Format

Provide a clear pass/fail report:

```
🔥 LASSO RPC SMOKE TEST
Target: https://lasso-rpc.fly.dev
=======================

✅ Basic RPC Methods (3/3)
   eth_blockNumber: 142ms (block: 0x12d4f5c)
   eth_chainId: 89ms (chain: 0x1)
   eth_gasPrice: 134ms (gas: 0x5d21dba00)

✅ Routing Strategies (3/3)
   round-robin: 156ms
   fastest: 98ms
   latency-weighted: 123ms

✅ HTTP Batching: 187ms (3 requests)

✅ Observability
   Metadata headers: present
   Metadata body: present

✅ Multi-Chain
   Base chain: 145ms (chain: 0x2105)

✅ Performance Baseline
   P50: 134ms
   P95: 187ms
   P99: 245ms
   Min: 89ms / Max: 245ms

OVERALL: ✅ ALL TESTS PASSED

NOTES:
- Fastest strategy showing best performance (98ms avg)
- All routing strategies operational
- Response times within acceptable range
```

## When Failures Occur

If any test fails:
1. Report the specific failure with error message
2. Suggest likely causes (provider down, config issue, network problem)
3. Recommend next steps (check logs, validate config, test manually)

## When to Use

- After deploying to staging/prod
- Before announcing new features
- During incident investigation
- Weekly automated checks
- After provider configuration changes

## Integration with Existing Tools

This command uses the same endpoints documented in README.md, making it easy to:
- Compare smoke test results to documented behavior
- Validate examples in README still work
- Catch documentation drift
