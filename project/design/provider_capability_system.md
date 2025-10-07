# Provider Capability System - Design Document

## Executive Summary

This document outlines a phased approach to building an intelligent provider capability system for Lasso RPC. The system will evolve from immediate error classification improvements to a learning-based capability discovery engine, ultimately enabling Lasso to route requests intelligently based on empirical provider capabilities and avoid misrouting requests to providers that don't support them.

## Problem Statement

### Current Issue

Lasso's error classification system incorrectly treats provider capability limitations as retriable infrastructure errors. Example scenario:

```
Provider: ethereum_public
Error: "This range of parameters is not supported"
Current Behavior:
  - Classified as retriable infrastructure error
  - System continues routing to this provider
  - Circuit breaker opens after N attempts
  - Poor user experience (high latency, wasted requests)

Desired Behavior:
  - Recognize as capability limitation
  - Exclude provider from future routing for this request type
  - System learns and remembers this limitation
  - Route to capable providers immediately
```

### Root Causes

1. **Insufficient Error Semantics**: Current classification relies on:
   - HTTP status codes (too coarse-grained)
   - JSON-RPC error codes (providers use inconsistently)
   - Simple keyword matching (brittle, incomplete)

2. **No Capability Model**: System has no concept of:
   - Provider-specific method support
   - Parameter range limitations (archival vs recent data)
   - Proprietary method extensions (Alchemy, Infura-specific APIs)

3. **Static Provider Configuration**: Current `chains.yml` only declares:
   - URLs, priority, type
   - No capability metadata or constraints

4. **Binary Retriability**: Errors are either "retriable" or "not retriable"
   - No distinction between "temporarily unavailable" vs "fundamentally unsupported"
   - No provider exclusion lists per request type

## Design Principles

1. **Graceful Degradation**: Start with simple improvements, evolve to sophisticated learning
2. **Zero Breaking Changes**: All changes are additive and backward-compatible
3. **Performance-First**: Classification and selection must remain <5ms
4. **Observability-Native**: All capability decisions emit telemetry and logs
5. **Pragmatic Learning**: Learn from real errors, not synthetic probes
6. **Fail-Safe Defaults**: Unknown capabilities default to "assume supported"

---

## Phase 1: Enhanced Error Classification (Immediate)

**Timeline**: 1-2 days
**Goal**: Fix the immediate misclassification issue with minimal changes

### 1.1 New Error Categories

Extend `Lasso.JSONRPC.Error` with finer-grained categories:

```elixir
# Current categories
:rate_limit, :auth_error, :client_error, :server_error, :network_error

# New categories
:unsupported_method      # Method doesn't exist on this provider
:unsupported_params      # Parameters not supported (range, archival, etc.)
:insufficient_credits    # Provider-specific quota/credits exhausted
:capability_limitation   # General capability limitation
```

### 1.2 Enhanced Message Pattern Matching

Add provider capability error patterns to `ErrorNormalizer`:

```elixir
# New patterns in ErrorNormalizer
@capability_keywords [
  "not supported",
  "unsupported",
  "not available",
  "does not support",
  "invalid range",
  "range too large",
  "exceeds maximum",
  "archival data not available",
  "historical data not supported",
  "block range",
  "too many logs",
  "query returned more than",
  "result limit exceeded"
]

defp categorize_and_assess_retriability(code, message) do
  message_lower = String.downcase(message)

  cond do
    # Check capability patterns FIRST (most specific)
    contains_any?(message_lower, @capability_keywords) ->
      {:capability_limitation, false}  # NOT retriable

    # Rate limits (checked before auth)
    contains_any?(message_lower, @rate_limit_keywords) ->
      {:rate_limit, true}

    # Auth errors
    contains_any?(message_lower, @auth_keywords) ->
      {:auth_error, true}

    # Fall back to code-based
    true ->
      {categorize_jsonrpc_error(code), retriable_jsonrpc_error?(code)}
  end
end
```

### 1.3 Circuit Breaker Policy Update

Modify `CircuitBreaker` to ignore capability errors:

```elixir
# In CircuitBreaker.classify_and_handle_result/2
{:error, %JError{category: :capability_limitation}} ->
  # Capability errors don't affect circuit breaker state
  handle_non_breaker_error(result, state)

{:error, %JError{category: :unsupported_method}} ->
  handle_non_breaker_error(result, state)

{:error, %JError{category: :unsupported_params}} ->
  handle_non_breaker_error(result, state)
```

