# Livechain Testing Guide

This document outlines the testing strategy and structure for the Livechain project.

## Test Structure Overview

### 1. ExUnit Test Suite (`/test/`)

**Purpose**: Automated unit and integration tests for CI/CD
**Run with**: `mix test`

#### Test Categories:

- **Unit Tests**: Individual module functionality
- **Integration Tests**: Component interaction testing
- **HTTP Tests**: Controller and API endpoint testing
- **Architecture Tests**: System-wide integration testing

#### Key Test Files:

```
test/
├── livechain_test.exs                    # Basic module tests
├── livechain/
│   ├── architecture_test.exs            # System integration tests
│   ├── telemetry_test.exs               # Telemetry event tests
│   ├── config/
│   │   └── chain_config_test.exs        # Configuration tests
│   └── rpc/
│       ├── endpoint_test.exs            # RPC endpoint tests
│       └── live_stream_test.exs         # WebSocket streaming tests
└── livechain_web/
    ├── conn_case.exs                    # HTTP test helpers
    └── controllers/
        ├── health_controller_test.exs   # Health endpoint tests
        ├── status_controller_test.exs   # Status endpoint tests
        └── rpc_controller_test.exs      # RPC endpoint tests
```

### 2. Validation Scripts (`/scripts/validation/`)

**Purpose**: Manual system validation and real-world testing
**Run with**: `mix run scripts/validation/<script>.exs`

#### Scripts:

- **`test_real_integration.exs`**: Comprehensive real RPC endpoint testing
  - Tests direct RPC calls to public endpoints
  - Validates JSON-RPC controller integration
  - Tests WebSocket connections to real networks

### 3. Demo Scripts (`/scripts/`)

**Purpose**: Feature demonstrations and presentations
**Run with**: `mix run scripts/<script>.exs`

#### Scripts:

- **`demo_hackathon.exs`**: Complete feature demonstration

  - Health endpoint validation
  - JSON-RPC endpoint testing
  - Multi-chain support validation
  - WebSocket subscription testing
  - System validation
  - Multi-client WebSocket instructions

- **`start_demo.exs`**: Quick start demonstration
  - Runs live demo for 2 minutes
  - Shows real-time blockchain data streaming

## Running Tests

### ExUnit Tests

```bash
# Run all tests
mix test

# Run specific test file
mix test test/livechain/architecture_test.exs

# Run tests with coverage
mix test --cover

# Run only integration tests
mix test --only integration

# Run only live tests (requires network)
mix test --only live
```

### Validation Scripts

```bash
# Test real RPC integration
mix run scripts/validation/test_real_integration.exs
```

### Demo Scripts

```bash
# Run complete hackathon demo
mix run scripts/demo_hackathon.exs

# Run quick start demo
mix run scripts/start_demo.exs
```

## Test Coverage

### ✅ Well-Covered Areas

1. **Configuration Management**

   - Config loading and validation
   - Environment variable substitution
   - Chain/provider lookups

2. **RPC Infrastructure**

   - Endpoint creation and validation
   - WebSocket connections
   - Real blockchain network integration

3. **Architecture Components**

   - Process registry functionality
   - Circuit breaker patterns
   - Message aggregation
   - Performance testing
   - Fault tolerance

4. **Telemetry**

   - Event emission for all major operations
   - Handler attachment/detachment

5. **HTTP Controllers**
   - JSON-RPC endpoint testing
   - Health and status endpoints
   - Error handling

### ⚠️ Areas Needing More Coverage

1. **WebSocket Channels**

   - Phoenix channel testing with real clients
   - Multi-client connection testing

2. **Error Scenarios**

   - Network failure handling
   - Rate limiting scenarios
   - Malicious input testing

3. **Load Testing**

   - High-throughput testing
   - Memory usage under load
   - Connection pool testing

4. **Security Testing**
   - Authentication/authorization
   - Input validation
   - Rate limiting

## Testing Best Practices

### 1. Unit Tests

- Test individual functions in isolation
- Use mocks for external dependencies
- Focus on edge cases and error conditions

### 2. Integration Tests

- Test component interactions
- Use real dependencies when possible
- Test end-to-end workflows

### 3. HTTP Tests

- Test all controller endpoints
- Validate response formats
- Test error conditions

### 4. Live Tests

- Tag with `@moduletag :live`
- Handle network failures gracefully
- Use timeouts for network operations

### 5. Performance Tests

- Measure response times
- Test under realistic load
- Monitor memory usage

## Adding New Tests

### For New Modules

1. Create test file in appropriate directory
2. Follow naming convention: `module_name_test.exs`
3. Include unit tests for all public functions
4. Add integration tests for complex workflows

### For New Controllers

1. Create test file in `test/livechain_web/controllers/`
2. Use `LivechainWeb.ConnCase`
3. Test all HTTP methods and status codes
4. Validate response formats

### For New Features

1. Add unit tests for core functionality
2. Add integration tests for feature workflows
3. Add HTTP tests for API endpoints
4. Consider adding validation scripts for manual testing

## Continuous Integration

Tests are automatically run in CI/CD pipeline:

- **Unit Tests**: Run on every commit
- **Integration Tests**: Run on pull requests
- **Live Tests**: Run on main branch (optional)
- **Coverage**: Minimum 80% coverage required

## Troubleshooting

### Common Issues

1. **Tests failing due to network issues**

   - Use `@moduletag :skip` for live tests
   - Add proper error handling for network failures

2. **Tests timing out**

   - Increase timeout for slow operations
   - Use `@moduletag timeout: 60_000`

3. **Tests interfering with each other**
   - Use `async: false` for tests that modify global state
   - Clean up after tests in `on_exit` callbacks

### Debugging

```bash
# Run tests with detailed output
mix test --trace

# Run specific test with debug info
mix test test/path/to/test.exs --trace

# Run tests with logger output
mix test --logger
```
