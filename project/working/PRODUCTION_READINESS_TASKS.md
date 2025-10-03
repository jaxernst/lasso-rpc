# Production Readiness Tasks

**Status**: In Progress
**Target**: First Production Deployment
**Last Updated**: 2025-10-03

## ✅ COMPLETED

- [x] Initial audit and assessment
- [x] Identified critical issues and blockers

## 🔄 IN PROGRESS

### Phase 1: Critical Fixes (BLOCKING)

- [ ] **P0.1**: Remove ConnectionTracker references from RPCSocket
  - File: `lib/lasso_web/sockets/rpc_socket.ex`
  - Lines: 25, 482, 490, 498
  - Replace with Phoenix socket primitives
  - Status: NOT STARTED

- [ ] **P0.2**: Fix 21 failing WebSocket tests
  - File: `test/lasso/rpc/ws_connection_test.exs:1024, 1329`
  - Issue: Concurrent request correlation ID mismatches
  - Issue: Subscription lifecycle timeouts
  - Status: NOT STARTED

- [ ] **P0.3**: Add JSON parse error handling to RPC controller
  - File: `lib/lasso_web/controllers/rpc_controller.ex`
  - Return JSON-RPC error instead of HTML
  - Status: NOT STARTED

- [ ] **P0.4**: Fix circuit breaker integration
  - File: `lib/lasso/rpc/circuit_breaker.ex`
  - Add missing `record_failure/1` function
  - Complete test coverage
  - Status: NOT STARTED

### Phase 2: Production Configuration

- [ ] **P1.1**: Add production config with rate limiting
  - File: `config/prod.exs`
  - Add request timeouts
  - Add rate limiting configuration
  - Disable benchmark snapshots
  - Status: NOT STARTED

- [ ] **P1.2**: Fix health endpoint uptime calculation
  - Fix negative uptime value
  - Status: NOT STARTED

- [ ] **P1.3**: Clean up compiler warnings
  - Remove unused aliases (10 warnings)
  - Status: NOT STARTED

### Phase 3: Testing & Edge Cases

- [ ] **P2.1**: Create fuzz battle test with real providers
  - Test wide breadth of RPC methods
  - Test various parameter combinations
  - Test edge cases (null, empty arrays, large payloads)
  - Status: NOT STARTED

- [ ] **P2.2**: Test provider capability differences
  - Historical block/log retrieval limits
  - Failover behavior when provider doesn't support params
  - Status: NOT STARTED

- [ ] **P2.3**: Complete integration test stubs
  - File: `test/integration/failover_test.exs:297-309`
  - Status: NOT STARTED

### Phase 4: Documentation

- [ ] **P3.1**: Create future production needs document
  - Telemetry/metrics tracking
  - APM integration
  - Error tracking
  - Status: NOT STARTED

## 📋 ESTIMATED TIMELINE

- Phase 1: 6-8 hours
- Phase 2: 2-3 hours
- Phase 3: 4-6 hours
- Phase 4: 1 hour

**Total**: 13-18 hours

## 🎯 SUCCESS CRITERIA

- [ ] All unit tests passing (166/166)
- [ ] All integration tests passing
- [ ] Battle tests passing with real providers
- [ ] No compiler warnings
- [ ] Production config validated
- [ ] JSON-RPC error handling tested
- [ ] Provider failover tested with capability differences