### 1.4 Request Pipeline Failover Logic

Update `RequestPipeline` to exclude providers on capability errors:

```elixir
# In attempt_request_on_channels/4
{:error, %JError{category: cat} = reason}
    when cat in [:capability_limitation, :unsupported_method, :unsupported_params] ->

  # Log capability error for learning
  Logger.info("Provider capability limitation detected",
    provider: channel.provider_id,
    method: rpc_request["method"],
    error_category: cat,
    error_message: reason.message
  )

  # Emit telemetry for capability learning system
  :telemetry.execute([:lasso, :capability, :limitation_detected], %{count: 1}, %{
    chain: ctx.chain,
    provider_id: channel.provider_id,
    method: rpc_request["method"],
    category: cat,
    params_digest: ctx.params_digest
  })

  # Try next channel WITHOUT incrementing retries
  # (This isn't a failure, it's a capability mismatch)
  attempt_request_on_channels(rest_channels, rpc_request, timeout, ctx)
```

### 1.5 Observability Updates

Add structured logging for capability errors:

```elixir
# In Observability module
def log_capability_limitation(ctx, channel, error) do
  Logger.warning("Provider capability limitation",
    request_id: ctx.request_id,
    chain: ctx.chain,
    method: ctx.method,
    provider: channel.provider_id,
    transport: channel.transport,
    error_category: error.category,
    error_message: error.message,
    params_digest: ctx.params_digest
  )
end
```

### Phase 1 Outcomes

✅ Capability errors no longer trigger circuit breakers
✅ System automatically fails over to next provider
✅ Clear telemetry for capability limitations
✅ Foundation for learning system (Phase 3)

**Risk**: Message pattern matching is brittle (providers use inconsistent wording)
**Mitigation**: Phase 2 adds static capability declarations, Phase 3 adds learning

---

## Phase 2: Static Capability Declarations

**Timeline**: 3-5 days
**Goal**: Allow explicit provider capability declarations in configuration

### 2.1 Extended Provider Configuration Schema

Add capability declarations to `chains.yml`:

```yaml
chains:
  ethereum:
    chain_id: 1
    name: "Ethereum Mainnet"

    providers:
      - id: "ethereum_alchemy"
        name: "Alchemy"
        priority: 1
        type: "premium"
        url: "https://eth-mainnet.alchemyapi.io/v2/${ALCHEMY_API_KEY}"
        ws_url: "wss://eth-mainnet.alchemyapi.io/v2/${ALCHEMY_API_KEY}"

        # NEW: Capability declarations
        capabilities:
          archival: true
          max_block_range: 10000  # eth_getLogs range limit
          max_result_size: 10000  # max results per query

          # Method support (default: all standard methods supported)
          supported_methods:
            - "eth_*"  # All standard eth methods
            - "alchemy_*"  # Proprietary Alchemy methods

          unsupported_methods:
            - "trace_*"  # Doesn't support trace APIs

          # Parameter constraints
          constraints:
            eth_getLogs:
              max_block_range: 2000
              requires_topics: false
            eth_getBlockByNumber:
              archival_depth: -1  # unlimited archival

      - id: "ethereum_public"
        name: "PublicNode Ethereum"
        priority: 4
        type: "public"
        url: "https://ethereum-rpc.publicnode.com"

        capabilities:
          archival: false  # Recent blocks only
          max_block_range: 100
          max_result_size: 1000

          unsupported_methods:
            - "trace_*"
            - "debug_*"

          constraints:
            eth_getLogs:
              max_block_range: 100  # Very limited
              max_blocks_back: 128  # Only recent blocks
```

### 2.2 Capability Model

Create structured capability representation:

