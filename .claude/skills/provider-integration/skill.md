---
name: provider-integration
description: Complete end-to-end workflow for adding new RPC providers to Lasso with adapter creation, testing, and validation
---

# Provider Integration Agent

Guide users through the complete process of adding new RPC providers to Lasso, from gathering requirements to production validation.

## When to Auto-Invoke

This skill should be **automatically triggered** when:

1. **User wants to add a provider**
   - "Add [provider name]  to Lasso"
   - "Integrate [provider] for ethereum"
   - "I want to use [provider]"

2. **User mentions new provider**
   - "Can we support [provider]?"
   - "How do I add [provider]?"
   - "What providers work with Lasso?"

## Core Responsibilities

### Phase 1: Information Gathering (Interactive)

**Ask structured questions to gather requirements:**

```
I'll help you integrate [Provider Name] into Lasso RPC.

Let me gather some information:

1. Provider Name: [User provides]

2. Provider URLs:
   - HTTP endpoint: ___
   - WebSocket endpoint (or type "none"): ___

3. Provider Type:
   - [ ] Public (free, no auth)
   - [ ] Private (requires API key)
   - [ ] Premium (paid tier)

4. API Key Requirements:
   - [ ] No API key needed
   - [ ] API key in URL
   - [ ] API key in header
   - [ ] Other (specify): ___

5. Known Limitations:
   Does this provider have any of these limitations?
   - [ ] Block range limit for eth_getLogs (specify blocks): ___
   - [ ] Address count limit for eth_getLogs: ___
   - [ ] Rate limits (requests/second): ___
   - [ ] Archive node support: Yes / No / Unknown
   - [ ] Custom error codes: Yes / No
   - [ ] Other limitations: ___

6. Which chains should this provider support?
   - [ ] Ethereum
   - [ ] Base
   - [ ] Polygon
   - [ ] Arbitrum
   - [ ] Other: ___
```

**Store gathered info** in structured format for next phases.

### Phase 2: Adapter Strategy Decision

**Analyze gathered information** to determine adapter needs:

**Decision tree:**

```
Does provider have special requirements?
├─ YES
│  ├─ Block range limits? → Custom adapter needed
│  ├─ Address limits? → Custom adapter needed
│  ├─ Custom error codes? → Custom adapter needed
│  ├─ Custom auth headers? → Custom adapter needed
│  └─ Non-standard responses? → Custom adapter needed
└─ NO → Use Generic adapter
```

**Report decision with reasoning:**

```
ADAPTER STRATEGY DECISION:
==========================

Decision: Custom Adapter Recommended

Reasoning:
- Provider has eth_getLogs block range limit of 100 blocks
- Requires special error code handling for rate limits
- Standard JSON-RPC otherwise

Recommendation: Create adapter based on Alchemy or LlamaRPC template
```

### Phase 3: Adapter Creation (If Needed)

**If custom adapter needed:**

1. **Select template** based on requirements:
   - Block range limits → Use Alchemy template
   - Address limits → Use PublicNode template
   - Custom errors → Use DRPC template
   - Generic custom → Use LlamaRPC template

2. **Generate adapter file** from template:

```elixir
# lib/lasso/core/providers/adapters/[provider_name].ex

defmodule Lasso.RPC.Providers.Adapters.[ProviderName] do
  @moduledoc """
  Provider adapter for [Provider Name].

  Known limitations:
  - [Auto-populated from gathered info]

  Configuration options:
  - `:max_block_range` - Maximum block range for eth_getLogs (default: [value])
  """

  @behaviour Lasso.RPC.ProviderAdapter

  import Lasso.RPC.Providers.AdapterHelpers

  # [Auto-populate defaults based on gathered info]
  @default_max_block_range [value]

  @impl true
  def supports_method?(method, _transport, _ctx) do
    # Standard methods supported
    method in [
      "eth_blockNumber",
      "eth_chainId",
      "eth_getBalance",
      "eth_getLogs",
      "eth_call",
      "eth_getBlockByNumber",
      "eth_getTransactionReceipt",
      "eth_gasPrice"
    ]
  end

  @impl true
  def validate_params("eth_getLogs", params, _transport, ctx) do
    limit = get_adapter_config(ctx, :max_block_range, @default_max_block_range)

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
        max_block_range: "Maximum block range for eth_getLogs (default: #{@default_max_block_range})"
      ]
    }
  end
end
```

3. **Register in adapter registry:**

