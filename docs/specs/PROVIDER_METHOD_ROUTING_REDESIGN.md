# Provider Method Routing Redesign Specification

**Status**: Draft
**Version**: 1.0
**Date**: 2025-11-17
**Authors**: Engineering Team

## Executive Summary

This specification defines a redesigned system for automatic provider routing based on RPC method support capabilities. The goal is to aggregate multiple Ethereum RPC providers into a unified superset API while efficiently routing requests to capable providers without runtime overhead.

**Key Principles**:
- Static specifications as the authoritative source
- Enhanced error classification for capability violations
- Development tooling for adapter creation
- No runtime probing or discovery (operational simplicity)
- Fail-safe degradation with explicit defaults

---

## Table of Contents

1. [Background & Motivation](#background--motivation)
2. [Architecture Overview](#architecture-overview)
3. [Method Categorization](#method-categorization)
4. [Adapter Specification System](#adapter-specification-system)
5. [Error Classification Enhancement](#error-classification-enhancement)
6. [Development Tooling](#development-tooling)
7. [Implementation Plan](#implementation-plan)
8. [Testing Strategy](#testing-strategy)
9. [Operational Considerations](#operational-considerations)
10. [Appendices](#appendices)

---

## Background & Motivation

### Current State

Lasso currently implements a two-phase validation system:
1. **Phase 1**: Fast method-level filtering via `supports_method?/3`
2. **Phase 2**: Parameter validation via `validate_params/4`

Each adapter manually implements method support checks, leading to:
- Inconsistent method categorization across adapters
- Incomplete coverage of standard Ethereum JSON-RPC methods
- Difficulty onboarding new providers
- Limited visibility into provider capabilities

### Problems to Solve

1. **Scalability**: Adding new providers requires manual capability documentation
2. **Accuracy**: No systematic way to verify adapter declarations match reality
3. **Maintenance**: Provider API changes require code updates
4. **Visibility**: No centralized view of method support across providers

### Design Goals

- ✅ Aggregate providers into superset RPC API
- ✅ Route requests to capable providers efficiently
- ✅ Scale to 50+ providers across 10+ chains
- ✅ Avoid hardcoding full method lists per adapter
- ✅ Provide development tooling for adapter creation
- ✅ Maintain <20μs P99 filtering overhead
- ❌ No runtime discovery or probing (operational complexity)
- ❌ No startup delays or liveness probe failures

---

## Architecture Overview

### Three-Layer Design

```
┌─────────────────────────────────────────────────────────┐
│ Layer 1: Method Registry (Canonical Reference)          │
│ - Standard Ethereum JSON-RPC method definitions          │
│ - Categorization by support patterns                     │
│ - Source of truth for method taxonomy                    │
└─────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────┐
│ Layer 2: Adapter Specifications (Provider Capabilities) │
│ - Each adapter declares unsupported categories/methods   │
│ - Defines parameter constraints (block ranges, etc.)     │
│ - Explicit metadata (tier, limitations, last verified)   │
└─────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────┐
│ Layer 3: Error Classification (Runtime Feedback)        │
│ - Enhanced patterns for capability violations            │
│ - Provider-specific error code mapping                   │
│ - Telemetry for adapter accuracy monitoring              │
└─────────────────────────────────────────────────────────┘
```

### Request Flow

```elixir
# Request arrives
Request → AdapterFilter.filter_channels(channels, method)
  │
  ├─→ For each channel:
  │    ├─→ Get adapter for provider.type
  │    ├─→ Call adapter.supports_method?(method, transport, context)
  │    │    ├─→ Check method category
  │    │    ├─→ Check unsupported_methods list
  │    │    └─→ Return :ok | {:error, :method_unsupported}
  │    └─→ Filter into [capable] or [filtered]
  │
  └─→ Return {capable_channels, filtered_channels}
       │
       ▼
  RequestPipeline.execute(method, params, channels)
  │
  ├─→ Select best channel (latency, cost, health)
  ├─→ Call adapter.validate_params(method, params, transport, ctx)
  │    └─→ Validate block ranges, address counts, etc.
  ├─→ Forward request to provider
  │
  └─→ On error:
       ├─→ Call adapter.classify_error(code, message)
       ├─→ Emit telemetry for capability_violation
       └─→ Failover to next channel if retriable
```

### Data Flow

```
Development Time:
1. Developer runs mix task: probe_provider
2. Receives method support report
3. Implements adapter with unsupported_methods list
4. Commits adapter to codebase

Runtime:
1. Request filtered by adapter.supports_method?
2. Parameter validation by adapter.validate_params
3. Error classification by adapter.classify_error
4. Telemetry emitted for monitoring
```

---

## Method Categorization

### Canonical Method Registry

**File**: `lib/lasso/rpc/method_registry.ex`

Methods are categorized by support patterns across providers:

```elixir
defmodule Lasso.RPC.MethodRegistry do
  @moduledoc """
  Canonical registry of Ethereum JSON-RPC methods categorized by
  support patterns across hosted providers.

  Categories reflect real-world availability:
  - :core - Universal support (99%+ providers)
  - :state - Common support (90%+ providers)
  - :filters - Restricted support (60% providers, often limited)
  - :debug/:trace - Rare support (<10% providers)
  - :local_only - Never supported on hosted providers
  """

  @standard_methods %{
    # Universal support - all hosted providers
    core: [
      "eth_blockNumber",
      "eth_chainId",
      "eth_gasPrice",
      "eth_getBalance",
      "eth_getCode",
      "eth_getTransactionByHash",
      "eth_getTransactionReceipt",
      "eth_getBlockByNumber",
      "eth_getBlockByHash",
      "eth_getBlockTransactionCountByHash",
      "eth_getBlockTransactionCountByNumber",
      "eth_getUncleCountByBlockHash",
      "eth_getUncleCountByBlockNumber",
      "eth_getUncleByBlockHashAndIndex",
      "eth_getUncleByBlockNumberAndIndex",
      "eth_getTransactionByBlockHashAndIndex",
      "eth_getTransactionByBlockNumberAndIndex"
    ],

    # Common support - may have archive restrictions
    state: [
      "eth_call",
      "eth_estimateGas",
      "eth_getStorageAt",
      "eth_getTransactionCount",
      "eth_getProof"  # EIP-1186 - archive nodes
    ],

    # Network/utility methods
    network: [
      "net_version",
      "net_listening",
      "net_peerCount",
      "web3_clientVersion",
      "web3_sha3",
      "eth_protocolVersion",
      "eth_syncing"
    ],

    # EIP-1559 methods (post-London fork)
    eip1559: [
      "eth_maxPriorityFeePerGas",
      "eth_feeHistory"
    ],

    # EIP-4844 methods (post-Dencun, blob transactions)
    eip4844: [
      "eth_getBlobBaseFee"
    ],

    # Mempool/pending transaction methods
    mempool: [
      "eth_sendRawTransaction"
    ],

    # Filter/log methods - HIGHEST FAILURE RATE
    # Most providers restrict block ranges, address counts
    filters: [
      "eth_getLogs",
      "eth_newFilter",
      "eth_getFilterChanges",
      "eth_getFilterLogs",
      "eth_uninstallFilter",
      "eth_newBlockFilter",
      "eth_newPendingTransactionFilter"
    ],

    # WebSocket subscriptions (transport-dependent)
    subscriptions: [
      "eth_subscribe",
      "eth_unsubscribe"
    ],

    # Batch methods (provider-specific)
    batch: [
      "eth_getBlockReceipts"  # Parity/Erigon/Alchemy enhanced
    ],

    # Debug methods (rarely supported, requires debug flag)
    debug: [
      "debug_traceTransaction",
      "debug_traceBlockByNumber",
      "debug_traceBlockByHash",
      "debug_traceCall",
      "debug_getBadBlocks",
      "debug_storageRangeAt",
      "debug_getModifiedAccountsByNumber",
      "debug_getModifiedAccountsByHash"
    ],

    # Trace methods (Parity/Erigon - rare)
    trace: [
      "trace_block",
      "trace_transaction",
      "trace_call",
      "trace_callMany",
      "trace_rawTransaction",
      "trace_replayBlockTransactions",
      "trace_replayTransaction",
      "trace_filter",
      "trace_get"
    ],

    # Never available on hosted providers
    local_only: [
      "eth_accounts",
      "eth_sign",
      "eth_signTransaction",
      "eth_sendTransaction",
      "eth_coinbase",
      "eth_mining",
      "eth_hashrate",
      "eth_getWork",
      "eth_submitWork",
      "eth_submitHashrate"
    ],

    # TxPool inspection (rarely available)
    txpool: [
      "txpool_status",
      "txpool_content",
      "txpool_inspect"
    ]
  }

  @doc "Returns all standard method categories"
  def categories, do: @standard_methods

  @doc "Returns flattened list of all standard methods"
  def all_methods do
    @standard_methods
    |> Map.values()
    |> List.flatten()
    |> Enum.uniq()
  end

  @doc "Returns methods in a specific category"
  def category_methods(category), do: Map.get(@standard_methods, category, [])

  @doc "Returns the category for a given method"
  def method_category(method) do
    Enum.find_value(@standard_methods, :unknown, fn {cat, methods} ->
      if method in methods, do: cat
    end)
  end

  @doc """
  Returns default support assumption for unknown methods.

  Conservative assumptions:
  - Standard methods (core, state, network): Assume supported
  - Experimental/new methods (eip4844): Assume unsupported
  - Archive methods (debug, trace): Assume unsupported
  - Deprecated methods: Assume unsupported
  """
  def default_support_assumption(method) do
    case method_category(method) do
      cat when cat in [:core, :state, :network, :eip1559, :mempool] -> true
      cat when cat in [:debug, :trace, :local_only, :txpool] -> false
      :eip4844 -> false  # New, conservative
      :unknown -> false  # Conservative for unknown
    end
  end
end
```

### Category Support Matrix

| Category | Support % | Restrictions | Example Providers |
|----------|-----------|--------------|-------------------|
| `core` | 99%+ | None | All providers |
| `state` | 90%+ | Archive depth limits | Most providers |
| `network` | 95%+ | None | Most providers |
| `eip1559` | 95%+ | Post-London only | Most providers |
| `eip4844` | 60%+ | Post-Dencun only | Alchemy, Infura, QuickNode |
| `mempool` | 100% | Rate limits | All providers |
| `filters` | 60%+ | Block range limits, address count limits | Alchemy (2K blocks), PublicNode (128 blocks), Cloudflare (blocked) |
| `subscriptions` | 95%+ | WebSocket only | Most providers |
| `batch` | 30%+ | Provider-specific | Alchemy, Erigon, Parity |
| `debug` | 5%+ | Paid tier, archive | QuickNode (paid), Alchemy (growth+) |
| `trace` | 5%+ | Paid tier, archive | QuickNode (paid), GetBlock |
| `local_only` | 0% | Never on hosted | None |
| `txpool` | 1%+ | Rarely available | Private nodes only |

---

## Adapter Specification System

### Enhanced ProviderAdapter Behavior

**File**: `lib/lasso/core/providers/provider_adapter.ex`

```elixir
defmodule Lasso.RPC.ProviderAdapter do
  @moduledoc """
  Behaviour for provider-specific RPC adapters.

  Adapters declare provider capabilities and parameter constraints,
  enabling efficient method routing and request validation.
  """

  # ... existing callbacks (supports_method?, validate_params, etc.) ...

  @doc """
  Returns metadata about the provider adapter.

  ## Fields:
  - `:type` - Provider type (:paid | :public | :dedicated)
  - `:tier` - Service tier (:free | :paid | :enterprise)
  - `:known_limitations` - List of human-readable limitations
  - `:unsupported_categories` - Method categories not supported
  - `:unsupported_methods` - Specific methods not supported
  - `:conditional_support` - Methods with parameter restrictions
  - `:last_verified` - Date capabilities were last verified

  ## Example:
      def metadata do
        %{
          type: :public,
          tier: :free,
          known_limitations: [
            "eth_getLogs limited to 128 blocks",
            "No archive data (recent blocks only)",
            "Aggressive rate limiting on free tier"
          ],
          unsupported_categories: [:debug, :trace, :txpool],
          unsupported_methods: ["eth_getLogs", "eth_newFilter"],
          conditional_support: %{
            "eth_call" => "Recent blocks only (no deep archive)"
          },
          last_verified: ~D[2025-01-17]
        }
      end
  """
  @callback metadata() :: map()

  @optional_callbacks [metadata: 0]
end
```

### Adapter Implementation Pattern

**Example**: `lib/lasso/core/providers/adapters/public_node.ex`

```elixir
defmodule Lasso.RPC.Adapters.PublicNode do
  @behaviour Lasso.RPC.ProviderAdapter

  alias Lasso.RPC.{MethodRegistry, Adapters.Generic}
  alias Lasso.Core.Providers.AdapterHelpers

  # ============================================
  # Phase 1: Method-Level Filtering (Fast)
  # ============================================

  @impl true
  def supports_method?(method, _transport, _context) do
    category = MethodRegistry.method_category(method)

    cond do
      # Unsupported categories
      category in [:debug, :trace, :txpool, :local_only] ->
        {:error, :method_unsupported}

      # Specific unsupported methods
      method in ["eth_getLogs", "eth_newFilter", "eth_getFilterChanges"] ->
        {:error, :method_unsupported}

      # Subscriptions require WebSocket (handled by TransportPolicy)
      category == :subscriptions ->
        :ok

      # All other standard methods supported
      true ->
        :ok
    end
  end

  # ============================================
  # Phase 2: Parameter Validation (Slow)
  # ============================================

  @impl true
  def validate_params("eth_call", params, _transport, context) do
    # PublicNode has limited archive depth
    validate_archive_depth(params, context, max_depth: 1000)
  end

  def validate_params("eth_getBalance", params, _transport, context) do
    validate_archive_depth(params, context, max_depth: 1000)
  end

  def validate_params("eth_getCode", params, _transport, context) do
    validate_archive_depth(params, context, max_depth: 1000)
  end

  def validate_params(_method, _params, _transport, _context) do
    :ok
  end

  # ============================================
  # Error Classification
  # ============================================

  @impl true
  def classify_error(_code, message) when is_binary(message) do
    cond do
      String.contains?(message, "This range of parameters is not supported") ->
        {:ok, :capability_violation}

      String.contains?(message, "pruned") ->
        {:ok, :requires_archival}

      true ->
        :default
    end
  end

  def classify_error(_code, _message), do: :default

  # ============================================
  # Normalization (Delegate to Generic)
  # ============================================

  @impl true
  defdelegate normalize_request(req, ctx), to: Generic

  @impl true
  defdelegate normalize_response(resp, ctx), to: Generic

  @impl true
  defdelegate normalize_error(err, ctx), to: Generic

  @impl true
  defdelegate headers(ctx), to: Generic

  # ============================================
  # Metadata
  # ============================================

  @impl true
  def metadata do
    %{
      type: :public,
      tier: :free,
      known_limitations: [
        "No eth_getLogs support",
        "No filter methods (eth_newFilter, etc.)",
        "Limited archive depth (~1000 blocks)",
        "No debug/trace methods",
        "Aggressive rate limiting"
      ],
      unsupported_categories: [:debug, :trace, :filters, :txpool, :local_only],
      unsupported_methods: ["eth_getLogs", "eth_newFilter", "eth_getFilterChanges",
                            "eth_getFilterLogs", "eth_uninstallFilter"],
      conditional_support: %{
        "eth_call" => "Recent blocks only (~1000 block depth)",
        "eth_getBalance" => "Recent blocks only (~1000 block depth)",
        "eth_getCode" => "Recent blocks only (~1000 block depth)"
      },
      last_verified: ~D[2025-01-17]
    }
  end

  # ============================================
  # Private Helpers
  # ============================================

  defp validate_archive_depth(params, context, opts) do
    max_depth = Keyword.fetch!(opts, :max_depth)
    block_param = List.last(params)

    case parse_block_param(block_param) do
      {:ok, :latest} ->
        :ok

      {:ok, block_num} when is_integer(block_num) ->
        current_block = Map.get(context, :current_block, :latest)

        if current_block == :latest do
          :ok  # Can't validate without current block
        else
          age = current_block - block_num

          if age <= max_depth do
            :ok
          else
            {:error, {:requires_archival,
              "Block is #{age} blocks old, PublicNode max: #{max_depth}"}}
          end
        end

      _ ->
        :ok  # Can't parse, let provider decide
    end
  end

  defp parse_block_param("latest"), do: {:ok, :latest}
  defp parse_block_param("earliest"), do: {:ok, 0}
  defp parse_block_param("pending"), do: {:ok, :latest}

  defp parse_block_param("0x" <> hex) do
    case Integer.parse(hex, 16) do
      {num, ""} -> {:ok, num}
      _ -> {:error, :invalid_hex}
    end
  end

  defp parse_block_param(_), do: {:error, :invalid_format}
end
```

### Adapter Templates by Provider Type

#### Template 1: Restrictive Public Provider

```elixir
# Use for: Cloudflare, PublicNode, LlamaRPC
def supports_method?(method, _t, _c) do
  category = MethodRegistry.method_category(method)

  case category do
    cat when cat in [:debug, :trace, :filters, :txpool] ->
      {:error, :method_unsupported}
    _ ->
      :ok
  end
end
```

#### Template 2: Permissive Paid Provider

```elixir
# Use for: Alchemy, Infura, QuickNode (standard tier)
def supports_method?(method, _t, _c) do
  category = MethodRegistry.method_category(method)

  case category do
    cat when cat in [:local_only] ->
      {:error, :method_unsupported}
    _ ->
      :ok
  end
end

def validate_params("eth_getLogs", [params], transport, ctx) do
  max_range = AdapterHelpers.get_adapter_config(ctx, :max_block_range, 2000)
  validate_block_range(params, max_range)
end
```

#### Template 3: Archive Node Provider

```elixir
# Use for: QuickNode (archive), Alchemy (growth+), GetBlock
def supports_method?(method, _t, _c) do
  category = MethodRegistry.method_category(method)

  case category do
    :local_only -> {:error, :method_unsupported}
    _ -> :ok  # Archive nodes support everything except local
  end
end
```

---

## Error Classification Enhancement

### Enhanced ErrorNormalizer

**File**: `lib/lasso/core/support/error_normalizer.ex` (or similar)

```elixir
defmodule Lasso.Core.Support.ErrorClassifier do
  @moduledoc """
  Classifies RPC errors into actionable categories for failover logic.

  Categories:
  - :method_unsupported - Method doesn't exist (-32601)
  - :capability_violation - Method exists but params exceed provider limits
  - :requires_archival - Historical data not available (pruned)
  - :rate_limit - Rate limit exceeded
  - :auth_error - Authentication/authorization failure
  - :invalid_params - Client sent malformed request (-32602)
  - :internal_error - Provider internal error (retriable)
  """

  # Provider-specific error codes for capability violations
  @capability_violation_codes [
    -32005,  # Geth: limit exceeded
    -32046,  # Cloudflare: capacity limit
    30,      # DRPC: free tier timeout
    35,      # DRPC: capability violation
    -32701   # PublicNode: parameter range violation
  ]

  # Rate limit error codes
  @rate_limit_codes [
    429,     # HTTP 429
    -32005,  # Geth rate limit (overlaps with capability)
    -32016   # CloudFlare rate limit
  ]

  # Patterns for capability violations
  @capability_patterns [
    # Block range violations (most common)
    ~r/block range.*exceeded/i,
    ~r/range too large/i,
    ~r/range.*not supported/i,
    ~r/this range of parameters is not supported/i,  # PublicNode
    ~r/block range is too large/i,

    # Result count violations
    ~r/too many (logs|results)/i,
    ~r/query returned more than \d+/i,
    ~r/result limit exceeded/i,
    ~r/exceeds maximum/i,
    ~r/result set has \d+ rows/i,

    # Archive/historical restrictions
    ~r/archival.*not available/i,
    ~r/historical data not supported/i,
    ~r/pruned/i,
    ~r/(require|need).*archive/i,
    ~r/missing trie node/i,  # Geth pruned data

    # Method unavailability
    ~r/not (supported|available|enabled)/i,
    ~r/does not support/i,
    ~r/method.*unavailable/i,

    # Tier/plan restrictions
    ~r/upgrade.*plan/i,
    ~r/paid tier/i,
    ~r/timeout on the free tier/i,  # DRPC
    ~r/feature not enabled/i
  ]

  # Patterns for rate limiting
  @rate_limit_patterns [
    ~r/rate limit/i,
    ~r/too many requests/i,
    ~r/capacity/i,
    ~r/throttle/i,
    ~r/daily request count exceeded/i,
    ~r/compute units/i  # Alchemy
  ]

  @doc """
  Classifies an error into a category and determines if retriable.

  Returns: `{category :: atom(), retriable :: boolean()}`
  """
  def classify(error_code, error_message, provider_type \\ :generic)

  # Method not found - high confidence
  def classify(-32601, _message, _provider) do
    {:method_unsupported, false}
  end

  # Invalid params - client error
  def classify(-32602, _message, _provider) do
    {:invalid_params, false}
  end

  # Capability violation codes
  def classify(code, message, provider)
      when code in @capability_violation_codes do
    # Some codes overlap (e.g., -32005 can be rate limit or capability)
    # Use message to disambiguate
    if matches_any?(@rate_limit_patterns, message) do
      {:rate_limit, true}
    else
      {:capability_violation, false}
    end
  end

  # Rate limit codes
  def classify(code, _message, _provider) when code in @rate_limit_codes do
    {:rate_limit, true}
  end

  # Message-based classification
  def classify(_code, message, provider) when is_binary(message) do
    message_lower = String.downcase(message)

    cond do
      matches_any?(@capability_patterns, message_lower) ->
        {:capability_violation, false}

      matches_any?(@rate_limit_patterns, message_lower) ->
        {:rate_limit, true}

      String.contains?(message_lower, "unauthorized") or
      String.contains?(message_lower, "forbidden") ->
        {:auth_error, false}

      true ->
        # Delegate to adapter-specific classification
        case provider_classify(provider, message_lower) do
          {:ok, category} -> {category, retriable?(category)}
          :default -> {:internal_error, true}
        end
    end
  end

  # Fallback
  def classify(_code, _message, _provider) do
    {:internal_error, true}
  end

  # ============================================
  # Private Helpers
  # ============================================

  defp matches_any?(patterns, message) do
    Enum.any?(patterns, &Regex.match?(&1, message))
  end

  defp retriable?(category) do
    case category do
      :rate_limit -> true
      :internal_error -> true
      :timeout -> true
      _ -> false
    end
  end

  defp provider_classify(provider_type, message) do
    case Lasso.Core.Providers.AdapterRegistry.get_adapter(provider_type) do
      {:ok, adapter} ->
        if function_exported?(adapter, :classify_error, 2) do
          adapter.classify_error(nil, message)
        else
          :default
        end

      _ ->
        :default
    end
  end
end
```

### Error Classification Usage

```elixir
# In RequestPipeline after receiving provider error
case make_request(channel, method, params) do
  {:error, %{code: code, message: message}} ->
    {category, retriable?} = ErrorClassifier.classify(
      code,
      message,
      channel.provider.type
    )

    # Emit telemetry
    :telemetry.execute(
      [:lasso, :request, :error],
      %{count: 1},
      %{
        method: method,
        provider: channel.provider.id,
        category: category,
        retriable: retriable?
      }
    )

    # Decide on failover
    if retriable? and attempts < max_attempts do
      failover_to_next_channel(channels, method, params)
    else
      {:error, %{category: category, original_error: %{code: code, message: message}}}
    end
end
```

---

## Development Tooling

### Mix Task: Provider Method Discovery

**Purpose**: Aid manual adapter creation by probing provider capabilities during development.

**File**: `lib/mix/tasks/lasso/probe_provider.ex`

```elixir
defmodule Mix.Tasks.Lasso.ProbeProvider do
  use Mix.Task
  require Logger

  @shortdoc "Probe an RPC provider to discover supported methods"

  @moduledoc """
  Probes an Ethereum RPC provider to discover which methods are supported.

  This is a **development tool** for creating adapter implementations.
  It is NOT used at runtime.

  ## Usage

      mix lasso.probe_provider <provider_url> [options]

  ## Options

    * `--level <level>` - Probe level (default: standard)
      - critical: Core methods only (~10 methods)
      - standard: Common methods (~25 methods)
      - full: All standard methods (~70 methods)

    * `--timeout <ms>` - Request timeout in milliseconds (default: 3000)

    * `--output <format>` - Output format (default: table)
      - table: Human-readable table
      - json: JSON output
      - adapter: Generate adapter skeleton

    * `--chain <name>` - Chain name for context (default: ethereum)

    * `--concurrent <n>` - Concurrent requests (default: 5)

  ## Examples

      # Probe Alchemy with standard methods
      mix lasso.probe_provider https://eth-mainnet.alchemyapi.io/v2/KEY

      # Probe PublicNode with all methods, JSON output
      mix lasso.probe_provider https://ethereum.publicnode.com \\
        --level full \\
        --output json

      # Generate adapter skeleton from probe results
      mix lasso.probe_provider https://api.mycustomprovider.io \\
        --level full \\
        --output adapter \\
        --chain ethereum

  ## Output

  The task will probe each method and report:
  - ✅ Supported: Method returned valid response
  - ❌ Unsupported: Method returned -32601 (method not found)
  - ⚠️  Unknown: Method returned other error or timed out

  Results include:
  - Support status for each method
  - Response times
  - Error details
  - Recommended adapter configuration
  """

  @levels %{
    critical: [:core],
    standard: [:core, :state, :network, :eip1559, :mempool],
    full: [:core, :state, :network, :eip1559, :eip4844, :mempool,
           :filters, :subscriptions, :batch, :debug, :trace]
  }

  @impl Mix.Task
  def run(args) do
    {opts, args, _} = OptionParser.parse(args,
      strict: [
        level: :string,
        timeout: :integer,
        output: :string,
        chain: :string,
        concurrent: :integer
      ],
      aliases: [l: :level, t: :timeout, o: :output, c: :chain]
    )

    case args do
      [provider_url | _] ->
        probe_provider(provider_url, opts)

      [] ->
        Mix.shell().error("Usage: mix lasso.probe_provider <provider_url> [options]")
        Mix.shell().info("\nRun `mix help lasso.probe_provider` for details")
    end
  end

  defp probe_provider(url, opts) do
    # Start required applications
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:jason)

    level = Keyword.get(opts, :level, "standard") |> String.to_atom()
    timeout = Keyword.get(opts, :timeout, 3000)
    output_format = Keyword.get(opts, :output, "table") |> String.to_atom()
    chain = Keyword.get(opts, :chain, "ethereum")
    concurrent = Keyword.get(opts, :concurrent, 5)

    Mix.shell().info("🔍 Probing provider: #{url}")
    Mix.shell().info("📊 Level: #{level}")
    Mix.shell().info("⏱️  Timeout: #{timeout}ms")
    Mix.shell().info("")

    # Get methods to probe
    methods = get_probe_methods(level)

    Mix.shell().info("Testing #{length(methods)} methods...\n")

    # Probe concurrently
    results =
      methods
      |> Task.async_stream(
        fn method -> probe_method(url, method, timeout) end,
        max_concurrency: concurrent,
        timeout: timeout + 1000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, :timeout} -> {:timeout, nil, timeout}
      end)
      |> Enum.zip(methods)
      |> Enum.map(fn {result, method} ->
        Map.put(result, :method, method)
      end)

    # Output results
    case output_format do
      :table -> output_table(results)
      :json -> output_json(results)
      :adapter -> output_adapter_skeleton(results, url, chain)
      _ -> Mix.shell().error("Unknown output format: #{output_format}")
    end
  end

  defp get_probe_methods(level) do
    categories = Map.get(@levels, level, @levels.standard)

    categories
    |> Enum.flat_map(&Lasso.RPC.MethodRegistry.category_methods/1)
  end

  defp probe_method(url, method, timeout) do
    params = minimal_params_for(method)

    payload = %{
      jsonrpc: "2.0",
      id: 1,
      method: method,
      params: params
    }

    start_time = System.monotonic_time(:millisecond)

    result =
      HTTPoison.post(
        url,
        Jason.encode!(payload),
        [{"Content-Type", "application/json"}],
        recv_timeout: timeout
      )

    duration = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, %{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"error" => %{"code" => -32601}}} ->
            %{status: :unsupported, duration: duration, error: "Method not found"}

          {:ok, %{"error" => %{"code" => -32602}}} ->
            %{status: :supported, duration: duration, note: "Invalid params (method exists)"}

          {:ok, %{"result" => _}} ->
            %{status: :supported, duration: duration}

          {:ok, %{"error" => error}} ->
            %{status: :unknown, duration: duration, error: error}

          {:error, _} ->
            %{status: :unknown, duration: duration, error: "Invalid JSON response"}
        end

      {:ok, %{status_code: status}} ->
        %{status: :unknown, duration: duration, error: "HTTP #{status}"}

      {:error, %{reason: reason}} ->
        %{status: :unknown, duration: duration, error: inspect(reason)}
    end
  end

  defp minimal_params_for("eth_blockNumber"), do: []
  defp minimal_params_for("eth_chainId"), do: []
  defp minimal_params_for("eth_gasPrice"), do: []
  defp minimal_params_for("eth_call"), do: [
    %{to: "0x0000000000000000000000000000000000000000", data: "0x"},
    "latest"
  ]
  defp minimal_params_for("eth_estimateGas"), do: [
    %{to: "0x0000000000000000000000000000000000000000", data: "0x"}
  ]
  defp minimal_params_for("eth_getBalance"), do: [
    "0x0000000000000000000000000000000000000000",
    "latest"
  ]
  defp minimal_params_for("eth_getCode"), do: [
    "0x0000000000000000000000000000000000000000",
    "latest"
  ]
  defp minimal_params_for("eth_getTransactionCount"), do: [
    "0x0000000000000000000000000000000000000000",
    "latest"
  ]
  defp minimal_params_for("eth_getStorageAt"), do: [
    "0x0000000000000000000000000000000000000000",
    "0x0",
    "latest"
  ]
  defp minimal_params_for("eth_getTransactionByHash"), do: [
    "0x" <> String.duplicate("0", 64)
  ]
  defp minimal_params_for("eth_getTransactionReceipt"), do: [
    "0x" <> String.duplicate("0", 64)
  ]
  defp minimal_params_for("eth_getBlockByNumber"), do: ["latest", false]
  defp minimal_params_for("eth_getBlockByHash"), do: [
    "0x" <> String.duplicate("0", 64),
    false
  ]
  defp minimal_params_for("eth_getLogs"), do: [
    %{fromBlock: "latest", toBlock: "latest"}
  ]
  defp minimal_params_for("eth_newFilter"), do: [
    %{fromBlock: "latest", toBlock: "latest"}
  ]
  defp minimal_params_for("eth_getFilterChanges"), do: ["0x1"]
  defp minimal_params_for("eth_getFilterLogs"), do: ["0x1"]
  defp minimal_params_for("eth_uninstallFilter"), do: ["0x1"]
  defp minimal_params_for("eth_getBlockReceipts"), do: ["latest"]
  defp minimal_params_for("eth_feeHistory"), do: [4, "latest", []]
  defp minimal_params_for("debug_traceTransaction"), do: [
    "0x" <> String.duplicate("0", 64),
    %{}
  ]
  defp minimal_params_for("debug_traceBlockByNumber"), do: ["latest", %{}]
  defp minimal_params_for("trace_block"), do: ["latest"]
  defp minimal_params_for("trace_transaction"), do: [
    "0x" <> String.duplicate("0", 64)
  ]
  defp minimal_params_for(_), do: []

  defp output_table(results) do
    # Group by category
    by_category =
      results
      |> Enum.group_by(fn r ->
        Lasso.RPC.MethodRegistry.method_category(r.method)
      end)

    # Print summary
    supported = Enum.count(results, &(&1.status == :supported))
    unsupported = Enum.count(results, &(&1.status == :unsupported))
    unknown = Enum.count(results, &(&1.status == :unknown))

    Mix.shell().info("=" |> String.duplicate(80))
    Mix.shell().info("SUMMARY")
    Mix.shell().info("=" |> String.duplicate(80))
    Mix.shell().info("✅ Supported:   #{supported}")
    Mix.shell().info("❌ Unsupported: #{unsupported}")
    Mix.shell().info("⚠️  Unknown:     #{unknown}")
    Mix.shell().info("")

    # Print by category
    Enum.each(by_category, fn {category, methods} ->
      Mix.shell().info("#{category |> to_string() |> String.upcase()}")
      Mix.shell().info("-" |> String.duplicate(80))

      Enum.each(methods, fn result ->
        icon = case result.status do
          :supported -> "✅"
          :unsupported -> "❌"
          :unknown -> "⚠️"
          :timeout -> "⏱️"
        end

        duration_str = if result[:duration], do: " (#{result.duration}ms)", else: ""
        error_str = if result[:error], do: " - #{result.error}", else: ""
        note_str = if result[:note], do: " - #{result.note}", else: ""

        Mix.shell().info(
          "  #{icon} #{String.pad_trailing(result.method, 40)} " <>
          "#{duration_str}#{error_str}#{note_str}"
        )
      end)

      Mix.shell().info("")
    end)

    # Recommendations
    Mix.shell().info("=" |> String.duplicate(80))
    Mix.shell().info("RECOMMENDATIONS")
    Mix.shell().info("=" |> String.duplicate(80))

    unsupported_methods =
      results
      |> Enum.filter(&(&1.status == :unsupported))
      |> Enum.map(&(&1.method))

    unsupported_categories =
      unsupported_methods
      |> Enum.map(&Lasso.RPC.MethodRegistry.method_category/1)
      |> Enum.uniq()
      |> Enum.filter(fn cat ->
        category_methods = Lasso.RPC.MethodRegistry.category_methods(cat)
        unsupported_in_cat = Enum.count(category_methods, &(&1 in unsupported_methods))
        # If >80% of category unsupported, recommend blocking whole category
        unsupported_in_cat / length(category_methods) > 0.8
      end)

    if length(unsupported_categories) > 0 do
      Mix.shell().info("Block entire categories:")
      Enum.each(unsupported_categories, fn cat ->
        Mix.shell().info("  - :#{cat}")
      end)
      Mix.shell().info("")
    end

    remaining_unsupported =
      unsupported_methods
      |> Enum.reject(fn method ->
        Lasso.RPC.MethodRegistry.method_category(method) in unsupported_categories
      end)

    if length(remaining_unsupported) > 0 do
      Mix.shell().info("Block specific methods:")
      Enum.each(remaining_unsupported, fn method ->
        Mix.shell().info("  - \"#{method}\"")
      end)
    end
  end

  defp output_json(results) do
    json = Jason.encode!(results, pretty: true)
    Mix.shell().info(json)
  end

  defp output_adapter_skeleton(results, url, chain) do
    # Derive provider name from URL
    provider_name =
      URI.parse(url).host
      |> String.split(".")
      |> Enum.at(-2)
      |> Macro.camelize()

    unsupported_methods =
      results
      |> Enum.filter(&(&1.status == :unsupported))
      |> Enum.map(&(&1.method))

    unsupported_categories =
      unsupported_methods
      |> Enum.map(&Lasso.RPC.MethodRegistry.method_category/1)
      |> Enum.uniq()
      |> Enum.filter(fn cat ->
        category_methods = Lasso.RPC.MethodRegistry.category_methods(cat)
        unsupported_in_cat = Enum.count(category_methods, &(&1 in unsupported_methods))
        unsupported_in_cat / length(category_methods) > 0.8
      end)

    remaining_unsupported =
      unsupported_methods
      |> Enum.reject(fn method ->
        Lasso.RPC.MethodRegistry.method_category(method) in unsupported_categories
      end)

    skeleton = """
    defmodule Lasso.RPC.Adapters.#{provider_name} do
      @moduledoc \"\"\"
      Adapter for #{provider_name} RPC provider.

      Generated from probe results on #{Date.utc_today()}
      Chain: #{chain}
      URL: #{url}
      \"\"\"

      @behaviour Lasso.RPC.ProviderAdapter

      alias Lasso.RPC.{MethodRegistry, Adapters.Generic}

      @impl true
      def supports_method?(method, _transport, _context) do
        category = MethodRegistry.method_category(method)

        cond do
          # Unsupported categories
          category in #{inspect(unsupported_categories)} ->
            {:error, :method_unsupported}

          # Unsupported methods
          method in #{inspect(remaining_unsupported)} ->
            {:error, :method_unsupported}

          # All other methods supported
          true ->
            :ok
        end
      end

      @impl true
      def validate_params(_method, _params, _transport, _context) do
        # TODO: Add parameter validation if needed
        # Example: eth_getLogs block range limits
        :ok
      end

      @impl true
      def classify_error(_code, _message) do
        # TODO: Add provider-specific error classification
        :default
      end

      @impl true
      defdelegate normalize_request(req, ctx), to: Generic

      @impl true
      defdelegate normalize_response(resp, ctx), to: Generic

      @impl true
      defdelegate normalize_error(err, ctx), to: Generic

      @impl true
      defdelegate headers(ctx), to: Generic

      @impl true
      def metadata do
        %{
          type: :unknown,  # TODO: Set to :paid | :public | :dedicated
          tier: :unknown,  # TODO: Set to :free | :paid | :enterprise
          known_limitations: [
            # TODO: Document known limitations from provider docs
          ],
          unsupported_categories: #{inspect(unsupported_categories)},
          unsupported_methods: #{inspect(remaining_unsupported)},
          conditional_support: %{
            # TODO: Add methods with parameter restrictions
            # "eth_getLogs" => "Max 2000 block range"
          },
          last_verified: ~D[#{Date.utc_today()}]
        }
      end
    end
    """

    Mix.shell().info(skeleton)

    # Write to file
    filename = "lib/lasso/core/providers/adapters/#{Macro.underscore(provider_name)}.ex"
    Mix.shell().info("\n💾 Save to: #{filename}")
  end
end
```

### Usage Examples

```bash
# Probe a new provider with standard methods
mix lasso.probe_provider https://api.newprovider.io/v1/mainnet

# Probe with all methods for comprehensive testing
mix lasso.probe_provider https://ethereum.publicnode.com \
  --level full \
  --timeout 5000

# Generate adapter skeleton from probe results
mix lasso.probe_provider https://eth-mainnet.alchemyapi.io/v2/$KEY \
  --level full \
  --output adapter \
  > lib/lasso/core/providers/adapters/alchemy.ex

# Get JSON output for scripting
mix lasso.probe_provider https://cloudflare-eth.com \
  --level standard \
  --output json | jq '.[] | select(.status == "unsupported")'
```

---

## Implementation Plan

### Phase 1: Foundation (Week 1)

**Goal**: Establish method registry and update existing adapters

**Tasks**:
1. Create `Lasso.RPC.MethodRegistry` module
   - Define all standard method categories
   - Implement category lookup functions
   - Add default support assumptions

2. Update `ProviderAdapter` behavior
   - Add `metadata/0` callback
   - Document adapter specification format

3. Update existing 9 adapters to use `MethodRegistry`
   - Alchemy
   - PublicNode
   - Cloudflare
   - DRPC
   - LlamaRPC
   - Merkle
   - Flashbots
   - 1RPC
   - Generic

4. Add tests for method categorization

**Deliverables**:
- `lib/lasso/rpc/method_registry.ex`
- Updated adapter files
- Test coverage for method lookups

**Success Criteria**:
- All existing tests pass
- Method categories cover 100% of standard Ethereum JSON-RPC
- Each adapter implements `metadata/0`

---

### Phase 2: Error Classification (Week 1)

**Goal**: Enhance error handling for capability violations

**Tasks**:
1. Create or update `ErrorClassifier` module
   - Add capability violation patterns
   - Add rate limit patterns
   - Add provider-specific error codes

2. Update `RequestPipeline` to use enhanced classification
   - Call `ErrorClassifier.classify/3`
   - Emit telemetry for error categories
   - Use classification for failover decisions

3. Add tests for error classification
   - Test capability violation detection
   - Test rate limit detection
   - Test provider-specific error handling

**Deliverables**:
- `lib/lasso/core/support/error_classifier.ex`
- Updated `RequestPipeline` error handling
- Telemetry events for error categories

**Success Criteria**:
- 95%+ accuracy on capability violation detection
- Correct failover behavior for each error category
- Telemetry data available for monitoring

---

### Phase 3: Development Tooling (Week 2)

**Goal**: Create Mix task for provider probing

**Tasks**:
1. Implement `mix lasso.probe_provider` task
   - Concurrent method probing
   - Multiple output formats (table, JSON, adapter)
   - Configurable probe levels

2. Document task usage
   - Add module documentation
   - Add examples to this spec
   - Add to main project README

3. Test task on existing providers
   - Verify Alchemy probe results
   - Verify Cloudflare probe results
   - Validate adapter generation

**Deliverables**:
- `lib/mix/tasks/lasso/probe_provider.ex`
- Documentation in task module
- Example probe outputs

**Success Criteria**:
- Task successfully probes 5+ providers
- Generated adapters match manual implementations
- Probe results help identify provider limitations

---

### Phase 4: Adapter Expansion (Week 2-3)

**Goal**: Implement adapters for top providers

**Providers to Add** (prioritized by usage):
1. **Infura** - Major paid provider
2. **QuickNode** - Archive support, paid tiers
3. **Ankr** - Public + paid tiers
4. **GetBlock** - Archive support
5. **Blast API** - Public provider
6. **POKT Network** - Decentralized
7. **Chainstack** - Enterprise
8. **Moralis** - Developer-focused

**Process per Provider**:
1. Run `mix lasso.probe_provider` against provider
2. Review provider documentation for parameter limits
3. Implement adapter using probe results + docs
4. Add provider to `AdapterRegistry`
5. Add tests for adapter
6. Document known limitations in `metadata/0`

**Deliverables**:
- 8 new adapter modules
- Updated `AdapterRegistry` mappings
- Tests for each adapter

**Success Criteria**:
- Each adapter accurately represents provider capabilities
- Tests validate method support filtering
- Tests validate parameter constraints

---

### Phase 5: Monitoring & Validation (Week 3)

**Goal**: Validate accuracy in production

**Tasks**:
1. Add telemetry dashboards
   - Capability violation rates per provider
   - Method support accuracy (false positives/negatives)
   - Failover success rates

2. Implement capability accuracy tracking
   - Record when adapter says "unsupported" but provider succeeds
   - Record when adapter says "supported" but provider rejects
   - Weekly reports on adapter accuracy

3. Create adapter maintenance playbook
   - Process for updating adapters when provider APIs change
   - Schedule for re-probing providers (quarterly)
   - Escalation for repeated capability violations

**Deliverables**:
- Telemetry dashboard queries
- Accuracy tracking instrumentation
- Maintenance playbook document

**Success Criteria**:
- <1% false positive rate (adapter says supported, provider rejects)
- <5% false negative rate (adapter says unsupported, provider accepts)
- Telemetry data available for all error categories

---

## Testing Strategy

### Unit Tests

**Method Registry**:
```elixir
defmodule Lasso.RPC.MethodRegistryTest do
  use ExUnit.Case

  alias Lasso.RPC.MethodRegistry

  test "all_methods returns unique methods" do
    methods = MethodRegistry.all_methods()
    assert length(methods) == length(Enum.uniq(methods))
  end

  test "method_category returns correct category" do
    assert MethodRegistry.method_category("eth_blockNumber") == :core
    assert MethodRegistry.method_category("eth_getLogs") == :filters
    assert MethodRegistry.method_category("debug_traceTransaction") == :debug
  end

  test "default_support_assumption is conservative" do
    assert MethodRegistry.default_support_assumption("eth_call") == true
    assert MethodRegistry.default_support_assumption("debug_traceTransaction") == false
    assert MethodRegistry.default_support_assumption("unknown_method") == false
  end
end
```

**Adapter Tests**:
```elixir
defmodule Lasso.RPC.Adapters.PublicNodeTest do
  use ExUnit.Case

  alias Lasso.RPC.Adapters.PublicNode

  describe "supports_method?/3" do
    test "blocks debug methods" do
      assert PublicNode.supports_method?("debug_traceTransaction", :http, %{}) ==
               {:error, :method_unsupported}
    end

    test "blocks eth_getLogs" do
      assert PublicNode.supports_method?("eth_getLogs", :http, %{}) ==
               {:error, :method_unsupported}
    end

    test "allows core methods" do
      assert PublicNode.supports_method?("eth_blockNumber", :http, %{}) == :ok
      assert PublicNode.supports_method?("eth_call", :http, %{}) == :ok
    end
  end

  describe "validate_params/4" do
    test "validates archive depth for eth_call" do
      params = [%{to: "0x...", data: "0x"}, "0x1"]
      context = %{current_block: 1000}

      # Recent block (within 1000 blocks)
      assert PublicNode.validate_params("eth_call", params, :http, context) == :ok

      # Old block (beyond archive depth)
      old_params = [%{to: "0x...", data: "0x"}, "0x0"]
      assert {:error, {:requires_archival, _}} =
        PublicNode.validate_params("eth_call", old_params, :http, context)
    end
  end

  describe "metadata/0" do
    test "returns complete metadata" do
      meta = PublicNode.metadata()

      assert meta.type == :public
      assert meta.tier == :free
      assert is_list(meta.known_limitations)
      assert is_list(meta.unsupported_categories)
      assert :filters in meta.unsupported_categories
    end
  end
end
```

**Error Classifier Tests**:
```elixir
defmodule Lasso.Core.Support.ErrorClassifierTest do
  use ExUnit.Case

  alias Lasso.Core.Support.ErrorClassifier

  test "classifies method not found" do
    assert ErrorClassifier.classify(-32601, "Method not found", :generic) ==
             {:method_unsupported, false}
  end

  test "classifies block range exceeded" do
    {category, retriable?} = ErrorClassifier.classify(
      -32005,
      "block range exceeded",
      :alchemy
    )

    assert category == :capability_violation
    assert retriable? == false
  end

  test "classifies rate limits as retriable" do
    {category, retriable?} = ErrorClassifier.classify(
      429,
      "Too many requests",
      :generic
    )

    assert category == :rate_limit
    assert retriable? == true
  end
end
```

### Integration Tests

**End-to-End Filtering**:
```elixir
defmodule Lasso.Core.Providers.AdapterFilterIntegrationTest do
  use ExUnit.Case

  alias Lasso.Core.Providers.AdapterFilter

  setup do
    # Create test channels with different adapter types
    channels = [
      build_channel(:alchemy, "alchemy_eth"),
      build_channel(:cloudflare, "cloudflare_eth"),
      build_channel(:publicnode, "publicnode_eth")
    ]

    {:ok, channels: channels}
  end

  test "filters channels for eth_getLogs", %{channels: channels} do
    {:ok, capable, filtered} = AdapterFilter.filter_channels(channels, "eth_getLogs")

    # Alchemy supports eth_getLogs
    assert Enum.any?(capable, &(&1.provider.id == "alchemy_eth"))

    # Cloudflare and PublicNode don't support eth_getLogs
    assert Enum.any?(filtered, &(&1.provider.id == "cloudflare_eth"))
    assert Enum.any?(filtered, &(&1.provider.id == "publicnode_eth"))
  end

  test "filters channels for debug_traceTransaction", %{channels: channels} do
    {:ok, capable, filtered} =
      AdapterFilter.filter_channels(channels, "debug_traceTransaction")

    # No standard providers support debug methods
    assert capable == []
    assert length(filtered) == 3
  end
end
```

**Mix Task Tests**:
```elixir
defmodule Mix.Tasks.Lasso.ProbeProviderTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  @moduletag :integration

  test "probes provider and outputs table" do
    output = capture_io(fn ->
      Mix.Tasks.Lasso.ProbeProvider.run([
        "https://ethereum.publicnode.com",
        "--level", "critical",
        "--timeout", "2000"
      ])
    end)

    assert output =~ "SUMMARY"
    assert output =~ "✅ Supported"
    assert output =~ "RECOMMENDATIONS"
  end

  test "generates adapter skeleton" do
    output = capture_io(fn ->
      Mix.Tasks.Lasso.ProbeProvider.run([
        "https://ethereum.publicnode.com",
        "--level", "standard",
        "--output", "adapter"
      ])
    end)

    assert output =~ "defmodule Lasso.RPC.Adapters."
    assert output =~ "@behaviour Lasso.RPC.ProviderAdapter"
    assert output =~ "def supports_method?"
  end
end
```

---

## Operational Considerations

### Performance Targets

| Metric | Target | Current | Notes |
|--------|--------|---------|-------|
| AdapterFilter P99 | <20μs | ~15μs | Phase 1 filtering overhead |
| Method lookup | <1μs | N/A | MethodRegistry category lookup |
| Error classification | <5μs | N/A | Pattern matching on error strings |
| Provider probing (dev) | <30s | N/A | Full probe of one provider |

### Monitoring

**Key Metrics**:
- `lasso.adapter_filter.filter_channels.duration` - Filtering latency
- `lasso.adapter_filter.capable_count` - Channels passing filter
- `lasso.adapter_filter.filtered_count` - Channels filtered out
- `lasso.request.error.count{category=capability_violation}` - Capability errors
- `lasso.request.error.count{category=rate_limit}` - Rate limits
- `lasso.adapter.accuracy.false_positive` - Adapter said supported, provider rejected
- `lasso.adapter.accuracy.false_negative` - Adapter said unsupported, provider accepted

**Alerts**:
- Capability violation rate >5% for any provider → Review adapter accuracy
- False positive rate >1% → Adapter declaration too permissive
- Filtering duration P99 >50μs → Performance regression

### Maintenance

**Quarterly Tasks**:
1. Re-probe top 10 providers using Mix task
2. Review provider documentation for API changes
3. Update adapters if capabilities changed
4. Review telemetry for false positive/negative rates
5. Update `last_verified` dates in adapter metadata

**When Provider API Changes**:
1. Run `mix lasso.probe_provider <url> --level full --output json`
2. Compare results to current adapter implementation
3. Update adapter `supports_method?` and `validate_params`
4. Update `metadata.last_verified` date
5. Deploy and monitor for accuracy improvements

**When Adding New Provider**:
1. Run probe task with `--output adapter`
2. Review provider documentation for parameter limits
3. Enhance generated adapter with parameter validation
4. Add tests for adapter
5. Add provider to `AdapterRegistry`
6. Document in provider matrix (Appendix B)

---

## Appendices

### Appendix A: Provider Type Classification

| Type | Characteristics | Examples |
|------|----------------|----------|
| **Paid Premium** | Full method support, high rate limits, SLAs | Alchemy (Growth+), Infura (Team+), QuickNode (Premium) |
| **Paid Standard** | Most methods, moderate limits | Alchemy (free tier), Infura (free tier), QuickNode (free) |
| **Public Community** | Limited methods, aggressive rate limits | PublicNode, LlamaRPC, Cloudflare |
| **Archive Specialized** | Full archive, debug/trace support | QuickNode (Archive), GetBlock, Ankr (Premium) |
| **Dedicated** | Private nodes, all methods | Customer-hosted nodes |

### Appendix B: Provider Capability Matrix

| Provider | Core | State | Filters | Debug | Trace | Archive Depth | Notes |
|----------|------|-------|---------|-------|-------|---------------|-------|
| Alchemy | ✅ | ✅ | ✅ (2K blocks) | ✅ (paid) | ❌ | Full (paid) | eth_getBlockReceipts supported |
| Infura | ✅ | ✅ | ✅ (10K blocks) | ❌ | ❌ | 128 blocks | Good filter support |
| QuickNode | ✅ | ✅ | ✅ (varies) | ✅ (paid) | ✅ (paid) | Full (archive tier) | Best archive support |
| Ankr | ✅ | ✅ | ✅ (1K blocks) | ❌ | ❌ | Limited | Public + paid tiers |
| PublicNode | ✅ | ⚠️ (recent) | ❌ | ❌ | ❌ | ~1000 blocks | Very limited |
| Cloudflare | ✅ | ✅ | ❌ | ❌ | ❌ | None | No filter methods |
| LlamaRPC | ✅ | ✅ | ⚠️ (limited) | ❌ | ❌ | Limited | Varies by chain |
| DRPC | ✅ | ✅ | ✅ (10K blocks) | ❌ | ❌ | Limited | Free tier restricted |

### Appendix C: Error Code Reference

| Code | Provider | Meaning | Category |
|------|----------|---------|----------|
| -32601 | All | Method not found | method_unsupported |
| -32602 | All | Invalid params | invalid_params |
| -32005 | Geth | Limit exceeded | capability_violation |
| -32046 | Cloudflare | Capacity limit | capability_violation |
| -32016 | Cloudflare | Rate limit | rate_limit |
| -32701 | PublicNode | Parameter range violation | capability_violation |
| 30 | DRPC | Free tier timeout | capability_violation |
| 35 | DRPC | Capability violation | capability_violation |
| 429 | HTTP | Too many requests | rate_limit |

### Appendix D: Glossary

- **Adapter**: Provider-specific module implementing ProviderAdapter behavior
- **Capability Violation**: Request rejected due to provider parameter limits
- **Method Category**: Group of methods with similar support patterns
- **Phase 1 Validation**: Fast method-level filtering (supports_method?)
- **Phase 2 Validation**: Slow parameter validation (validate_params)
- **Probing**: Automated testing of provider method support (dev tool)
- **Spec/Specification**: Static declaration of provider capabilities
- **Fail-Open**: Default to allowing requests when capability unknown

---

## Document History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025-11-17 | Engineering Team | Initial specification |

---

## References

- [Ethereum JSON-RPC Specification](https://ethereum.github.io/execution-apis/api-documentation/)
- [EIP-1186: eth_getProof](https://eips.ethereum.org/EIPS/eip-1186)
- [EIP-1559: Fee Market](https://eips.ethereum.org/EIPS/eip-1559)
- [EIP-4844: Blob Transactions](https://eips.ethereum.org/EIPS/eip-4844)
- Provider Documentation:
  - [Alchemy API Reference](https://docs.alchemy.com/reference/ethereum-api-quickstart)
  - [Infura Documentation](https://docs.infura.io/infura/networks/ethereum)
  - [QuickNode Documentation](https://www.quicknode.com/docs/ethereum)
