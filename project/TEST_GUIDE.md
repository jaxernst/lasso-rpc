# Test Guide

This project uses ExUnit tags to categorize tests by speed and purpose.

## Running Tests

### Quick CI Tests (Default)
Run fast unit tests suitable for CI pipelines:
```bash
mix test
```

This excludes: `:skip`, `:integration`, `:battle`, `:real_providers`, `:slow`

### Integration Tests
Run integration tests that use mocked providers:
```bash
mix test --include integration
```

Or run ONLY integration tests:
```bash
mix test --only integration
```

### Battle Tests
Run battle tests with real provider connections:
```bash
mix test --include battle
```

**Warning:** Battle tests make real network calls and may take several minutes.

### All Tests
Run everything including slow tests:
```bash
mix test --include integration --include battle --include slow
```

Or simply include all:
```bash
mix test --include integration --include battle --include real_providers --include slow
```

## Test Categories

### Fast Tests (No Tag)
- Unit tests
- Mocked tests
- Tests that complete in < 1 second
- **Run by default with `mix test`**

### `:integration`
- Integration tests with mocked external dependencies
- Tests that verify multiple components working together
- Typically 1-10 seconds per test

### `:battle`
- Performance and chaos testing scenarios
- Long-running stress tests
- May take 30+ seconds per test

### `:real_providers`
- Tests that connect to real Ethereum RPC providers
- Require network connectivity
- Subject to rate limits and network latency

### `:slow`
- Any test that takes > 10 seconds
- Often overlaps with `:battle` or `:real_providers`

### `:skip`
- Disabled tests (WIP or known issues)
- Never run unless explicitly included

## Adding Tags to Tests

```elixir
defmodule MyIntegrationTest do
  use ExUnit.Case, async: false

  # Tag entire module
  @moduletag :integration

  # Tag specific test
  @tag :slow
  test "long running operation" do
    # ...
  end
end
```

## CI Configuration

For CI pipelines, use the default `mix test` command which runs only fast unit tests.

For nightly builds or pre-release validation, include integration and battle tests:
```bash
mix test --include integration --include battle
```