```elixir
# Update lib/lasso/core/providers/adapter_registry.ex

@provider_type_mapping %{
  # ... existing
  "[provider_name]" => Lasso.RPC.Providers.Adapters.[ProviderName]
}
```

### Phase 4: Configuration Update

**Generate configuration** for chains.yml:

```yaml
# Add to config/chains.yml

ethereum:
  chain_id: 1
  providers:
    # ... existing providers
    - id: "[provider_name]_ethereum"
      name: "[Provider Display Name]"
      url: "[http_url]"
      ws_url: "[ws_url]"  # Optional
      type: "[public/private]"
      priority: [5-8]
      adapter_config:
        max_block_range: [value]  # If custom adapter
```

**If API key required**, document environment variable:

```markdown
## Environment Variables

Add to your `.env` file or deployment config:

```bash
export [PROVIDER]_API_KEY="your-api-key-here"
```

Then update the URL in chains.yml:
```yaml
url: "https://[provider-endpoint]/${[PROVIDER]_API_KEY}"
```
```

### Phase 5: Test Creation

**Generate adapter tests** (if custom adapter):

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

    test "rejects unsupported methods" do
      refute [ProviderName].supports_method?("eth_sendRawTransaction", :http, %{})
    end
  end

  describe "validate_params/4" do
    test "accepts eth_getLogs within block range limit" do
      params = [%{"fromBlock" => "0x1", "toBlock" => "0x64"}]
      assert :ok = [ProviderName].validate_params("eth_getLogs", params, :http, %{})
    end

    test "rejects eth_getLogs exceeding block range limit" do
      # Range: [calculated to exceed default]
      params = [%{"fromBlock" => "0x1", "toBlock" => "[hex_above_limit]"}]

      assert {:error, {:param_limit, message}} =
        [ProviderName].validate_params("eth_getLogs", params, :http, %{})

      assert message =~ "max [limit] block range"
    end

    test "respects adapter_config overrides" do
      config = %{adapter_config: %{max_block_range: 500}}
      ctx = %{provider_config: config}

      # Should accept 450 blocks with limit of 500
      params = [%{"fromBlock" => "0x1", "toBlock" => "0x1c2"}]
      assert :ok = [ProviderName].validate_params("eth_getLogs", params, :http, ctx)
    end
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

**Generate integration test:**

```elixir
# test/integration/providers/[provider_name]_integration_test.exs

defmodule Lasso.Integration.Providers.[ProviderName]IntegrationTest do
  use Lasso.IntegrationCase, async: false

  @moduletag :integration
  @moduletag :skip  # Remove after configuring provider

  describe "[Provider Name] integration" do
    test "successfully routes request to [provider_name]" do
      # Setup
      {:ok, _} = start_provider("[provider_name]_ethereum")

      # Execute
      {:ok, result} = make_rpc_request("ethereum", "eth_blockNumber", [])

      # Verify
      assert is_binary(result)
      assert String.starts_with?(result, "0x")
    end

    test "handles provider-specific error cases" do
      {:ok, _} = start_provider("[provider_name]_ethereum")

      # Test with known limitation
      params = [%{
        "fromBlock" => "0x1",
        "toBlock" => "[hex_exceeding_limit]"
      }]

      assert {:error, reason} = make_rpc_request("ethereum", "eth_getLogs", params)
      assert reason =~ "block range" or reason =~ "param_limit"
    end
  end
end
```

### Phase 6: Validation & Testing

**Run validation checks in order:**

```bash
# 1. Compile
mix compile
```

**Report:** Compilation status, any warnings

```bash
# 2. Run adapter tests
mix test test/lasso/core/providers/adapters/[provider_name]_test.exs
```

**Report:** Test results, any failures

```bash
# 3. Run integration test (if provider configured)
mix test test/integration/providers/[provider_name]_integration_test.exs
```

**Report:** Whether provider is configured and working

**4. Manual smoke test** (if user has API key configured):

```bash
curl -X POST http://localhost:4000/rpc/provider/[provider_name]_ethereum/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

**Report:** Response and latency

**5. Dashboard check:**
- Start server: `mix phx.server`
- Navigate to: http://localhost:4000/metrics/ethereum
- Verify provider appears in leaderboard

### Phase 7: Documentation Update

**Generate documentation updates:**

1. **README.md** - Add provider to list
2. **Configuration comments** - Add to chains.yml
3. **Adapter documentation** - Document limitations

**Example README update:**

```markdown
## Supported Providers