```elixir
defmodule Lasso.RPC.Capability do
  @moduledoc """
  Represents a provider's capabilities and constraints.

  This model supports both static (declared in config) and dynamic
  (learned from empirical errors) capabilities.
  """

  defstruct [
    :provider_id,
    :chain,

    # Static capabilities (from config)
    archival: true,
    max_block_range: nil,
    max_result_size: nil,
    supported_methods: [:all],  # :all or list of patterns
    unsupported_methods: [],

    # Method-specific constraints
    method_constraints: %{},

    # Dynamic capabilities (learned)
    learned_limitations: %{},  # method => limitation_record
    last_updated: nil,

    # Metadata
    source: :static  # :static | :learned | :hybrid
  ]

  @type t :: %__MODULE__{}

  @doc """
  Checks if a provider supports a given method with specific parameters.
  """
  @spec supports?(t(), method :: String.t(), params :: list()) ::
    {:ok, :supported} |
    {:error, :unsupported_method} |
    {:error, :unsupported_params, reason :: String.t()}
  def supports?(%__MODULE__{} = cap, method, params) do
    cond do
      method_unsupported?(cap, method) ->
        {:error, :unsupported_method}

      constraints_violated?(cap, method, params) ->
        {:error, :unsupported_params, constraint_violation_reason(cap, method, params)}

      learned_limitation_exists?(cap, method, params) ->
        {:error, :unsupported_params, "Learned from empirical errors"}

      true ->
        {:ok, :supported}
    end
  end

  @doc """
  Records a capability limitation learned from an error.
  """
  def record_limitation(cap, method, params, error) do
    limitation = %{
      method: method,
      params_pattern: extract_param_pattern(params),
      error_message: error.message,
      error_category: error.category,
      first_seen: System.system_time(:millisecond),
      occurrences: 1
    }

    updated_limitations =
      Map.update(
        cap.learned_limitations,
        method,
        [limitation],
        fn existing -> [limitation | existing] end
      )

    %{cap |
      learned_limitations: updated_limitations,
      last_updated: System.system_time(:millisecond),
      source: if(cap.source == :static, do: :hybrid, else: :learned)
    }
  end

  # Private helpers...
end
```

### 2.3 Capability Store

ETS-based capability storage:

```elixir
defmodule Lasso.RPC.CapabilityStore do
  @moduledoc """
  ETS-backed storage for provider capabilities.
  Supports both static (config-driven) and dynamic (learned) capabilities.
  """

  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    table = :ets.new(:capability_store, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @doc """
  Gets capabilities for a provider on a chain.
  Returns default capabilities if not found.
  """
  @spec get_capabilities(chain :: String.t(), provider_id :: String.t()) ::
    Lasso.RPC.Capability.t()
  def get_capabilities(chain, provider_id) do
    case :ets.lookup(:capability_store, {chain, provider_id}) do
      [{_, capability}] -> capability
      [] -> Lasso.RPC.Capability.default(chain, provider_id)
    end
  end

  @doc """
  Updates capabilities for a provider (called during config reload or learning).
  """
  def put_capabilities(chain, provider_id, capability) do
    :ets.insert(:capability_store, {{chain, provider_id}, capability})
    :ok
  end

  @doc """
  Records a learned limitation for a provider.
  """
  def record_limitation(chain, provider_id, method, params, error) do
    capability = get_capabilities(chain, provider_id)
    updated = Lasso.RPC.Capability.record_limitation(capability, method, params, error)
    put_capabilities(chain, provider_id, updated)

    # Emit telemetry
    :telemetry.execute([:lasso, :capability, :learned], %{count: 1}, %{
      chain: chain,
      provider_id: provider_id,
      method: method
    })
  end
end
```

### 2.4 Selection Integration

Update `Selection.select_channels/3` to filter by capabilities:

```elixir
defmodule Lasso.RPC.Selection do
  # ...existing code...

  def select_channels(chain, method, opts) do
    # ...existing candidate retrieval...

    candidates
    |> filter_by_capabilities(chain, method, opts)
    |> rank_by_strategy(strategy, method)
    |> Enum.take(limit)
  end

  defp filter_by_capabilities(candidates, chain, method, opts) do
    params = Keyword.get(opts, :params, [])

    Enum.filter(candidates, fn candidate ->
      capability = CapabilityStore.get_capabilities(chain, candidate.id)

      case Capability.supports?(capability, method, params) do
        {:ok, :supported} ->
          true

        {:error, reason} ->
          Logger.debug("Filtering out provider due to capability limitation",
            provider: candidate.id,
            method: method,
            reason: inspect(reason)
          )
          false
      end
    end)
  end
end
```

### 2.5 Configuration Loader

Update `ConfigStore` to parse and cache capabilities:

