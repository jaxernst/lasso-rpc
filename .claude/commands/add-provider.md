---
description: Guide through complete workflow for adding a new RPC provider to Lasso
---

# Add New RPC Provider

Complete end-to-end workflow for integrating a new RPC provider into Lasso.

## Overview

Adding a provider involves:
1. Gathering provider information
2. Creating provider adapter (if needed)
3. Updating configuration
4. Creating tests
5. Validating integration

## Step 1: Gather Provider Information

**Ask user for:**
- Provider name (e.g., "Alchemy", "Infura", "QuickNode")
- Provider type/category (public, private, premium)
- RPC endpoint URL (HTTP)
- WebSocket endpoint URL (if supported)
- API key requirements (if any)
- Known limitations:
  - Rate limits
  - Block range limits for eth_getLogs
  - Supported methods
  - Archive node availability

**Example questions:**
```
I'll help you add a new RPC provider to Lasso.

Please provide:
1. Provider name: ___
2. HTTP endpoint URL: ___
3. WebSocket endpoint URL (or "none"): ___
4. Is this a public provider? (y/n): ___
5. Does it require an API key? (y/n): ___
6. Any known limitations? (rate limits, block ranges, etc.): ___
```

## Step 2: Determine If Custom Adapter Needed

**Check if provider has special requirements:**

**Needs custom adapter if:**
- Custom error codes or messages
- Special rate limit behavior
- Block range restrictions for eth_getLogs
- Custom authentication headers
- Non-standard JSON-RPC responses

**Can use generic adapter if:**
- Standard JSON-RPC 2.0
- No special limitations
- Standard error codes
- No custom headers

**Existing adapters in `lib/lasso/core/providers/adapters/`:**
- Alchemy (eth_getLogs block range: 10)
- PublicNode (address count limits)
- LlamaRPC (block range: 1000)
- Merkle (block range: 1000)
- Cloudflare (no restrictions)
- DRPC (custom error codes)
- 1RPC (custom rate limit errors)

## Step 3: Create Provider Adapter (if needed)

**If custom adapter needed, create from template:**

```elixir
# lib/lasso/core/providers/adapters/[provider_name].ex

defmodule Lasso.RPC.Providers.Adapters.[ProviderName] do
  @moduledoc """
  Provider adapter for [Provider Name].

  Known limitations:
  - [List specific limitations]

  Configuration options:
  - `:option_name` - Description (default: value)
  """

  @behaviour Lasso.RPC.ProviderAdapter

  import Lasso.RPC.Providers.AdapterHelpers

  # Default limits
  @default_block_range 1000

  @impl true
  def supports_method?(method, _transport, _ctx) do
    # Most providers support all standard methods
    # Override if provider has limitations
    method in [
      "eth_blockNumber",
      "eth_chainId",
      "eth_getBalance",
      "eth_getLogs",
      # ... etc
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

## Step 4: Update Configuration

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
        max_block_range: 1000  # If custom adapter
```

**If API key required, document in README:**

```markdown
## Environment Variables

For [Provider Name], set:
```bash
export [PROVIDER]_API_KEY="your-api-key"
```

## Step 5: Create Tests

**Create adapter test (if custom adapter):**

```elixir
# test/lasso/core/providers/adapters/[provider_name]_test.exs

defmodule Lasso.RPC.Providers.Adapters.[ProviderName]Test do
  use ExUnit.Case, async: true

  alias Lasso.RPC.Providers.Adapters.[ProviderName]

  describe "supports_method?/3" do
    test "supports standard eth methods" do
      assert [ProviderName].supports_method?("eth_blockNumber", :http, %{})
      assert [ProviderName].supports_method?("eth_getLogs", :http, %{})
    end
  end

  describe "validate_params/4" do
    test "accepts eth_getLogs within block range limit" do
      params = [%{"fromBlock" => "0x1", "toBlock" => "0x64"}]  # 100 blocks
      assert :ok = [ProviderName].validate_params("eth_getLogs", params, :http, %{})
    end

    test "rejects eth_getLogs exceeding block range limit" do
      # Test with range exceeding default limit
      params = [%{"fromBlock" => "0x1", "toBlock" => "0x1000"}]  # 4096 blocks
      assert {:error, {:param_limit, _}} =
        [ProviderName].validate_params("eth_getLogs", params, :http, %{})
    end
  end

  describe "classify_error/2" do
    # Add tests for any custom error classification
  end

  describe "metadata/0" do
    test "returns adapter metadata" do
      meta = [ProviderName].metadata()
      assert meta.provider_type == "[provider_name]"
      assert is_map(meta.configurable_limits)
    end
  end