Lasso RPC currently supports:

- Alchemy
- Cloudflare
- LlamaRPC
- PublicNode
- Merkle
- [Provider Name] ← NEW

### Provider-Specific Configuration

**[Provider Name]:**
- Block range limit: [value] blocks
- Archive support: [Yes/No]
- API key required: [Yes/No]
```

## Completion Checklist

Generate interactive checklist:

```
PROVIDER INTEGRATION CHECKLIST
===============================

Provider: [Name]
Chains: ethereum, base

 [x] Information gathered
 [x] Adapter strategy determined (Custom adapter)
 [x] Adapter created: lib/lasso/core/providers/adapters/[name].ex
 [x] Adapter registered in adapter_registry.ex
 [x] Configuration added to chains.yml
 [ ] Environment variables documented (if needed)
 [x] Adapter tests created (8 tests)
 [x] Integration tests created
 [x] Compilation: PASS
 [x] Adapter tests: 8/8 PASS
 [ ] Integration tests: SKIPPED (needs API key)
 [ ] Manual smoke test: TODO
 [ ] Dashboard verification: TODO
 [ ] Documentation updated: TODO

NEXT STEPS:
1. Add API key to environment: export [PROVIDER]_API_KEY="..."
2. Remove :skip tag from integration test
3. Run manual smoke test
4. Verify in dashboard
5. Update README.md
6. Commit changes

Would you like me to help with any of these next steps?
```

## Output Format

Provide clear, phased progress reports:

```
🔌 PROVIDER INTEGRATION: [Provider Name]
========================================

PHASE 1: INFORMATION GATHERING ✅
  Name: [Provider Name]
  Type: Public
  HTTP: https://[endpoint]
  WS: wss://[ws-endpoint]
  Limitations:
    - Block range: 100 blocks
    - Rate limit: 300 req/s

PHASE 2: ADAPTER STRATEGY ✅
  Decision: Custom adapter needed
  Reasoning: Block range validation required
  Template: Alchemy-based

PHASE 3: ADAPTER CREATION ✅
  Created: lib/lasso/core/providers/adapters/[name].ex (127 lines)
  Registered: adapter_registry.ex updated
  Features:
    - Block range validation (max 100)
    - Configurable via adapter_config
    - Telemetry integration

PHASE 4: CONFIGURATION ✅
  Updated: config/chains.yml
  Chains: ethereum, base
  Priority: 6

PHASE 5: TEST CREATION ✅
  Adapter tests: test/lasso/core/providers/adapters/[name]_test.exs
  Integration tests: test/integration/providers/[name]_integration_test.exs
  Coverage: 8 adapter tests, 2 integration tests

PHASE 6: VALIDATION ⏳
  ✅ Compilation: PASS (0 warnings)
  ✅ Adapter Tests: 8/8 PASS
  ⚠️  Integration Tests: SKIPPED (needs configuration)
  ⏳ Manual Smoke Test: Pending user setup
  ⏳ Dashboard: Pending server start

PHASE 7: DOCUMENTATION ⏳
  Pending: README update, config comments

========================================
STATUS: Provider integration 80% complete

NEXT ACTIONS (User):
1. Configure API key (if needed)
2. Test manually
3. Verify in dashboard
4. Review and approve changes

Ready to proceed with testing?
```

## Resources

- `resources/adapter-template.ex` - Adapter code template
- `resources/test-template.exs` - Test code template
- `resources/integration-checklist.md` - Detailed integration steps
- `/add-provider` slash command - Manual integration guide

## Integration with Other Features

**Compose with:**
- `/add-provider` - Use as reference for steps
- `/health-check` - Run after integration
- `/smoke-test` - Validate provider works
- `elixir-quality` skill - Ensure no warnings introduced
- `elixir-phoenix-expert` subagent - For complex issues

**Hand off to other skills:**
- After integration complete → `smoke-test-runner` for validation
- If compilation issues → `elixir-quality` for fixes
- If architectural questions → `elixir-phoenix-expert` for guidance

## Success Criteria

- Adapter created and registered (if needed)
- Configuration added for all requested chains
- Tests created and passing
- Compilation clean (zero warnings)
- Documentation updated
- User can make requests through new provider
- Provider visible in dashboard

## Notes

- Be interactive - ask questions rather than assume
- Provide code that's ready to use, not pseudo-code
- Run validation steps automatically where possible
- Give clear next steps for manual tasks
- Make integration feel guided, not overwhelming