```elixir
defmodule Lasso.Config.ConfigStore do
  # ...existing code...

  defp load_provider_config(chain_name, provider_config) do
    # ...existing loading...

    # Parse capabilities if present
    capability =
      case Map.get(provider_config, "capabilities") do
        nil -> Capability.default(chain_name, provider_id)
        cap_config -> Capability.from_config(chain_name, provider_id, cap_config)
      end

    # Store in CapabilityStore
    CapabilityStore.put_capabilities(chain_name, provider_id, capability)

    provider_config
  end
end
```

### Phase 2 Outcomes

✅ Explicit capability declarations in config
✅ Pre-filtering of incompatible providers
✅ Support for provider-specific constraints
✅ Foundation for proprietary method routing

**Limitation**: Requires manual capability documentation
**Next Step**: Phase 3 adds automatic learning

---

## Phase 3: Dynamic Capability Learning

**Timeline**: 1-2 weeks
**Goal**: Automatically discover and remember provider capabilities from empirical errors

### 3.1 Learning Engine Architecture

```elixir
defmodule Lasso.RPC.CapabilityLearner do
  @moduledoc """
  Learns provider capabilities from empirical request/error patterns.

  Uses telemetry events to observe capability limitation errors and
  builds a statistical model of provider constraints.
  """

  use GenServer

  defstruct [
    :observations,  # Map of {chain, provider, method} => [observations]
    :confidence_threshold,  # Min observations to learn a limitation
    :persistence_interval  # How often to persist to disk
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    # Attach to capability telemetry
    :telemetry.attach_many(
      "capability-learner",
      [
        [:lasso, :capability, :limitation_detected],
        [:lasso, :rpc, :request, :stop]
      ],
      &__MODULE__.handle_telemetry/4,
      nil
    )

    # Load persisted learnings
    observations = load_persisted_learnings()

    # Schedule periodic persistence
    schedule_persistence()

    {:ok, %__MODULE__{
      observations: observations,
      confidence_threshold: Keyword.get(opts, :confidence_threshold, 3),
      persistence_interval: Keyword.get(opts, :persistence_interval, 60_000)
    }}
  end

  def handle_telemetry(
    [:lasso, :capability, :limitation_detected],
    _measurements,
    metadata,
    _config
  ) do
    GenServer.cast(__MODULE__, {:observe_limitation, metadata})
  end

  def handle_telemetry(
    [:lasso, :rpc, :request, :stop],
    %{duration_ms: _duration},
    %{result: :success} = metadata,
    _config
  ) do
    # Positive signal: provider DOES support this
    GenServer.cast(__MODULE__, {:observe_success, metadata})
  end

  def handle_cast({:observe_limitation, metadata}, state) do
    observation = %{
      chain: metadata.chain,
      provider_id: metadata.provider_id,
      method: metadata.method,
      category: metadata.category,
      params_digest: metadata[:params_digest],
      timestamp: System.system_time(:millisecond),
      type: :limitation
    }

    new_state = record_observation(state, observation)
    new_state = maybe_learn_limitation(new_state, observation)

    {:noreply, new_state}
  end

  def handle_cast({:observe_success, metadata}, state) do
    observation = %{
      chain: metadata.chain,
      provider_id: metadata.provider_id,
      method: metadata.method,
      params_digest: metadata[:params_digest],
      timestamp: System.system_time(:millisecond),
      type: :success
    }

    new_state = record_observation(state, observation)

    {:noreply, new_state}
  end

  defp maybe_learn_limitation(state, observation) do
    key = {observation.chain, observation.provider_id, observation.method}
    observations = Map.get(state.observations, key, [])

    # Count recent limitation observations
    recent_limitations =
      observations
      |> Enum.filter(&(&1.type == :limitation))
      |> Enum.filter(&recent?(&1, 300_000))  # Last 5 minutes
      |> length()

    # Learn if we've seen this limitation enough times
    if recent_limitations >= state.confidence_threshold do
      learn_limitation(observation)
    end

    state
  end

  defp learn_limitation(observation) do
    Logger.info("Learning provider limitation",
      chain: observation.chain,
      provider: observation.provider_id,
      method: observation.method,
      category: observation.category
    )

    # Create a learned limitation record
    limitation = %{
      method: observation.method,
      category: observation.category,
      params_pattern: observation.params_digest,
      confidence: :high,
      first_observed: observation.timestamp,
      last_observed: observation.timestamp,
      observation_count: 1
    }

    # Update CapabilityStore
    capability = CapabilityStore.get_capabilities(
      observation.chain,
      observation.provider_id
    )

    updated = Capability.add_learned_limitation(capability, limitation)
    CapabilityStore.put_capabilities(observation.chain, observation.provider_id, updated)

    :ok
  end

  defp load_persisted_learnings do
    # Load from disk (e.g., priv/capabilities/learned.json)
    # Format: %{"{chain}:{provider}:{method}" => [observations]}
    %{}
  end

  defp persist_learnings(state) do
    # Save observations to disk for durability across restarts
    :ok
  end

  # ... more helpers ...
end
```

