# Test Guide

This project uses ExUnit tags to categorize tests by speed and purpose.

## Running Tests

### Quick CI Tests (Default)
Run fast unit tests suitable for CI pipelines:
```bash
mix test
```

This excludes: `:skip`, `:integration`, `:real_providers`, `:slow`

### Integration Tests
Run integration tests that use mocked providers:
```bash
mix test --include integration
```

Or run ONLY integration tests:
```bash
mix test --only integration
```

### Live Provider and Slow Tests

```bash
mix test --include integration --include real_providers --include slow
```

These opt-in tests can make real network requests. The default and integration
suites use local fixtures and do not require provider credentials.

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

### `:real_providers`
- Tests that connect to real Ethereum RPC providers
- Require network connectivity
- Subject to rate limits and network latency

### `:slow`
- Any test that takes > 10 seconds
- Can overlap with `:real_providers`

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

CI runs unit tests and the full hermetic integration suite, plus formatting,
Credo, Dialyzer, dependency auditing, and Docker build/boot checks. The dashboard
simulator's JavaScript contract tests run through ExUnit and require Node.js 18+.

Use `mix test --include integration` to reproduce the full hermetic suite locally.
