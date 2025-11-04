# Provider Integration Checklist

Complete checklist for adding a new RPC provider to Lasso RPC.

## Pre-Integration

- [ ] Provider information gathered
  - [ ] Provider name and type
  - [ ] HTTP endpoint URL
  - [ ] WebSocket endpoint URL (if supported)
  - [ ] API key requirements
  - [ ] Known limitations documented
  - [ ] Target chains identified

- [ ] Adapter strategy decided
  - [ ] Custom adapter needed? (Yes/No)
  - [ ] Template selected (if custom)
  - [ ] Limitations mapped to adapter features

## Code Changes

### Adapter (if custom)

- [ ] Adapter file created: `lib/lasso/core/providers/adapters/[name].ex`
- [ ] Implements `ProviderAdapter` behaviour
- [ ] Imports `AdapterHelpers`
- [ ] Defines default limits
- [ ] Implements `supports_method?/3`
- [ ] Implements `validate_params/4` for known limitations
- [ ] Implements `classify_error/2` (if custom errors)
- [ ] Implements `headers/1` (if custom auth)
- [ ] Implements `metadata/0`
- [ ] Registered in `adapter_registry.ex`

### Configuration

- [ ] Added to `config/chains.yml` for each chain
- [ ] Provider ID follows naming convention (`[provider]_[chain]`)
- [ ] URLs configured correctly
- [ ] Type set appropriately (public/private)
- [ ] Priority assigned
- [ ] `adapter_config` added (if custom adapter)
- [ ] Configuration comments added

### Environment (if needed)

- [ ] API key environment variable documented
- [ ] URL template updated for API key injection
- [ ] .env.example updated
- [ ] Deployment docs updated (if relevant)

## Testing

### Adapter Tests (if custom adapter)

- [ ] Test file created: `test/lasso/core/providers/adapters/[name]_test.exs`
- [ ] Tests for `supports_method?/3`
- [ ] Tests for `validate_params/4` with various inputs
- [ ] Tests for adapter_config overrides
- [ ] Tests for `classify_error/2` (if custom)
- [ ] Tests for `metadata/0`
- [ ] All tests passing

### Integration Tests

- [ ] Test file created: `test/integration/providers/[name]_integration_test.exs`
- [ ] Test for successful request routing
- [ ] Test for provider-specific error handling
- [ ] Tests tagged appropriately (`:integration`)
- [ ] Tests skipped if provider not configured (`:skip` tag)

### Validation

- [ ] Compilation clean: `mix compile`
- [ ] Adapter tests passing: `mix test test/.../[name]_test.exs`
- [ ] Integration tests passing (if configured)
- [ ] No new Credo warnings: `mix credo --strict`
- [ ] No new Dialyzer warnings: `mix dialyzer`

## Manual Testing

### Local Testing

- [ ] Server started: `mix phx.server`
- [ ] Provider visible in dashboard: http://localhost:4000/metrics/[chain]
- [ ] Manual curl test successful:
  ```bash
  curl -X POST http://localhost:4000/rpc/provider/[provider_id]/[chain] \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
  ```
- [ ] Response valid and latency acceptable
- [ ] Provider circuit breaker functioning
- [ ] Provider appears in routing strategies

### Dashboard Verification

- [ ] Provider appears in leaderboard
- [ ] Latency metrics updating
- [ ] Circuit breaker status visible
- [ ] Provider can be selected for routing

### Smoke Testing

- [ ] Basic RPC methods work through provider
- [ ] Routing strategies include provider
- [ ] Error handling graceful
- [ ] Performance acceptable

## Documentation

- [ ] README.md updated with provider in supported list
- [ ] Provider-specific configuration documented
- [ ] Known limitations documented
- [ ] API key setup documented (if needed)
- [ ] Example configuration provided

### Architecture Documentation

- [ ] Adapter added to ARCHITECTURE.md (if custom)
- [ ] Limitations explained
- [ ] Configuration options documented

### Code Comments

- [ ] Adapter has clear @moduledoc
- [ ] Complex logic commented
- [ ] Configuration options explained in chains.yml comments

## Deployment (if applicable)

- [ ] Staging environment updated
- [ ] Staging smoke tests passing
- [ ] Production configuration prepared
- [ ] API keys configured in deployment environment
- [ ] Production deployment executed
- [ ] Production smoke tests passing
- [ ] Provider visible in prod dashboard
- [ ] No errors in production logs

## Post-Integration

- [ ] Monitor provider performance for 24-48 hours
- [ ] Check circuit breaker behavior
- [ ] Verify no unexpected errors
- [ ] Collect baseline performance metrics
- [ ] Update baseline-metrics.md (if relevant)

## Rollback Plan (if needed)

- [ ] Know how to remove provider from config
- [ ] Know how to disable provider without code changes
- [ ] Have previous config backed up
- [ ] Verified rollback procedure

## Example: Completing Checklist for DRPC

```
## Pre-Integration
✅ Provider information gathered
   - Name: DRPC
   - HTTP: https://drpc.org/ethereum
   - WS: wss://drpc.org/ethereum/ws
   - API Key: No (public tier)
   - Limitations: Custom error codes for rate limits
   - Chains: ethereum, base

✅ Adapter strategy decided
   - Custom adapter needed: Yes
   - Template: DRPC-specific for error handling
   - Features: classify_error/2 for codes 30, 35

## Code Changes
✅ Adapter created: lib/lasso/core/providers/adapters/drpc.ex
✅ Registered in adapter_registry.ex
✅ Added to chains.yml for ethereum and base
✅ No API key needed

## Testing
✅ Adapter tests created: 6 tests, all passing
✅ Integration tests created: 2 tests
⚠️  Integration tests skipped (needs live configuration)

## Validation
✅ Compilation: PASS
✅ Adapter tests: 6/6 PASS
✅ Credo: PASS
✅ Dialyzer: PASS

## Manual Testing
✅ Server started, provider visible in dashboard
✅ Manual curl successful (134ms latency)
✅ Circuit breaker functioning
✅ Appears in routing strategies

## Documentation
✅ README updated
✅ Adapter documented in code
✅ Configuration commented

## Status: COMPLETE ✅

Next: Monitor performance for 24 hours
```

## Integration Time Estimate

**With custom adapter:**
- Information gathering: 5-10 minutes
- Adapter creation: 15-20 minutes
- Configuration: 5 minutes
- Testing: 10-15 minutes
- Documentation: 5 minutes
- Validation: 5-10 minutes

**Total: 45-65 minutes**

**With generic adapter:**
- Information gathering: 5 minutes
- Configuration: 5 minutes
- Testing: 10 minutes
- Documentation: 5 minutes
- Validation: 5 minutes

**Total: 30 minutes**

## Common Issues & Solutions

**Issue: Adapter tests failing**
- Check that validate_params logic matches limitations
- Verify hex math for block ranges
- Ensure adapter_config access correct

**Issue: Provider not appearing in dashboard**
- Check server logs for errors
- Verify provider ID in config matches adapter registry
- Ensure chain supervisor started successfully

**Issue: Compilation warnings**
- Run /code-cleanup to fix automatically
- Check for unused imports
- Verify all callbacks implemented

**Issue: Integration tests failing**
- Verify provider configured correctly in test environment
- Check API key set (if required)
- Ensure test provider URLs reachable

**Issue: Provider always circuit broken**
- Check provider URL is correct and reachable
- Verify API key valid (if required)
- Check provider not actually down
- Review circuit breaker thresholds