### 3.2 Confidence-Based Filtering

Extend `Capability.supports?/3` to use confidence levels:

```elixir
defmodule Lasso.RPC.Capability do
  # ...existing code...

  defp learned_limitation_exists?(cap, method, params) do
    case Map.get(cap.learned_limitations, method) do
      nil ->
        false

      limitations ->
        Enum.any?(limitations, fn lim ->
          params_match?(lim.params_pattern, params) and
          confidence_sufficient?(lim)
        end)
    end
  end

  defp confidence_sufficient?(limitation) do
    limitation.observation_count >= 3 and
    limitation.confidence in [:medium, :high]
  end
end
```

### 3.3 Persistence Layer

Save learned capabilities to disk for durability:

```elixir
# priv/capabilities/ethereum/learned.json
{
  "ethereum_public": {
    "learned_limitations": {
      "eth_getLogs": [
        {
          "params_pattern": "block_range_>1000",
          "error_message": "query returned more than 10000 results",
          "category": "capability_limitation",
          "confidence": "high",
          "observation_count": 15,
          "first_observed": 1704067200000,
          "last_observed": 1704153600000
        }
      ]
    },
    "last_updated": 1704153600000
  }
}
```

### 3.4 Unlearning / Decay

Add mechanism to forget stale limitations:

```elixir
defmodule Lasso.RPC.CapabilityLearner do
  # In handle_cast({:observe_success, metadata}, state)

  # If we see successful requests that previously failed,
  # reduce confidence or remove the limitation
  defp maybe_unlearn_limitation(state, observation) do
    key = {observation.chain, observation.provider_id, observation.method}
    capability = CapabilityStore.get_capabilities(observation.chain, observation.provider_id)

    case Map.get(capability.learned_limitations, observation.method) do
      nil ->
        state

      limitations ->
        # Find matching limitation
        matching = Enum.find(limitations, &params_match?(&1.params_pattern, observation.params_digest))

        if matching do
          # Success contradicts learned limitation - reduce confidence
          Logger.info("Success observed for previously limited pattern, reducing confidence",
            provider: observation.provider_id,
            method: observation.method
          )

          # Decrement observation count or remove entirely
          updated_limitations =
            Enum.map(limitations, fn lim ->
              if lim == matching do
                %{lim | observation_count: max(lim.observation_count - 1, 0)}
              else
                lim
              end
            end)
            |> Enum.filter(&(&1.observation_count > 0))

          updated_cap = %{capability |
            learned_limitations: Map.put(capability.learned_limitations, observation.method, updated_limitations)
          }

          CapabilityStore.put_capabilities(observation.chain, observation.provider_id, updated_cap)
        end

        state
    end
  end
end
```

### Phase 3 Outcomes

✅ Automatic capability discovery from errors
✅ Statistical confidence-based learning
✅ Persistence across restarts
✅ Self-correcting via unlearning
✅ Zero manual capability documentation required

---

## Phase 4: Proprietary Method Support

**Timeline**: 3-5 days
**Goal**: Enable routing of provider-specific methods (Alchemy, Infura extensions)

### 4.1 Proprietary Method Registry

