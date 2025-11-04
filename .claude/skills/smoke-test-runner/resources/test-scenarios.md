# Smoke Test Scenarios and Validation Criteria

Detailed test scenarios for Lasso RPC smoke testing.

## Test Scenario Categories

### 1. Core RPC Functionality

**Purpose:** Verify essential JSON-RPC methods work correctly

**Methods to test:**
- `eth_blockNumber` - Most basic, fastest method
- `eth_chainId` - Validates chain configuration
- `eth_gasPrice` - Tests price oracle integration
- `eth_getBalance` - Tests address queries (optional, needs valid address)

**Validation criteria:**
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": "0x..."  // Must be valid hex
}
```

**Success:**
- Valid JSON-RPC 2.0 response
- `result` field present (not `error`)
- Result format matches method (hex for blockNumber, etc.)
- Response time < 500ms P95

**Failure indicators:**
- JSON-RPC error response
- Timeout (>5000ms)
- Invalid JSON
- HTTP error (500, 502, 503)

### 2. Multi-Chain Support

**Purpose:** Validate all configured chains work

**Chains to test:**
- ethereum (chain_id: 0x1)
- base (chain_id: 0x2105)
- polygon (chain_id: 0x89) - if configured
- arbitrum (chain_id: 0xa4b1) - if configured

**Test pattern:**
```bash
for chain in ethereum base polygon arbitrum; do
  curl "$HOST/rpc/$chain" -d '{"jsonrpc":"2.0","method":"eth_chainId"...}'
done
```

**Validation:**
- Each chain returns correct chain_id
- Block numbers are recent (within last hour)
- Response times consistent across chains

**Failure indicators:**
- Wrong chain_id
- Chain not found (404)
- Stale block numbers (>1 hour old)

### 3. Routing Strategy Tests

**Purpose:** Verify all selection strategies function correctly

**Strategies:**
1. Default (`/rpc/:chain`) - Uses configured default strategy
2. Round-robin (`/rpc/round-robin/:chain`)
3. Fastest (`/rpc/fastest/:chain`)
4. Latency-weighted (`/rpc/latency-weighted/:chain`)

**Test method:** `eth_blockNumber` (fast, deterministic)

**Validation:**
- All strategies return successful responses
- Block numbers consistent (within 2-3 blocks of each other)
- Fastest strategy shows best average latency
- No routing errors

**Expected performance ranking:**
1. fastest - Should have lowest latency
2. latency-weighted - Should be close to fastest
3. round-robin - May be slower if includes slower providers

**Failure indicators:**
- Strategy returns error
- Block numbers diverge significantly (>10 blocks)
- Fastest is slower than round-robin (suggests scoring issue)

### 4. HTTP Batching

**Purpose:** Validate batch request support

**Test payload:**
```json
[
  {"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1},
  {"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":2},
  {"jsonrpc":"2.0","method":"eth_gasPrice","params":[],"id":3}
]
```

**Validation:**
- Response is array with 3 elements
- Each element has correct `id` matching request
- All responses successful
- Total time < 3× single request time (parallel execution)

**Failure indicators:**
- Response not an array
- Missing responses
- Incorrect `id` values
- Serial execution (time ≈ 3× single request)

### 5. Observability & Metadata

**Purpose:** Verify routing transparency features

**Test A: Metadata in Headers**
```bash
curl -i "$HOST/rpc/ethereum?include_meta=headers"
```

**Expected headers:**
```
X-Lasso-Request-ID: <uuid>
X-Lasso-Meta: <base64url-encoded-json>
```

**Decode and validate:**
```bash
# Extract meta header
meta=$(echo "$response" | grep "X-Lasso-Meta:" | cut -d' ' -f2)

# Decode (base64url)
echo "$meta" | base64 -d | jq

# Should contain:
{
  "chain": "ethereum",
  "strategy": "round_robin",
  "selected_provider": {...},
  "upstream_latency_ms": 123,
  ...
}
```

**Test B: Metadata in Body**
```bash
curl "$HOST/rpc/ethereum?include_meta=body"
```

**Expected response:**
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": "0x...",
  "lasso_meta": {
    "chain": "ethereum",
    "selected_provider": {...},
    ...
  }
}
```

**Validation:**
- Headers mode: Both headers present and valid
- Body mode: `lasso_meta` field present with routing info
- Metadata contains expected fields (chain, strategy, provider, latency)

### 6. Performance Baseline

**Purpose:** Detect performance regressions

**Test methodology:**
1. Run 20 sequential requests for `eth_blockNumber`
2. Measure total time for each
3. Calculate percentiles (P50, P95, P99)
4. Compare to baseline

**Sample sizes:**
- Quick check: 10 samples (±30% variance acceptable)
- Standard: 20 samples (±20% variance)
- Thorough: 50 samples (±10% variance)

**Baseline expectations (local):**
```
P50: 100-150ms
P95: 200-300ms
P99: 300-500ms
```

**Baseline expectations (prod):**
```
P50: 150-250ms
P95: 300-500ms
P99: 500-1000ms
```

**Regression thresholds:**
- ⚠️  Warning: >15% slower than baseline
- ❌ Critical: >30% slower or any timeouts

**Consider factors:**
- Time of day (peak vs off-peak)
- Provider health (check dashboard)
- Network conditions
- Recent deployments

### 7. Provider-Specific Routing

**Purpose:** Validate direct provider selection

**Test pattern:**
```bash
# Test specific provider
curl "$HOST/rpc/provider/<provider_id>/ethereum"
```

**Common providers to test:**
- ethereum_llamarpc
- ethereum_cloudflare
- base_publicnode

**Validation:**
- Provider responds successfully
- Response time within expected range for provider
- Block number recent

**Use case:**
- Debugging provider issues
- Validating new provider integration
- A/B testing providers

### 8. Error Handling

**Purpose:** Verify graceful error handling

**Test A: Invalid Method**
```bash
curl "$HOST/rpc/ethereum" -d '{"jsonrpc":"2.0","method":"eth_invalidMethod","params":[],"id":1}'
```

**Expected:**
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": {
    "code": -32601,
    "message": "Method not found"
  }
}
```

**Test B: Invalid Params**
```bash
curl "$HOST/rpc/ethereum" -d '{"jsonrpc":"2.0","method":"eth_getBalance","params":["invalid"],"id":1}'
```

**Expected:**
- Proper JSON-RPC error response
- Meaningful error message
- Appropriate error code

**Validation:**
- Returns JSON-RPC error (not HTTP 500)
- Error code and message are informative
- Request ID preserved in response

## Automation Script Template

```bash
#!/bin/bash
# smoke-test.sh