end
```

**Create integration test:**

```elixir
# test/integration/providers/[provider_name]_integration_test.exs

defmodule Lasso.Integration.Providers.[ProviderName]IntegrationTest do
  use Lasso.IntegrationCase, async: false

  @moduletag :integration
  @moduletag :skip  # Remove after provider configured

  describe "[Provider Name] integration" do
    test "successfully routes request to [provider_name]" do
      # Start provider
      {:ok, _} = start_provider("[provider_name]_ethereum")

      # Make request
      {:ok, result} = make_rpc_request("ethereum", "eth_blockNumber", [])

      # Validate
      assert is_binary(result)
      assert String.starts_with?(result, "0x")
    end
  end
end
```

## Step 6: Validate Integration

**Run validation checks:**

```bash
# 1. Compile
mix compile

# 2. Run adapter tests
mix test test/lasso/core/providers/adapters/[provider_name]_test.exs

# 3. Run integration test (if provider configured)
mix test test/integration/providers/[provider_name]_integration_test.exs

# 4. Manual smoke test
curl -X POST http://localhost:4000/rpc/provider/[provider_name]_ethereum/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

**Verify in dashboard:**
- Start server: `mix phx.server`
- Open: http://localhost:4000/metrics/ethereum
- Confirm provider appears in leaderboard
- Check circuit breaker status

## Step 7: Documentation

**Update documentation:**

1. **README.md** - Add provider to supported list
2. **project/ARCHITECTURE.md** - Document any adapter-specific behavior
3. **config/chains.yml** - Add comments for configuration options

## Completion Checklist

```
✅ Provider information gathered
✅ Adapter created (if needed) and registered
✅ Configuration updated in chains.yml
✅ Adapter tests created and passing
✅ Integration tests created
✅ Manual smoke test successful
✅ Provider visible in dashboard
✅ Documentation updated
```

## Output Format

Provide clear progress report:

```
ADDING RPC PROVIDER: [Provider Name]
====================================

STEP 1: Information Gathered
  Name: [Provider Name]
  Type: Public
  HTTP: https://[endpoint]
  WS: wss://[endpoint]
  Limitations: Block range 1000, no archive

STEP 2: Adapter Strategy
  Decision: Custom adapter needed (block range limit)

STEP 3: Adapter Created
  ✅ Created: lib/lasso/core/providers/adapters/[name].ex
  ✅ Registered in adapter_registry.ex
  ✅ Implements block range validation

STEP 4: Configuration Updated
  ✅ Added to config/chains.yml for ethereum

STEP 5: Tests Created
  ✅ Adapter tests: 8 tests passing
  ✅ Integration test: created (requires provider setup)

STEP 6: Validation
  ✅ Compilation: PASS
  ✅ Adapter tests: 8/8 PASS
  ⚠️  Integration test: SKIPPED (needs API key)
  ⏳ Manual smoke test: TODO

NEXT STEPS:
1. Set API key in environment
2. Run manual smoke test
3. Remove :skip tag from integration test
4. Update README with provider details
```

## When to Use

- Adding new RPC providers to Lasso
- Migrating from one provider to another
- Expanding multi-chain support
- Testing provider compatibility

## Notes

- Use existing adapters as reference examples
- Test thoroughly before production use
- Document provider-specific quirks
- Monitor circuit breaker behavior after adding