```elixir
defmodule Lasso.RPC.ProprietaryMethods do
  @moduledoc """
  Registry of provider-specific JSON-RPC methods.
  Allows routing of non-standard methods to providers that support them.
  """

  # Alchemy-specific methods
  @alchemy_methods [
    "alchemy_getTokenBalances",
    "alchemy_getTokenMetadata",
    "alchemy_getAssetTransfers",
    "alchemy_getTransactionReceipts"
  ]

  # Infura-specific methods
  @infura_methods [
    "infura_gasPrice",
    "infura_getFilteredLogs"
  ]

  def supported_by_provider?(method, provider_id) do
    cond do
      String.contains?(provider_id, "alchemy") and method in @alchemy_methods ->
        true

      String.contains?(provider_id, "infura") and method in @infura_methods ->
        true

      # Standard methods supported by all
      String.starts_with?(method, "eth_") ->
        true

      true ->
        false
    end
  end

  def get_supporting_providers(chain, method) do
    # Return list of provider IDs that support this method
    Lasso.Config.ConfigStore.list_providers(chain)
    |> Enum.filter(&supported_by_provider?(method, &1.id))
  end
end
```

### 4.2 Selection Integration

```elixir
def select_channels(chain, method, opts) do
  # For proprietary methods, pre-filter to supporting providers only
  candidates =
    if proprietary_method?(method) do
      ProprietaryMethods.get_supporting_providers(chain, method)
      |> get_channels_for_providers(chain)
    else
      # Standard method - use normal selection
      get_all_candidates(chain, opts)
    end

  candidates
  |> filter_by_capabilities(chain, method, opts)
  |> rank_by_strategy(strategy, method)
  |> Enum.take(limit)
end
```

### 4.3 Provider Adapter Enhancements

```elixir
defmodule Lasso.RPC.Providers.Alchemy do
  @moduledoc """
  Alchemy-specific provider adapter.
  Handles Alchemy proprietary methods and error codes.
  """

  @behaviour Lasso.RPC.ProviderAdapter

  @impl true
  def normalize_request(request, _ctx) do
    # Alchemy-specific request transformations if needed
    request
  end

  @impl true
  def normalize_response(response, ctx) do
    # Handle Alchemy-specific response formats
    Lasso.RPC.Providers.Generic.normalize_response(response, ctx)
  end

  @impl true
  def normalize_error(error, ctx) do
    # Alchemy uses custom error codes
    case error do
      %{"code" => -32602, "message" => msg} when is_binary(msg) ->
        cond do
          String.contains?(msg, "invalid API key") ->
            JError.new(-32602, msg,
              provider_id: ctx.provider_id,
              category: :auth_error,
              retriable?: true  # Failover to other providers
            )

          true ->
            Lasso.RPC.Providers.Generic.normalize_error(error, ctx)
        end

      _ ->
        Lasso.RPC.Providers.Generic.normalize_error(error, ctx)
    end
  end

  @impl true
  def headers(_ctx) do
    # Alchemy-specific headers if needed
    []
  end
end
```

### Phase 4 Outcomes

✅ Support for Alchemy, Infura proprietary methods
✅ Provider adapters enable custom error handling
✅ Seamless routing for non-standard APIs

---

## Implementation Roadmap

### Week 1: Phase 1 (Immediate Fix)
- [ ] Day 1-2: Enhanced error categorization
  - Add new error categories
  - Implement capability keyword patterns
  - Update `ErrorNormalizer`
- [ ] Day 3: Circuit breaker updates
  - Modify CB to ignore capability errors
  - Add observability
- [ ] Day 4: Request pipeline failover
  - Skip capability-limited providers
  - Emit telemetry
- [ ] Day 5: Testing & validation
  - Battle tests for capability scenarios
  - Verify no CB triggers on capability errors

### Week 2-3: Phase 2 (Static Capabilities)
- [ ] Day 1-3: Capability model & store
  - Define `Capability` struct
  - Implement `CapabilityStore` (ETS)
  - Add config parsing
- [ ] Day 4-6: Selection integration
  - Update `Selection.select_channels/3`
  - Add capability filtering
  - Provider exclusion logic
- [ ] Day 7-8: Configuration & documentation
  - Document capability schema
  - Add capabilities to `chains.yml`
  - Migration guide
- [ ] Day 9-10: Testing
  - Unit tests for capability filtering
  - Integration tests
  - Battle tests

### Week 4-5: Phase 3 (Learning System)
- [ ] Day 1-4: Learning engine
  - Implement `CapabilityLearner`
  - Telemetry integration
  - Observation collection
- [ ] Day 5-7: Confidence & persistence
  - Confidence scoring
  - Disk persistence
  - Unlearning logic