HOST="${1:-http://localhost:4000}"
FAILED=0

echo "🔥 Lasso RPC Smoke Test"
echo "Target: $HOST"
echo "======================="

# Test 1: Basic RPC
echo "Testing eth_blockNumber..."
result=$(curl -s -w "\n%{http_code}" "$HOST/rpc/ethereum" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}')

http_code=$(echo "$result" | tail -1)
response=$(echo "$result" | head -1)

if [ "$http_code" != "200" ]; then
  echo "❌ FAIL: HTTP $http_code"
  FAILED=$((FAILED+1))
elif ! echo "$response" | jq -e '.result' > /dev/null 2>&1; then
  echo "❌ FAIL: No result field"
  FAILED=$((FAILED+1))
else
  block=$(echo "$response" | jq -r '.result')
  echo "✅ PASS: Block $block"
fi

# ... more tests

echo "======================="
echo "Passed: $((TOTAL-FAILED))/$TOTAL"
exit $FAILED
```

## Test Execution Checklist

- [ ] All basic RPC methods work
- [ ] All configured chains respond
- [ ] All routing strategies operational
- [ ] HTTP batching functions correctly
- [ ] Observability metadata present
- [ ] Performance within baseline
- [ ] Provider-specific routing works
- [ ] Error handling graceful
- [ ] No obvious regressions

## Next Steps After Smoke Test

**If all passed:**
- Update baseline if performance improved
- Document any new observations
- Schedule next test

**If regressions found:**
- Check provider dashboard for issues
- Compare to recent deployments
- Run load test for deeper analysis
- Review recent config changes

**If failures found:**
- Check server logs
- Verify provider configuration
- Test individual providers
- Escalate if critical
