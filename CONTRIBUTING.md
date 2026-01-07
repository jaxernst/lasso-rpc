# Contributing to Lasso RPC

Thank you for your interest in contributing to Lasso RPC! This document provides guidelines for contributing to the project.

## Development Setup

### Prerequisites

- **Elixir**: 1.17+ (check with `elixir --version`)
- **Erlang/OTP**: 26+ (check with `erl -version`)
- **Node.js**: 18+ (for asset compilation)
- **Git**: For version control

### Quick Start

```bash
# Clone the repository
git clone https://github.com/jaxernst/lasso-rpc.git
cd lasso-rpc

# Install dependencies
mix deps.get

# Start the Phoenix server
mix phx.server
```

The application will be available at `http://localhost:4000`.

### Environment Variables

Create a `.env` file for local development (see `.env.example` for template):

```bash
# Optional: Add your RPC provider API keys
DRPC_API_KEY=your_key_here
LAVA_API_KEY=your_key_here
# ... etc
```

## Development Workflow

### Running Tests

```bash
# Run all tests
mix test

# Run specific test file
mix test test/lasso/core/request/request_pipeline_test.exs

# Run with coverage
mix test --cover

# Run integration tests (requires real providers)
mix test --only integration
```

### Code Quality Tools

Before submitting a pull request, ensure your code passes all quality checks:

```bash
# Format code
mix format

# Check formatting
mix format --check-formatted

# Run linter
mix credo --strict

# Run static analysis (first run may take a while)
mix dialyzer

# Run all checks at once
mix format --check-formatted && mix credo --strict && mix test
```

### Documentation

- Document public APIs with `@doc` and `@moduledoc`
- Include examples in documentation where helpful
- Update relevant documentation in `docs/` when changing behavior
- Keep README.md up to date with new features

## Pull Request Process

### Before Submitting

1. **Create a feature branch** from `main`:
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Write tests** for new functionality
   - Unit tests for individual modules
   - Integration tests for request pipeline changes
   - No placeholder tests (`assert true`)

3. **Ensure all tests pass**:
   ```bash
   mix test
   ```

4. **Run code quality checks**:
   ```bash
   mix format --check-formatted
   mix credo --strict
   ```

5. **Update documentation** if needed

6. **Commit your changes** with clear, descriptive messages:
   ```bash
   git commit -m "Add feature: description of what was added"
   ```

### Submitting a Pull Request

1. Push your branch to GitHub:
   ```bash
   git push origin feature/your-feature-name
   ```

2. Open a pull request with:
   - **Clear title** describing the change
   - **Description** explaining what and why
   - **Screenshots** if UI changes are involved
   - **Link to related issues** if applicable

3. Wait for review and address feedback

## Types of Contributions

### Bug Fixes

- Search existing issues before creating a new one
- Include reproduction steps in the issue
- Reference the issue number in your PR

### New Features

- Open an issue to discuss the feature before implementing
- Consider backward compatibility
- Update documentation and examples
- Add comprehensive tests

### Documentation

- Fix typos, improve clarity, add examples
- Keep documentation in sync with code
- Update ARCHITECTURE.md for significant architectural changes

### Performance Improvements

- Include benchmarks showing the improvement
- Ensure no regression in functionality
- Consider the trade-offs

## Testing Requirements

### Unit Tests

- Test individual functions and modules
- Mock external dependencies
- Focus on edge cases and error handling

### Integration Tests

- Test the request pipeline end-to-end
- Test with real or realistic provider responses
- Verify telemetry events are emitted

### Test Guidelines

- Use descriptive test names
- One assertion per test when possible
- Use fixtures for complex test data
- Tag slow tests appropriately (`:integration`, `:real_providers`)

Example test structure:
```elixir
describe "function_name/2" do
  test "returns expected value for valid input" do
    assert MyModule.function_name(valid_input) == expected_output
  end

  test "raises error for invalid input" do
    assert_raise ArgumentError, fn ->
      MyModule.function_name(invalid_input)
    end
  end
end
```

## Project Structure

Key directories:
- `lib/lasso/core/` - Core RPC routing and provider management
- `lib/lasso_web/` - Phoenix web interface and controllers
- `config/` - Application configuration
- `config/profiles/` - Profile-specific chain and provider configs
- `test/` - Test files mirroring `lib/` structure
- `docs/` - Documentation and guides

## License

By contributing, you agree that your contributions will be licensed under the same AGPL-3.0 license that covers this project.