- [ ] Day 8-10: Testing & tuning
  - Validate learning threshold
  - Test unlearning
  - Performance benchmarks

### Week 6: Phase 4 (Proprietary Methods)
- [ ] Day 1-2: Method registry
  - Define proprietary method lists
  - Implement routing logic
- [ ] Day 3-4: Provider adapters
  - Alchemy adapter
  - Infura adapter (if needed)
- [ ] Day 5: Testing & docs

---

## Testing Strategy

### Unit Tests

```elixir
defmodule Lasso.RPC.CapabilityTest do
  use ExUnit.Case

  describe "supports?/3" do
    test "returns :ok for supported method" do
      cap = %Capability{
        supported_methods: ["eth_*"],
        unsupported_methods: []
      }

      assert {:ok, :supported} = Capability.supports?(cap, "eth_blockNumber", [])
    end

    test "returns :error for unsupported method" do
      cap = %Capability{
        supported_methods: ["eth_*"],
        unsupported_methods: ["trace_*"]
      }

      assert {:error, :unsupported_method} = Capability.supports?(cap, "trace_block", [])
    end

    test "returns :error for parameter constraint violation" do
      cap = %Capability{
        method_constraints: %{
          "eth_getLogs" => %{max_block_range: 100}
        }
      }

      params = [%{"fromBlock" => "0x1", "toBlock" => "0x200"}]  # Range of 511 blocks

      assert {:error, :unsupported_params, _reason} = Capability.supports?(cap, "eth_getLogs", params)
    end
  end
end
```

### Integration Tests

```elixir
defmodule Lasso.RPC.CapabilityIntegrationTest do
  use Lasso.DataCase

  test "request pipeline excludes provider with capability limitation" do
    # Setup: Configure one provider with limited range
    Lasso.Config.ConfigStore.update_provider("ethereum", "limited_provider", %{
      capabilities: %{
        method_constraints: %{
          "eth_getLogs" => %{max_block_range: 10}
        }
      }
    })

    # Execute request with large block range
    params = [%{"fromBlock" => "0x1", "toBlock" => "0x1000"}]

    {:ok, result, ctx} = Lasso.RPC.RequestPipeline.execute_via_channels(
      "ethereum",
      "eth_getLogs",
      params,
      []
    )

    # Verify: Should route to capable provider, not limited_provider
    assert ctx.selected_provider.id != "limited_provider"
  end
end
```

### Battle Tests

```elixir
defmodule Lasso.Battle.CapabilityScenarioTest do
  use Lasso.BattleCase

  test "capability learning under load" do
    Scenario.new("Learn capability limitations from errors")
    |> Scenario.setup_chain(:ethereum, providers: [:capable, :limited])
    |> Scenario.configure_provider(:limited, %{
      inject_errors: %{
        "eth_getLogs" => {:capability_limitation, "query returned more than 10000 results"}
      }
    })
    |> Scenario.run_workload(
      duration: 60_000,
      concurrency: 10,
      methods: ["eth_getLogs"],
      params_generator: &large_log_query_params/0
    )
    |> Scenario.assert_capability_learned(:limited, "eth_getLogs", :unsupported_params)
    |> Scenario.assert_routing_avoids(:limited, "eth_getLogs")
    |> Scenario.generate_report()
  end
end
```

---

## Observability & Monitoring

### Telemetry Events

```elixir
# New events emitted by capability system
[:lasso, :capability, :limitation_detected]  # Capability error observed
[:lasso, :capability, :learned]              # New limitation learned
[:lasso, :capability, :unlearned]            # Limitation removed
[:lasso, :capability, :filtered]             # Provider filtered out by capability
```

### Structured Logs

```json
{
  "event": "capability.limitation_detected",
  "chain": "ethereum",
  "provider_id": "ethereum_public",
  "method": "eth_getLogs",
  "error_category": "capability_limitation",
  "error_message": "query returned more than 10000 results",
  "params_digest": "sha256:abc123...",
  "timestamp": 1704067200000
}

{
  "event": "capability.learned",
  "chain": "ethereum",
  "provider_id": "ethereum_public",
  "method": "eth_getLogs",
  "limitation_type": "max_result_size",
  "confidence": "high",
  "observation_count": 5,
  "timestamp": 1704067800000
}

{
  "event": "capability.filtered",
  "chain": "ethereum",
  "provider_id": "ethereum_public",
  "method": "eth_getLogs",
  "reason": "Learned limitation: max_result_size exceeded",
  "timestamp": 1704068000000
}
```

### Dashboard Visualization

Add to LiveView dashboard:

```
┌─ Provider Capabilities ─────────────────────────────────┐
│ ethereum_alchemy                                         │
│   ✓ Archival: Yes                                       │
│   ✓ eth_getLogs max_range: 2000 blocks                  │
│   ✓ Proprietary: alchemy_* methods                      │
│                                                          │
│ ethereum_public                                          │
│   ✗ Archival: No (learned)                              │
│   ⚠ eth_getLogs max_range: 100 blocks (learned)         │
│   📊 Confidence: High (15 observations)                  │
└─────────────────────────────────────────────────────────┘
```

---

## Performance Considerations

### Selection Performance

- **Target**: Capability filtering adds <2ms to selection
- **Strategy**:
  - ETS lookups for capabilities (sub-microsecond)
  - Cache compiled regex patterns for method matching
  - Lazy evaluation - only check capabilities for final candidates

### Memory Footprint

- **Learned capabilities**: ~1KB per provider per method
- **Expected scale**: 10 chains × 10 providers × 20 methods = 2MB
- **Mitigation**: TTL-based eviction for low-confidence learnings

### Persistence Overhead

- **Write frequency**: Every 60 seconds (configurable)
- **Async writes**: Non-blocking persistence
- **Format**: JSON (human-readable, debuggable)

---

## Migration & Rollout

### Phase 1 Rollout
1. Deploy with feature flag: `config :lasso, enhanced_error_classification: false`
2. Monitor telemetry for capability errors
3. Enable feature flag gradually (A/B test)
4. Full rollout after 48 hours of monitoring

### Phase 2 Rollout
1. Add capabilities to `chains.yml` incrementally
2. Start with one well-documented provider (Alchemy)
3. Expand to all providers over 1 week
4. Document learned lessons

### Phase 3 Rollout
1. Deploy learning engine in observe-only mode
2. Let it collect data for 1 week without applying learnings
3. Review learned capabilities for accuracy
4. Enable learning-based filtering gradually

---

## Open Questions & Future Work

### Short-term
1. **Confidence threshold tuning**: What's the right N for "learned"?
   - Proposal: Start with N=5, tune based on false positive rate
2. **Parameter pattern extraction**: How to generalize parameter patterns?
   - Proposal: Hash params, later evolve to semantic pattern matching

### Long-term
1. **Cross-chain learning**: Share learnings across similar chains?
   - Example: Polygon limitations might apply to other L2s
2. **Cost-aware capability selection**: Route based on provider pricing
   - Integration with `:cheapest` strategy
3. **Predictive capability detection**: Probe providers before they fail?
   - Synthetic health checks with edge-case parameters

---

## Success Metrics

### Phase 1 Goals
- [ ] Zero circuit breaker openings due to capability errors
- [ ] <1% of requests retry on capability-limited providers
- [ ] 100% of capability errors emit telemetry

### Phase 2 Goals
- [ ] 100% of providers have capability declarations
- [ ] Provider selection accuracy: >99% (no capability-based failures)
- [ ] Selection latency: <3ms added overhead

### Phase 3 Goals
- [ ] >90% of limitations learned within 24 hours
- [ ] <5% false positive rate (incorrectly learned limitations)
- [ ] Zero manual capability documentation needed for new providers

### Phase 4 Goals
- [ ] Support for Alchemy, Infura proprietary methods
- [ ] Zero routing errors for proprietary methods
- [ ] Documentation for adding new provider adapters

---

## Conclusion

This phased approach balances immediate impact (fixing the classification bug) with long-term architectural goals (intelligent capability-aware routing). Each phase builds on the previous, creating a foundation for a system that continuously learns and adapts to provider capabilities without manual intervention.

The design prioritizes:
- **Pragmatism**: Simple fixes before complex systems
- **Observability**: Every decision is logged and measurable
- **Safety**: Conservative defaults, gradual rollout
- **Elegance**: Clean abstractions that compose naturally

By Phase 3 completion, Lasso will be one of the few RPC aggregators with true capability-aware routing, providing a significant competitive advantage and dramatically improved reliability for users.
