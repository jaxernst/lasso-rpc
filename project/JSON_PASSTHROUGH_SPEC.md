# JSON-RPC Passthrough Optimization Specification

**Version**: 1.4
**Status**: Implementation Complete
**Authors**: Engineering Team
**Reviewers**: EVM Tech Lead, Elixir/BEAM Researcher, Tech Lead
**Created**: 2024-12-04
**Updated**: 2024-12-05

### Changelog

- **v1.4**: Implemented and tested. Removed `parse_safe/1` (existing guards sufficient per BEAM expert). Updated spec to match actual implementation.
- **v1.3**: Zero-copy batch array splitter design, property tests for correctness
- **v1.2**: Simplified design - removed Fallback struct, result_type inference, ResponseSerializer behaviour, size thresholds, and config. Always passthrough by default.
- **v1.1**: Added lazy decode philosophy and touchpoint catalog
- **v1.0**: Initial specification

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Problem Statement](#2-problem-statement)
3. [Solution Overview](#3-solution-overview)
4. [Core Design Philosophy: Lazy Decoding](#4-core-design-philosophy-lazy-decoding)
5. [Structured Types Design](#5-structured-types-design)
6. [Module Architecture](#6-module-architecture)
7. [Implementation Specification](#7-implementation-specification)
8. [Batch Request Support](#8-batch-request-support)
9. [Transport Layer Changes](#9-transport-layer-changes)
10. [Observability Adaptations](#10-observability-adaptations)
11. [Result Decoding Touchpoints](#11-result-decoding-touchpoints)
12. [Error Handling](#12-error-handling)
13. [Testing Strategy](#13-testing-strategy)
14. [Risk Analysis](#14-risk-analysis)

---

## 1. Executive Summary

### 1.1 Objective

Eliminate unnecessary JSON decode/encode cycles for large RPC responses by implementing a passthrough mechanism that:

1. Parses only the JSON-RPC envelope (id, jsonrpc, result/error detection)
2. Passes the raw response bytes directly to clients for success responses
3. Maintains full parsing for error responses (which are small)
4. Supports both unary and batch requests across HTTP and WebSocket transports

## 2. Problem Statement

### 2.1 Current Architecture Pain Point

Every JSON-RPC response currently undergoes two expensive operations:

```
Provider Response (raw bytes)
    ↓
Jason.decode() ← O(n) CPU, O(n) memory allocation
    ↓
Elixir map with decoded "result" field
    ↓
Extract "result", build response envelope
    ↓
Jason.encode() ← O(n) CPU, O(n) memory allocation
    ↓
Client Response (raw bytes)
```

For a 50MB `eth_getLogs` response, this means:

- ~250ms decode + ~460ms encode = **707ms of CPU time**
- ~100MB of intermediate heap allocation
- Complete scheduler monopolization during processing

### 2.2 Key Insight

The proxy **does not need to inspect the `result` field contents**. The hot path only requires:

1. **Envelope validation**: Confirm valid JSON-RPC 2.0 structure
2. **ID extraction**: Verify response ID matches request ID
3. **Result/Error detection**: Route errors through error handling, pass through results
4. **Error parsing**: Full parsing only for error objects (typically <1KB)

## 3. Solution Overview

### 3.1 Passthrough Data Flow

```
Provider Response (raw bytes)
    ↓
EnvelopeParser.parse() ← O(1) CPU (~0.003ms), zero allocation
    ↓
%Response.Success{raw_bytes: bytes, id: id, ...}
    ↓
Verify ID matches request
    ↓
Send raw_bytes directly to client ← No re-encoding
```

### 3.2 Design Principles

1. **Zero-copy semantics**: Raw bytes flow through without transformation
2. **Structured types**: All response variants represented as typed structs
3. **Lazy decoding**: Never decode results unless explicitly requested
4. **Simple paths**: One code path for all responses, not size-based branching

### 3.3 Correctness Invariant

For any valid JSON-RPC success response `R` from a provider:

```
1. EnvelopeParser.parse(R) succeeds with envelope E
2. Response.Success.from_envelope(E).raw_bytes == R  (byte-for-byte identical)
3. Jason.decode(R)["result"] == Success.decode_result(response) |> elem(1)
```

**In plain terms**: Passthrough responses are bit-for-bit identical to what the provider sent.
No transformation, no re-encoding, no character encoding changes. The client receives
exactly what the upstream provider returned.

### 3.4 Architectural Layers

```
┌─────────────────────────────────────────────────────────────┐
│                    Client Interface                          │
│              (RPCController / RPCSocket)                     │
├─────────────────────────────────────────────────────────────┤
│                   Response Module                            │
│     (Unified response types: Success, Error, Batch)         │
├─────────────────────────────────────────────────────────────┤
│                  Passthrough Module                          │
│        (Eligibility, reconstruction, serialization)         │
├─────────────────────────────────────────────────────────────┤
│                 EnvelopeParser Module                        │
│           (Fast envelope-only JSON parsing)                  │
├─────────────────────────────────────────────────────────────┤
│                   Transport Layer                            │
│              (HTTP/Finch, WebSocket/Connection)              │
└─────────────────────────────────────────────────────────────┘
```

---

## 4. Core Design Philosophy: Lazy Decoding

### 4.1 The Principle

**Parse the envelope always. Decode the result never — unless explicitly requested.**

This lazy decoding approach provides:

1. **Default efficiency**: The hot path (client request → provider → client response) never decodes the result
2. **Explicit opt-in**: Callers that need decoded results call `decode_result/1` explicitly
3. **No heuristics**: No guessing about "small enough" responses — all responses use the same path
4. **Audit trail**: Easy to grep for `decode_result` to find all decode sites

### 4.2 When to Decode vs Passthrough

| Scenario                       | Decode? | Rationale                                            |
| ------------------------------ | ------- | ---------------------------------------------------- |
| Forward response to client     | **No**  | Client will decode; we're just a proxy               |
| Health probe (block height)    | **Yes** | Need to parse hex string to integer                  |
| Discovery probe (limits)       | **Yes** | Need to inspect response structure                   |
| Provider adapter normalization | **No**  | Passthrough responses don't need normalization       |
| Error responses                | **Yes** | Always parsed (small, need code/message for routing) |
| Observability (result size)    | **No**  | Use `byte_size(raw_bytes)`                           |

### 4.3 The `decode_result/1` Contract

```elixir
@doc """
Decode the result field from raw bytes.

This is an EXPLICIT OPT-IN for callers that need the actual result value.
The hot path should NEVER call this — send raw_bytes directly.

## When to Use

- Health probes needing block height
- Discovery probes inspecting response structure
- Testing/debugging
- Any cold-path operation requiring result inspection

## When NOT to Use

- Forwarding responses to clients (use raw_bytes)
- Building batch responses (use raw_bytes)
- Any hot-path operation

## Examples

    # Health probe - needs block height
    {:ok, %Success{} = resp} = Passthrough.parse_response(bytes)
    {:ok, "0x" <> hex} = Success.decode_result(resp)
    height = String.to_integer(hex, 16)

    # Client response - passthrough
    {:ok, %Success{raw_bytes: bytes}} = Passthrough.parse_response(bytes)
    send_resp(conn, 200, bytes)  # Zero decode!
"""
@spec decode_result(Success.t()) :: {:ok, term()} | {:error, term()}
def decode_result(%Success{raw_bytes: raw_bytes}) do
  case Jason.decode(raw_bytes) do
    {:ok, %{"result" => result}} -> {:ok, result}
    {:ok, _} -> {:error, :no_result_field}
    {:error, reason} -> {:error, {:decode_failed, reason}}
  end
end
```

### 4.4 Design Decision Rationale

**Why not decode small responses automatically?**

1. **Simplicity**: One code path is easier to reason about than two
2. **No threshold debates**: Avoids "is 10KB small enough?" discussions
3. **Predictable performance**: All responses have same overhead
4. **Explicit intent**: Code that decodes is visibly opting in

**Why not cache decoded results?**

1. **Structs are immutable**: Would need to return new struct
2. **Memory overhead**: Holding both raw_bytes and decoded result
3. **Rare need**: Most callers need decode once, if at all
4. **BEAM efficiency**: Jason.decode is fast for small payloads

---

## 5. Structured Types Design

### 5.1 Core Response Types

```elixir
defmodule Lasso.RPC.Response do
  @moduledoc """
  Unified response types for JSON-RPC responses with passthrough support.

  This module defines the canonical representation of responses flowing through
  the Lasso pipeline. All response variants are represented as structs with
  explicit types, enabling pattern matching and compile-time guarantees.

  ## Response Variants

  - `Success` - Successful response with raw bytes for passthrough
  - `Error` - Error response (fully parsed)
  - `Batch` - Batch response containing multiple Success/Error items

  ## Usage

      case Response.from_bytes(raw_bytes) do
        {:ok, %Response.Success{} = resp} ->
          # Send raw bytes directly
          send_resp(conn, 200, resp.raw_bytes)

        {:ok, %Response.Error{} = resp} ->
          # Handle error normally
          handle_error(conn, resp)
      end
  """

  alias Lasso.JSONRPC.Error, as: JError

  # Re-export submodule structs for convenience
  alias __MODULE__.{Success, Error, Batch}

  @type t :: Success.t() | Error.t() | Batch.t()
  @type id :: integer() | String.t() | nil
  @type parse_result :: {:ok, t()} | {:error, term()}

  @doc """
  Parse raw response bytes into a structured Response type.

  Uses envelope-only parsing to extract metadata without parsing the result.

  ## Examples

      iex> from_bytes(~s({"jsonrpc":"2.0","id":1,"result":"0x123"}))
      {:ok, %Response.Success{id: 1, raw_bytes: ...}}

      iex> from_bytes(~s({"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"Invalid"}}))
      {:ok, %Response.Error{id: 1, error: %JError{code: -32600, ...}}}
  """
  @spec from_bytes(binary()) :: parse_result()
  def from_bytes(raw_bytes) when is_binary(raw_bytes) do
    case Lasso.RPC.EnvelopeParser.parse(raw_bytes) do
      {:ok, %{type: :result} = envelope} ->
        {:ok, Success.from_envelope(envelope)}

      {:ok, %{type: :error} = envelope} ->
        {:ok, Error.from_envelope(envelope)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def from_bytes(_), do: {:error, :invalid_input}

  @doc """
  Serialize a Response to bytes for sending to client.

  For Success responses, returns raw_bytes directly (zero-copy).
  For Error responses, encodes the error structure.
  For Batch responses, reconstructs the array from components.
  """
  @spec to_bytes(t()) :: {:ok, binary()} | {:error, term()}
  def to_bytes(%Success{raw_bytes: bytes}), do: {:ok, bytes}
  def to_bytes(%Error{} = error), do: Error.to_bytes(error)
  def to_bytes(%Batch{} = batch), do: Batch.to_bytes(batch)

  @doc """
  Extract the response ID regardless of response type.
  """
  @spec id(t()) :: id()
  def id(%Success{id: id}), do: id
  def id(%Error{id: id}), do: id
  def id(%Batch{}), do: nil  # Batch has no single ID
end
```

### 5.2 Success Response Struct

```elixir
defmodule Lasso.RPC.Response.Success do
  @moduledoc """
  Represents a successful JSON-RPC response eligible for passthrough.

  The `raw_bytes` field contains the complete, unmodified response from
  the upstream provider. This enables zero-copy passthrough to clients.

  ## Memory Characteristics

  The `raw_bytes` field holds a reference to the original HTTP response binary.
  For binaries >64 bytes, BEAM uses reference-counted binaries (refc binaries)
  stored in a separate heap. This means:

  - **No copying**: The Response struct contains a 16-byte reference, not a copy
  - **Zero-copy passthrough**: Sending `raw_bytes` to Cowboy doesn't copy data
  - **Automatic cleanup**: Binary is garbage collected when all references drop

  For a 100MB response, memory overhead of the Success struct is ~100 bytes,
  not 100MB. The binary data exists exactly once in the shared binary heap.

  ## Example

      # Provider returns 50MB response
      {:ok, %Success{raw_bytes: bytes}} = Response.from_bytes(large_response)

      # Sending to client - no copy, just passes the binary reference
      send_resp(conn, 200, bytes)

      # After response sent and conn closed, binary is eligible for GC
  """

  @enforce_keys [:id, :jsonrpc, :raw_bytes]
  defstruct [:id, :jsonrpc, :raw_bytes]

  @type t :: %__MODULE__{
    id: Lasso.RPC.Response.id(),
    jsonrpc: String.t(),
    raw_bytes: binary()
  }

  @doc """
  Create a Success response from a parsed envelope.
  """
  @spec from_envelope(map()) :: t()
  def from_envelope(%{id: id, jsonrpc: jsonrpc, raw_bytes: raw_bytes}) do
    %__MODULE__{
      id: id,
      jsonrpc: jsonrpc,
      raw_bytes: raw_bytes
    }
  end

  @doc """
  Decode the result field from raw bytes.

  This is an EXPLICIT OPT-IN for callers that need the actual result value.
  The hot path should NEVER call this — send raw_bytes directly.

  ## When to Use

  - Health probes needing block height
  - Discovery probes inspecting response structure
  - Testing/debugging

  ## When NOT to Use

  - Forwarding responses to clients (use raw_bytes)
  - Building batch responses (use raw_bytes)
  """
  @spec decode_result(t()) :: {:ok, term()} | {:error, term()}
  def decode_result(%__MODULE__{raw_bytes: raw_bytes}) do
    case Jason.decode(raw_bytes) do
      {:ok, %{"result" => result}} -> {:ok, result}
      {:ok, _} -> {:error, :no_result_field}
      {:error, reason} -> {:error, {:decode_failed, reason}}
    end
  end

  @doc """
  Get the byte size of the raw response.

  Named `response_size` to avoid shadowing `Kernel.byte_size/1`.
  """
  @spec response_size(t()) :: non_neg_integer()
  def response_size(%__MODULE__{raw_bytes: raw_bytes}), do: byte_size(raw_bytes)
end
```

### 5.3 Error Response Struct

```elixir
defmodule Lasso.RPC.Response.Error do
  @moduledoc """
  Represents a JSON-RPC error response.

  Error responses are always fully parsed since they are small and
  require inspection for error handling, circuit breaker decisions,
  and client error formatting.
  """

  alias Lasso.JSONRPC.Error, as: JError

  @enforce_keys [:id, :jsonrpc, :error]
  defstruct [
    :id,
    :jsonrpc,
    :error,
    :raw_bytes
  ]

  @type t :: %__MODULE__{
    id: Lasso.RPC.Response.id(),
    jsonrpc: String.t(),
    error: JError.t(),
    raw_bytes: binary() | nil
  }

  @doc """
  Create an Error response from a parsed envelope.
  """
  @spec from_envelope(map()) :: t()
  def from_envelope(%{
    id: id,
    jsonrpc: jsonrpc,
    error: error_map,
    raw_bytes: raw_bytes
  }) do
    %__MODULE__{
      id: id,
      jsonrpc: jsonrpc,
      error: normalize_error(error_map),
      raw_bytes: raw_bytes
    }
  end

  @doc """
  Serialize error response to JSON bytes.
  """
  @spec to_bytes(t()) :: {:ok, binary()} | {:error, term()}
  def to_bytes(%__MODULE__{} = error) do
    response = %{
      "jsonrpc" => error.jsonrpc || "2.0",
      "id" => error.id,
      "error" => JError.to_map(error.error)
    }

    case Jason.encode(response) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, {:encode_failed, reason}}
    end
  end

  defp normalize_error(error_map) when is_map(error_map) do
    code = Map.get(error_map, "code", -32_000)
    message = Map.get(error_map, "message", "Unknown error")
    data = Map.get(error_map, "data")

    JError.new(code, message, data: data)
  end
end
```

### 5.4 Batch Response Struct

```elixir
defmodule Lasso.RPC.Response.Batch do
  @moduledoc """
  Represents a batch JSON-RPC response.

  Batch responses contain multiple Success or Error items, ordered to match
  the original request order. The `to_bytes/1` function reconstructs the
  JSON array by concatenating raw bytes, avoiding full re-serialization.

  ## Passthrough Mechanics

  For a batch where most responses are Success (passthrough-eligible):

  1. Each Success item contributes its `raw_bytes` directly
  2. Each Error item is serialized (small, fast)
  3. Items are joined with commas and wrapped in array brackets

  This means a batch with one 100MB success and one small error only
  serializes the error (~100 bytes), not the entire batch.
  """

  alias Lasso.RPC.Response.{Success, Error}

  @enforce_keys [:items, :request_ids]
  defstruct [
    :items,
    :request_ids,
    :total_byte_size
  ]

  @type item :: Success.t() | Error.t()

  @type t :: %__MODULE__{
    items: [item()],
    request_ids: [Lasso.RPC.Response.id()],
    total_byte_size: non_neg_integer() | nil
  }

  @doc """
  Build a Batch response from individual response items.

  Items are reordered to match the original request_ids order.

  ## Validations

  - Rejects duplicate response IDs (would cause silent data loss)
  - Rejects if any request_id is missing from responses
  """
  @spec build([item()], [Lasso.RPC.Response.id()]) :: {:ok, t()} | {:error, term()}
  def build(items, request_ids) when is_list(items) and is_list(request_ids) do
    # Check for duplicate response IDs
    response_ids = Enum.map(items, &item_id/1)

    case find_duplicates(response_ids) do
      [] ->
        build_batch(items, request_ids)

      duplicates ->
        {:error, {:duplicate_response_ids, duplicates}}
    end
  end

  defp build_batch(items, request_ids) do
    items_by_id = Map.new(items, fn item -> {item_id(item), item} end)

    case order_items(items_by_id, request_ids, []) do
      {:ok, ordered_items} ->
        {:ok, %__MODULE__{
          items: ordered_items,
          request_ids: request_ids,
          total_byte_size: calculate_total_size(ordered_items)
        }}

      {:error, _} = error ->
        error
    end
  end

  defp find_duplicates(ids) do
    ids
    |> Enum.frequencies()
    |> Enum.filter(fn {_id, count} -> count > 1 end)
    |> Enum.map(fn {id, _count} -> id end)
  end

  @doc """
  Serialize batch response to JSON bytes.

  Reconstructs the JSON array by concatenating raw bytes for Success items
  and encoding Error items. This is O(n) in number of items, not total bytes.
  """
  @spec to_bytes(t()) :: {:ok, binary()} | {:error, term()}
  def to_bytes(%__MODULE__{items: []}) do
    {:ok, "[]"}
  end

  def to_bytes(%__MODULE__{items: items}) do
    case serialize_items(items, []) do
      {:ok, serialized_items} ->
        {:ok, "[" <> Enum.join(serialized_items, ",") <> "]"}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Count how many items in the batch used passthrough.
  """
  @spec passthrough_count(t()) :: non_neg_integer()
  def passthrough_count(%__MODULE__{items: items}) do
    Enum.count(items, fn
      %Success{} -> true
      _ -> false
    end)
  end

  # Private implementation

  defp item_id(%Success{id: id}), do: id
  defp item_id(%Error{id: id}), do: id

  defp order_items(_items_by_id, [], acc), do: {:ok, Enum.reverse(acc)}

  defp order_items(items_by_id, [id | rest], acc) do
    case Map.fetch(items_by_id, id) do
      {:ok, item} ->
        order_items(items_by_id, rest, [item | acc])

      :error ->
        {:error, {:missing_response_for_id, id}}
    end
  end

  defp serialize_items([], acc), do: {:ok, Enum.reverse(acc)}

  defp serialize_items([%Success{raw_bytes: bytes} | rest], acc) do
    serialize_items(rest, [bytes | acc])
  end

  defp serialize_items([%Error{} = error | rest], acc) do
    case Error.to_bytes(error) do
      {:ok, bytes} ->
        serialize_items(rest, [bytes | acc])

      {:error, _} = err ->
        err
    end
  end

  defp calculate_total_size(items) do
    Enum.reduce(items, 0, fn
      %Success{} = success, acc -> acc + Success.response_size(success)
      %Error{raw_bytes: bytes}, acc when is_binary(bytes) -> acc + byte_size(bytes)
      _, acc -> acc
    end)
  end
end
```

---

## 6. Module Architecture

### 6.1 Module Dependency Graph

```
                    ┌──────────────────────┐
                    │   RPCController /    │
                    │     RPCSocket        │
                    └──────────┬───────────┘
                               │
                               ▼
                    ┌──────────────────────┐
                    │  Lasso.RPC.Response  │ ◄── Unified response types
                    └──────────┬───────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
              ▼                ▼                ▼
    ┌─────────────────┐ ┌────────────┐ ┌──────────────────┐
    │ Response.Success│ │Response.   │ │ Response.Batch   │
    │                 │ │Error       │ │                  │
    └────────┬────────┘ └─────┬──────┘ └────────┬─────────┘
             │                │                  │
             └────────────────┼──────────────────┘
                              │
                              ▼
                    ┌──────────────────────┐
                    │ Lasso.RPC.Passthrough│ ◄── Coordination logic
                    └──────────┬───────────┘
                               │
                               ▼
                    ┌──────────────────────┐
                    │Lasso.RPC.EnvelopeParser│ ◄── Fast parsing
                    └──────────────────────┘
```

### 6.2 Module Responsibilities

| Module             | Responsibility                                        |
| ------------------ | ----------------------------------------------------- |
| `Response`         | Type definitions, factory functions, serialization    |
| `Response.Success` | Success response struct, `decode_result/1` for opt-in |
| `Response.Error`   | Error response struct, JError integration             |
| `Response.Batch`   | Batch handling, array reconstruction from raw bytes   |
| `EnvelopeParser`   | Fast envelope-only parsing, metadata extraction       |

---

## 7. Implementation Specification

The implementation is straightforward since the core logic lives in `Response.from_bytes/1`.
The transport layer calls this function and returns the structured response.

**Key principle**: No separate "Passthrough" coordinator module is needed. The `Response` module
handles parsing, and callers use `Response.Success.decode_result/1` when they need the actual value.

### 7.1 EnvelopeParser Limitations

The `EnvelopeParser` scans only the first 2000 bytes of a response to find envelope keys.
This is a deliberate trade-off for performance:

| Characteristic | Value | Implication |
|----------------|-------|-------------|
| Scan window | 2000 bytes | Keys must appear within first 2KB |
| Max ID length | ~1500 chars | IDs longer than this may cause parse failure |
| Key order | Any | Handles `result`, `id`, `jsonrpc` in any order |

**When might this fail?**

- Response IDs exceeding ~1500 characters (extremely rare in practice)
- Providers that include large metadata before standard envelope keys

**If a parse fails due to scan limits**, the error is returned to the caller. This is acceptable
because such responses indicate either a provider bug or an attack vector (e.g., malicious
giant IDs to exhaust resources).

### 7.2 EnvelopeParser Defensive Guards

The `EnvelopeParser` has comprehensive defensive guards that handle all malformed input
without raising exceptions:

| Guard | Protection | Error Returned |
|-------|------------|----------------|
| `@max_batch_items 10_000` | Prevents stack overflow on huge batches | `{:error, :batch_too_large}` |
| `@max_object_depth 100` | Prevents stack overflow on deeply nested errors | `{:error, :malformed_error_object}` |
| `@scan_limit 2000` | Bounds envelope key scanning | `{:error, :no_result_or_error}` |
| `binary_at_safe/2` | Safe byte access with bounds checking | `{:error, :invalid_batch}` |
| Non-binary guards | Rejects non-binary input | `{:error, :invalid_input}` |
| Escape sequence bounds | Checks `pos + 1 < len` before advancing | `{:error, :unterminated_string}` |

**Why no `rescue` wrapper is needed:**

Per BEAM expert review, the existing guards are sufficient. All code paths return
`{:ok, _}` or `{:error, _}` tuples. A blanket `rescue _ ->` would:
1. Hide bugs that should be fixed
2. Catch exits/kills that shouldn't be caught
3. Lose diagnostic information

If a crash occurs, it indicates a bug in the parser that should be fixed, not masked.

### 7.3 EnvelopeParser Zero-Copy Batch Support (IMPLEMENTED)

Batch responses require splitting the top-level JSON array without parsing result values.
The naive approach (decode entire array, re-encode each item) defeats the optimization.

**Implementation**: See `lib/lasso/rpc/envelope_parser.ex` - `parse_batch/1` function.

**Algorithm overview:**

```elixir
@doc """
Parse JSON-RPC batch response without parsing individual result values.

Returns a list of envelope metadata for each item in the batch array.
Uses zero-copy slicing to extract items without duplicating the original binary.
"""
@spec parse_batch(binary()) :: {:ok, [envelope()]} | {:error, atom()}
def parse_batch(json_bytes) when is_binary(json_bytes) do
  case split_batch_items(json_bytes) do
    {:ok, item_slices} ->
      # Parse each item slice (each gets zero-copy treatment)
      results = Enum.map(item_slices, &parse/1)

      if Enum.all?(results, &match?({:ok, _}, &1)) do
        {:ok, Enum.map(results, fn {:ok, env} -> env end)}
      else
        # Return first error encountered
        Enum.find(results, &match?({:error, _}, &1))
      end

    {:error, _} = err -> err
  end
end
```

**Key implementation details:**

1. **Depth tracking at 0** - Split on commas when `depth == 0` (top-level array)
2. **String-aware scanning** - Toggle `in_string` flag on unescaped quotes
3. **Escape sequence bounds check** - Verify `pos + 1 < len` before advancing by 2
4. **Whitespace trimming** - Trim leading/trailing whitespace from each item slice
5. **Trailing comma handling** - Skip empty items gracefully
6. **Max items guard** - Return `{:error, :batch_too_large}` if > 10,000 items

**Error codes:**

| Error | Meaning |
|-------|---------|
| `:not_a_batch_array` | Input doesn't start with `[` |
| `:unterminated_batch` | No closing `]` found |
| `:batch_too_large` | Exceeds 10,000 items |
| `:unterminated_string` | Unclosed string in batch |
| `:no_result_or_error` | Item missing result/error key |

**Why zero-copy matters for batches:**

| Scenario | Naive (decode+re-encode) | Zero-copy split |
|----------|--------------------------|-----------------|
| 10 items, 1 large (50MB) | ~500ms (decode entire batch) | ~0.003ms per item |
| 50 items, all small | ~5ms | ~0.15ms |
| Memory allocation | Full batch decoded to heap | Only byte references |

**Complexity analysis:**
- Time: O(n) where n = total bytes (single scan)
- Space: O(m) where m = number of items (just offset tuples)
- Each item slice is a reference to the original binary (BEAM refc binary)

---

## 8. Batch Request Support

### 8.1 Batch Processing Flow

```
Client Request: [{"id":1,"method":"eth_blockNumber"}, {"id":2,"method":"eth_getLogs",...}]
                                      │
                                      ▼
                         ┌────────────────────────┐
                         │  Parse batch request   │
                         │  Extract request IDs   │
                         └───────────┬────────────┘
                                     │
                    ┌────────────────┴────────────────┐
                    │                                 │
                    ▼                                 ▼
          ┌─────────────────┐               ┌─────────────────┐
          │ Route request 1 │               │ Route request 2 │
          │ (Provider A)    │               │ (Provider B)    │
          └────────┬────────┘               └────────┬────────┘
                   │                                 │
                   ▼                                 ▼
          Provider A returns:               Provider B returns:
          {"id":1,"result":"0x123"}         {"id":2,"result":[...100MB...]}
          (42 bytes)                        (100MB)
                   │                                 │
                   ▼                                 ▼
          ┌─────────────────┐               ┌─────────────────┐
          │ EnvelopeParser  │               │ EnvelopeParser  │
          │ extract id: 1   │               │ extract id: 2   │
          │ type: :result   │               │ type: :result   │
          └────────┬────────┘               └────────┬────────┘
                   │                                 │
                   └────────────────┬────────────────┘
                                    │
                                    ▼
                         ┌────────────────────────┐
                         │   Batch.build/2        │
                         │   Correlate by ID      │
                         │   Order by request     │
                         └───────────┬────────────┘
                                     │
                                     ▼
                         ┌────────────────────────┐
                         │   Batch.to_bytes/1     │
                         │   "[" ++ raw1 ++ ","   │
                         │       ++ raw2 ++ "]"   │
                         └───────────┬────────────┘
                                     │
                                     ▼
Client Response: [{"id":1,"result":"0x123"},{"id":2,"result":[...100MB...]}]
                 ▲                          ▲
                 │                          │
            42 bytes copied            100MB passed through
            (or passed through)        (zero-copy!)
```

### 8.2 Batch Reconstruction Algorithm

```elixir
@doc """
Reconstruct batch response array from individual response items.

Time complexity: O(n) where n is number of items
Space complexity: O(1) additional (raw bytes are not copied)
"""
@spec reconstruct_batch([Success.t() | Error.t()], [Response.id()]) :: binary()
def reconstruct_batch(items, request_ids) do
  # Build ID -> item lookup (O(n))
  items_by_id = Map.new(items, &{item_id(&1), &1})

  # Order items and serialize (O(n))
  serialized =
    request_ids
    |> Enum.map(fn id ->
      case Map.fetch!(items_by_id, id) do
        %Success{raw_bytes: bytes} -> bytes  # Zero-copy reference
        %Error{} = error -> Jason.encode!(Error.to_map(error))  # Small, fast
      end
    end)

  # Join with array syntax (O(n) in items, not bytes)
  "[" <> Enum.join(serialized, ",") <> "]"
end
```

### 8.3 Mixed Provider Batch Handling

When batch requests route to different providers:

```elixir
defmodule Lasso.RPC.BatchExecutor do
  @moduledoc """
  Executes batch requests with passthrough-aware response collection.
  """

  alias Lasso.RPC.{Passthrough, Response}
  alias Lasso.RPC.Response.Batch

  @doc """
  Execute a batch of RPC requests, collecting responses with passthrough.

  Each request may route to a different provider based on strategy.
  Responses are collected as raw bytes and parsed with EnvelopeParser.
  """
  @spec execute_batch([map()], keyword()) :: {:ok, Batch.t()} | {:error, term()}
  def execute_batch(requests, opts) do
    request_ids = Enum.map(requests, & &1["id"])

    # Execute requests (existing pipeline logic)
    raw_responses = execute_requests_parallel(requests, opts)

    # Parse with passthrough optimization
    Passthrough.parse_batch_responses(raw_responses, request_ids: request_ids)
  end

  defp execute_requests_parallel(requests, opts) do
    requests
    |> Task.async_stream(
      fn request -> execute_single_request(request, opts) end,
      max_concurrency: Keyword.get(opts, :max_concurrency, 10),
      timeout: Keyword.get(opts, :timeout, 30_000)
    )
    |> Enum.map(fn
      {:ok, {:ok, raw_bytes}} -> raw_bytes
      {:ok, {:error, reason}} -> build_error_response(reason)
      {:exit, reason} -> build_error_response({:task_exit, reason})
    end)
  end

  defp execute_single_request(request, opts) do
    # Delegate to existing RequestPipeline
    # Returns {:ok, raw_bytes} or {:error, reason}
    Lasso.RPC.RequestPipeline.execute_raw(request, opts)
  end

  defp build_error_response(reason) do
    error = Lasso.JSONRPC.Error.from(reason)
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => nil,
      "error" => Lasso.JSONRPC.Error.to_map(error)
    })
  end
end
```

---

## 9. Transport Layer Changes

### 9.1 HTTP Transport (Finch Adapter)

**File**: `lib/lasso/core/transport/http/adapters/finch.ex`

```elixir
# Current implementation (line 105-124):
defp handle_response(status, body) when status in 200..299 do
  case Jason.decode(body) do
    {:ok, %{"error" => error} = response} when is_map(error) ->
      {:ok, response}
    {:ok, %{"result" => _} = response} ->
      {:ok, response}
    # ...
  end
end

# New implementation with passthrough:
defp handle_response(status, body) when status in 200..299 do
  # Return raw bytes - let caller decide on passthrough vs full parse
  {:ok, {:raw, body}}
end

defp handle_response(status, body) when status in 400..499 do
  # Client errors - parse to extract error details
  case Jason.decode(body) do
    {:ok, %{"error" => _} = response} -> {:error, response}
    _ -> {:error, {:http_error, status, body}}
  end
end

defp handle_response(status, body) when status >= 500 do
  {:error, {:http_error, status, body}}
end
```

### 9.2 HTTP Transport Layer

**File**: `lib/lasso/core/transport/http/http.ex`

```elixir
# Current (line 59-95):
def request(endpoint, rpc_request, timeout) do
  # ... setup ...
  case HttpClient.request(method, url, headers, body, adapter_opts) do
    {:ok, response, io_ms} ->
      case response do
        %{"result" => result} -> {:ok, result, io_ms}
        %{"error" => _} = err -> {:error, err, io_ms}
      end
    # ...
  end
end

# New implementation:
@doc """
Execute HTTP request, returning raw response bytes for passthrough.

The caller is responsible for parsing the response using Passthrough module.
This enables zero-copy transmission for large responses.
"""
@spec request(Endpoint.t(), map(), timeout()) ::
  {:ok, {:raw, binary()}, number()} |
  {:ok, {:parsed, map()}, number()} |
  {:error, term(), number()}
def request(endpoint, rpc_request, timeout) do
  url = endpoint.http_url

  if is_nil(url) do
    {:error, JError.new(-32_000, "No HTTP URL configured", category: :config_error)}
  else
    headers = build_headers(endpoint)
    body = Jason.encode!(rpc_request)
    adapter_opts = [receive_timeout: timeout]

    case HttpClient.request(:post, url, headers, body, adapter_opts) do
      {:ok, {:raw, raw_bytes}, io_ms} ->
        # Return raw bytes for passthrough-aware caller
        {:ok, {:raw, raw_bytes}, io_ms}

      {:ok, {:parsed, response}, io_ms} ->
        # Already parsed (e.g., error response)
        {:ok, {:parsed, response}, io_ms}

      {:error, reason, io_ms} ->
        {:error, reason, io_ms}

      {:error, reason} ->
        {:error, reason, 0}
    end
  end
end
```

### 9.3 Channel Integration

**File**: `lib/lasso/core/transport/channel.ex`

```elixir
@doc """
Execute request on channel, returning Response struct.

For HTTP channels, returns raw bytes eligible for passthrough.
For WebSocket channels, returns parsed response (existing behavior).
"""
@spec request(t(), map(), timeout()) ::
  {:ok, Response.t(), number()} | {:error, term(), number()}
def request(%__MODULE__{transport: :http} = channel, rpc_request, timeout) do
  case HTTP.request(channel.endpoint, rpc_request, timeout) do
    {:ok, {:raw, raw_bytes}, io_ms} ->
      case Response.from_bytes(raw_bytes) do
        {:ok, response} -> {:ok, response, io_ms}
        {:error, reason} -> {:error, reason, io_ms}
      end

    {:error, reason, io_ms} ->
      {:error, reason, io_ms}
  end
end

def request(%__MODULE__{transport: :ws} = channel, rpc_request, timeout) do
  # WebSocket implementation - Phase 2, currently returns raw bytes
  case WebSocket.request(channel.endpoint, rpc_request, timeout) do
    {:ok, raw_bytes, io_ms} ->
      case Response.from_bytes(raw_bytes) do
        {:ok, response} -> {:ok, response, io_ms}
        {:error, reason} -> {:error, reason, io_ms}
      end

    {:error, reason, io_ms} ->
      {:error, reason, io_ms}
  end
end
```

### 9.4 WebSocket Transport

**File**: `lib/lasso/core/transport/websocket/handler.ex`

```elixir
# Current (line 44-57):
def handle_frame({:text, message}, state) do
  case Jason.decode(message) do
    {:ok, decoded} ->
      send(state.owner, {:ws_message, decoded, state.endpoint})
      {:ok, state}
    # ...
  end
end

# New implementation with passthrough:
def handle_frame({:text, message}, state) do
  case Response.from_bytes(message) do
    {:ok, response} ->
      send(state.owner, {:ws_response, response, state.endpoint})
      {:ok, state}

    {:error, reason} ->
      {:error, reason}
  end
end
```

---

## 10. Observability Adaptations

### 10.1 RequestContext Modifications

**File**: `lib/lasso/core/request/request_context.ex`

```elixir
@doc """
Record successful result with Response struct.

Uses byte_size from raw_bytes directly - no re-encoding needed.
"""
@spec record_success(t(), Response.Success.t()) :: t()
def record_success(%__MODULE__{} = ctx, %Response.Success{} = response) do
  now = System.monotonic_time(:microsecond)
  end_to_end_ms = (now - ctx.start_time) / 1000.0

  %{ctx |
    status: :success,
    result_size_bytes: Response.Success.response_size(response),
    end_to_end_latency_ms: end_to_end_ms,
    lasso_overhead_ms: calculate_overhead(end_to_end_ms, ctx.upstream_latency_ms)
  }
end

defp calculate_overhead(end_to_end_ms, nil), do: nil
defp calculate_overhead(end_to_end_ms, upstream_ms), do: end_to_end_ms - upstream_ms
```

---

## 11. Result Decoding Touchpoints

This section catalogs every location in the codebase that accesses the `result` field from JSON-RPC responses. Each touchpoint is categorized and annotated with migration requirements.

### 11.1 Touchpoint Categories

| Category              | Description                  | Migration Approach             |
| --------------------- | ---------------------------- | ------------------------------ |
| **Hot Path**          | Client request/response flow | Use passthrough, NO decode     |
| **Cold Path - Probe** | Health/discovery probes      | Call `decode_result/1`         |
| **Cold Path - Test**  | Test utilities               | Call `decode_result/1`         |
| **Adapter**           | Provider normalization       | Skip for passthrough responses |
| **Subscription**      | WebSocket events             | Separate path, low volume      |

### 11.2 Hot Path Touchpoints (NO DECODE)

These are the critical performance paths. After migration, none should decode results.

#### 11.2.1 HTTP Transport Result Extraction

**File**: `lib/lasso/core/transport/http/http.ex:83`

```elixir
# CURRENT
{:ok, %{"result" => result}} -> {:ok, result, io_ms}

# AFTER MIGRATION
{:ok, %Response.Success{} = resp} -> {:ok, resp, io_ms}
```

**Impact**: Core HTTP response path. Returns Response struct instead of decoded result.

#### 11.2.2 Finch Adapter Response Validation

**File**: `lib/lasso/core/transport/http/adapters/finch.ex:114`

```elixir
# CURRENT
{:ok, %{"result" => _} = response} -> {:ok, response}

# AFTER MIGRATION
# EnvelopeParser detects result vs error - no pattern match needed
{:ok, {:raw, bytes}} -> {:ok, {:raw, bytes}}
```

**Impact**: Response validation moves to EnvelopeParser.

#### 11.2.3 WebSocket Connection Result Extraction

**File**: `lib/lasso/core/transport/websocket/connection.ex:382`

```elixir
# CURRENT
%{"result" => result} -> {:ok, result}

# AFTER MIGRATION (Phase 2)
%Response.Success{} = resp -> {:ok, resp}
```

**Impact**: WebSocket path. Phase 2 implementation.

#### 11.2.4 Provider Adapter Normalization

**File**: `lib/lasso/core/providers/adapters/generic.ex:39`

```elixir
# CURRENT
def normalize_response(%{"result" => result}, _ctx), do: {:ok, result}

# AFTER MIGRATION
def normalize_response(%Response.Success{} = resp, _ctx), do: {:ok, resp}
```

**Impact**: Provider adapters pass through the Response struct unchanged. No decoding or normalization needed - the adapter's job is just to forward the response.

#### 11.2.5 RPC Socket Response Building

**File**: `lib/lasso_web/sockets/rpc_socket.ex:238`

```elixir
# CURRENT
response = %{"jsonrpc" => "2.0", "id" => id, "result" => result}
{:reply, :ok, {:text, Jason.encode!(response)}, new_state}

# AFTER MIGRATION
%Response.Success{raw_bytes: bytes} = result
{:reply, :ok, {:text, bytes}, new_state}
```

**Impact**: Send raw bytes directly to client.

### 11.3 Cold Path Touchpoints (DECODE REQUIRED)

These paths legitimately need decoded results. Use `decode_result/1`.

#### 10.3.1 Provider Probe - Block Height

**File**: `lib/lasso/core/providers/provider_probe.ex:164`

```elixir
# CURRENT
case Channel.request(channel, rpc_request, 3_000) do
  {:ok, "0x" <> hex, _io_ms} ->
    height = String.to_integer(hex, 16)

# AFTER MIGRATION
case Channel.request(channel, rpc_request, 3_000) do
  {:ok, %Response.Success{} = resp, _io_ms} ->
    case Response.Success.decode_result(resp) do
      {:ok, "0x" <> hex} ->
        height = String.to_integer(hex, 16)
        %{success?: true, block_height: height, ...}
      {:ok, other} ->
        %{success?: false, error: {:unexpected_result, other}}
      {:error, reason} ->
        %{success?: false, error: {:decode_failed, reason}}
    end
```

**Impact**: Explicit decode for block height extraction. Small response, decode is cheap.

#### 10.3.2 Discovery Probes - Limits

**File**: `lib/lasso/discovery/probes/limits.ex` (multiple locations)

| Line | Current Pattern               | Migration                         |
| ---- | ----------------------------- | --------------------------------- |
| 114  | `{:ok, %{"result" => _}}`     | Check `%Response.Success{}`       |
| 145  | `{:ok, %{"result" => _}}`     | Check `%Response.Success{}`       |
| 174  | `{:ok, %{"result" => _}}`     | Check `%Response.Success{}`       |
| 274  | `{:ok, %{"result" => block}}` | `decode_result/1` → inspect block |
| 297  | `{:ok, %{"result" => block}}` | `decode_result/1` → inspect block |
| 307  | `{:ok, %{"result" => nil}}`   | `decode_result/1` → check nil     |
| 329  | `{:ok, %{"result" => _}}`     | Check `%Response.Success{}`       |
| 380  | `{:ok, %{"result" => hex}}`   | `decode_result/1` → parse hex     |

**Impact**: Discovery probes run infrequently (startup/periodic). Decode is acceptable.

#### 10.3.3 Discovery Probes - Method Support

**File**: `lib/lasso/discovery/probes/method_support.ex:197`

```elixir
# CURRENT
{:ok, %{"result" => _result}} -> :supported

# AFTER MIGRATION
{:ok, %Response.Success{}} -> :supported
```

**Impact**: Only checks for success, doesn't need result value. No decode needed.

#### 10.3.4 Discovery Probes - WebSocket

**File**: `lib/lasso/discovery/probes/websocket.ex:299,305`

```elixir
# Line 299 - subscription confirmation
{:ok, %{"id" => id, "result" => result}} when is_integer(id) ->

# Line 305 - subscription event
{:ok, %{"method" => "eth_subscription", "params" => %{"subscription" => sub_id, "result" => event}}}
```

**Impact**: WebSocket discovery probes. Low volume, decode acceptable.

### 11.4 Test/Battle Touchpoints (DECODE REQUIRED)

Test utilities that inspect results. Decode is appropriate.

#### 10.4.1 Battle Test Helper

**File**: `lib/lasso_battle/test_helper.ex:90`

```elixir
{:ok, %{"result" => result}} -> {:ok, result}
```

**Impact**: Test utility. Decode appropriate.

#### 10.4.2 Battle Workload

**File**: `lib/lasso_battle/workload.ex:96,452`

```elixir
# Line 96
{:ok, %{"result" => result}} -> {:ok, result}

# Line 452
{:ok, %{"result" => _}} -> :success
```

**Impact**: Load testing utilities. Decode appropriate.

#### 10.4.3 Battle WebSocket Client

**File**: `lib/lasso_battle/websocket_client.ex:65,171`

```elixir
# Line 65 - subscription ID extraction
{:ok, %{"id" => _id, "result" => subscription_id}}

# Line 171 - subscription event handling
defp handle_subscription_event(%{"subscription" => _sub_id, "result" => result}, state)
```

**Impact**: Test WebSocket client. Decode appropriate.

### 11.5 Subscription Path Touchpoints

WebSocket subscription events have their own path.

#### 10.5.1 Client Subscription Registry

**File**: `lib/lasso/core/streaming/client_subscription_registry.ex:119`

```elixir
"result" => payload
```

**Impact**: Subscription event forwarding. Events are typically small. Consider passthrough in future.

#### 10.5.2 WebSocket Connection - Subscription Events

**File**: `lib/lasso/core/transport/websocket/connection.ex:911`

```elixir
"params" => %{"subscription" => sub_id, "result" => payload}
```

**Impact**: Upstream subscription event handling. Separate from request/response path.

### 11.6 Observability Touchpoints

Telemetry and metrics that reference results.

#### 11.6.1 Telemetry Metadata

**File**: `lib/lasso/observability/telemetry.ex:355,366`

```elixir
result: metadata.result
```

**Impact**: Telemetry emission. With passthrough, `result` becomes `Response.Success` struct. Observability uses `byte_size(response.raw_bytes)` for result size.

### 11.7 Migration Checklist

| File                       | Line(s)  | Category      | Action                             | Priority |
| -------------------------- | -------- | ------------- | ---------------------------------- | -------- |
| `http.ex`                  | 83       | Hot Path      | Return Response struct             | P0       |
| `finch.ex`                 | 114      | Hot Path      | Return raw bytes                   | P0       |
| `generic.ex`               | 39       | Adapter       | Pass through Response struct       | P0       |
| `rpc_socket.ex`            | 238      | Hot Path      | Send raw bytes                     | P0       |
| `provider_probe.ex`        | 164      | Cold Path     | Add `decode_result/1`              | P0       |
| `connection.ex`            | 382      | Hot Path      | Return Response struct (Phase 2)   | P1       |
| `limits.ex`                | Multiple | Cold Path     | Add `decode_result/1` where needed | P1       |
| `method_support.ex`        | 197      | Cold Path     | Pattern match only                 | P1       |
| `telemetry.ex`             | 355,366  | Observability | Adapt to Response struct           | P1       |
| `websocket.ex` (discovery) | 299,305  | Cold Path     | Add `decode_result/1`              | P2       |
| `test_helper.ex`           | 90       | Test          | Add `decode_result/1`              | P2       |
| `workload.ex`              | 96,452   | Test          | Add `decode_result/1`              | P2       |
| `websocket_client.ex`      | 65,171   | Test          | Add `decode_result/1`              | P2       |

---

## 12. Error Handling

### 12.1 Error Response Handling

Error responses from providers are always fully parsed by the EnvelopeParser (they're small).
The existing circuit breaker and error handling logic continues to work unchanged:

```elixir
case Response.from_bytes(raw_bytes) do
  {:ok, %Response.Success{} = resp} ->
    CircuitBreaker.record_success(cb_id)
    {:ok, resp, io_ms}

  {:ok, %Response.Error{error: jerr} = resp} ->
    CircuitBreaker.record_failure(cb_id, jerr)
    {:error, resp, io_ms}

  {:error, reason} ->
    # EnvelopeParser couldn't parse - upstream provider fault
    {:error, reason, io_ms}
end
```

### 12.2 Design Decision: No Fallback Path

If `EnvelopeParser.parse/1` fails on a response, we return the error rather than
falling back to full JSON parsing. Rationale:

1. **If the provider sent valid JSON-RPC, our parser should handle it** - a parse failure indicates a bug in EnvelopeParser
2. **Simpler code paths** - one path, not two
3. **Fail fast** - surface parser bugs in testing rather than hiding them with fallback

---

## 13. Testing Strategy

### 13.1 Unit Tests

```elixir
defmodule Lasso.RPC.ResponseTest do
  use ExUnit.Case, async: true

  alias Lasso.RPC.Response
  alias Lasso.RPC.Response.{Success, Error, Batch}

  describe "Response.from_bytes/1" do
    test "parses success response" do
      raw = ~s({"jsonrpc":"2.0","id":1,"result":"0x123"})

      assert {:ok, %Success{} = resp} = Response.from_bytes(raw)
      assert resp.id == 1
      assert resp.jsonrpc == "2.0"
      assert resp.raw_bytes == raw
    end

    test "parses error response fully" do
      raw = ~s({"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"Invalid"}})

      assert {:ok, %Error{} = resp} = Response.from_bytes(raw)
      assert resp.id == 1
      assert resp.error.code == -32600
      assert resp.error.message == "Invalid"
    end

    test "handles large array result" do
      large_array = "[" <> String.duplicate("1,", 1_000_000) <> "1]"
      raw = ~s({"jsonrpc":"2.0","id":1,"result":#{large_array}})

      assert {:ok, %Success{} = resp} = Response.from_bytes(raw)
      assert Success.response_size(resp) > 1_000_000
    end

    test "handles various key orderings" do
      orderings = [
        ~s({"jsonrpc":"2.0","id":1,"result":"ok"}),
        ~s({"result":"ok","jsonrpc":"2.0","id":1}),
        ~s({"id":1,"result":"ok","jsonrpc":"2.0"}),
        ~s({"result":"ok","id":1,"jsonrpc":"2.0"})
      ]

      for raw <- orderings do
        assert {:ok, %Success{id: 1}} = Response.from_bytes(raw)
      end
    end
  end

  describe "Success.decode_result/1" do
    test "decodes result when explicitly called" do
      raw = ~s({"jsonrpc":"2.0","id":1,"result":"0x123"})
      {:ok, resp} = Response.from_bytes(raw)

      assert {:ok, "0x123"} = Success.decode_result(resp)
    end

    test "decodes complex result" do
      raw = ~s({"jsonrpc":"2.0","id":1,"result":{"hash":"0xabc","number":123}})
      {:ok, resp} = Response.from_bytes(raw)

      assert {:ok, %{"hash" => "0xabc", "number" => 123}} = Success.decode_result(resp)
    end
  end

  describe "Batch.to_bytes/1" do
    test "reconstructs JSON array from raw bytes" do
      items = [
        %Success{id: 1, jsonrpc: "2.0", raw_bytes: ~s({"jsonrpc":"2.0","id":1,"result":"0x123"})},
        %Success{id: 2, jsonrpc: "2.0", raw_bytes: ~s({"jsonrpc":"2.0","id":2,"result":[1,2,3]})}
      ]

      {:ok, batch} = Batch.build(items, [1, 2])
      {:ok, bytes} = Batch.to_bytes(batch)

      assert {:ok, decoded} = Jason.decode(bytes)
      assert is_list(decoded)
      assert length(decoded) == 2
    end
  end
end
```

### 13.2 Property-Based Tests

Property tests verify **correctness invariants** across a wide range of inputs.
These are not performance tests - they validate algorithmic correctness.

```elixir
defmodule Lasso.RPC.ResponsePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Lasso.RPC.Response
  alias Lasso.RPC.Response.{Success, Batch}
  alias Lasso.RPC.EnvelopeParser

  # ============================================================
  # INVARIANT 1: Raw bytes preservation (bit-for-bit identical)
  # ============================================================

  property "passthrough preserves raw bytes exactly" do
    check all id <- id_generator(),
              result <- json_result_generator() do
      response = %{"jsonrpc" => "2.0", "id" => id, "result" => result}
      raw = Jason.encode!(response)

      {:ok, %Success{raw_bytes: bytes}} = Response.from_bytes(raw)
      assert bytes == raw, "raw_bytes must be bit-for-bit identical to input"
    end
  end

  # ============================================================
  # INVARIANT 2: decode_result matches full JSON decode
  # ============================================================

  property "decode_result matches full JSON decode" do
    check all id <- id_generator(),
              result <- json_result_generator() do
      response = %{"jsonrpc" => "2.0", "id" => id, "result" => result}
      raw = Jason.encode!(response)

      {:ok, success} = Response.from_bytes(raw)
      {:ok, decoded_result} = Success.decode_result(success)

      {:ok, full_decode} = Jason.decode(raw)
      assert decoded_result == full_decode["result"]
    end
  end

  # ============================================================
  # INVARIANT 3: Parsed ID matches decoded ID
  # ============================================================

  property "parsed ID matches ID in raw bytes" do
    check all id <- id_generator(),
              result <- json_result_generator() do
      response = %{"jsonrpc" => "2.0", "id" => id, "result" => result}
      raw = Jason.encode!(response)

      {:ok, success} = Response.from_bytes(raw)
      {:ok, full_decode} = Jason.decode(raw)

      assert success.id == full_decode["id"]
    end
  end

  # ============================================================
  # INVARIANT 4: EnvelopeParser never crashes (returns error tuple)
  # ============================================================

  property "EnvelopeParser.parse never raises on any binary input" do
    check all bytes <- binary(min_length: 0, max_length: 5000) do
      result = EnvelopeParser.parse(bytes)

      assert match?({:ok, _}, result) or match?({:error, _}, result),
        "parse must return {:ok, _} or {:error, _}, got: #{inspect(result)}"
    end
  end

  property "EnvelopeParser.parse_batch never raises on any binary input" do
    check all bytes <- binary(min_length: 0, max_length: 5000) do
      result = EnvelopeParser.parse_batch(bytes)

      assert match?({:ok, _}, result) or match?({:error, _}, result),
        "parse_batch must return {:ok, _} or {:error, _}, got: #{inspect(result)}"
    end
  end

  # ============================================================
  # INVARIANT 5: Batch split preserves item bytes exactly
  # ============================================================

  property "batch parse returns items with identical bytes to originals" do
    check all items <- list_of(json_rpc_response_generator(), min_length: 1, max_length: 10) do
      # Build batch array manually
      batch_json = "[" <> Enum.join(items, ",") <> "]"

      case EnvelopeParser.parse_batch(batch_json) do
        {:ok, envelopes} ->
          assert length(envelopes) == length(items)

          # Each envelope's raw_bytes should match the original item
          Enum.zip(envelopes, items)
          |> Enum.each(fn {envelope, original_item} ->
            assert envelope.raw_bytes == original_item,
              "Item bytes must be preserved exactly"
          end)

        {:error, reason} ->
          flunk("parse_batch failed unexpectedly: #{inspect(reason)}")
      end
    end
  end

  # ============================================================
  # INVARIANT 6: Batch reconstruction produces valid JSON
  # ============================================================

  property "batch reconstruction produces valid JSON array" do
    check all results <- list_of(json_result_generator(), min_length: 1, max_length: 10) do
      {items, ids} =
        results
        |> Enum.with_index(1)
        |> Enum.map(fn {result, idx} ->
          raw = Jason.encode!(%{"jsonrpc" => "2.0", "id" => idx, "result" => result})
          {:ok, success} = Response.from_bytes(raw)
          {success, idx}
        end)
        |> Enum.unzip()

      {:ok, batch} = Batch.build(items, ids)
      {:ok, bytes} = Batch.to_bytes(batch)

      assert {:ok, decoded} = Jason.decode(bytes), "Batch output must be valid JSON"
      assert is_list(decoded)
      assert length(decoded) == length(results)
    end
  end

  # ============================================================
  # INVARIANT 7: Key order independence
  # ============================================================

  property "parse succeeds regardless of JSON key order" do
    check all id <- id_generator(),
              result <- json_result_generator(),
              key_order <- member_of([:standard, :result_first, :id_first]) do
      response = case key_order do
        :standard ->
          ~s({"jsonrpc":"2.0","id":#{Jason.encode!(id)},"result":#{Jason.encode!(result)}})
        :result_first ->
          ~s({"result":#{Jason.encode!(result)},"jsonrpc":"2.0","id":#{Jason.encode!(id)}})
        :id_first ->
          ~s({"id":#{Jason.encode!(id)},"result":#{Jason.encode!(result)},"jsonrpc":"2.0"})
      end

      assert {:ok, envelope} = EnvelopeParser.parse(response)
      assert envelope.id == id
      assert envelope.type == :result
    end
  end

  # ============================================================
  # Generators
  # ============================================================

  # ID generator: integers and strings (JSON-RPC allows both)
  defp id_generator do
    one_of([
      integer(-1_000_000..1_000_000),
      string(:alphanumeric, min_length: 1, max_length: 50),
      # Include some edge cases
      constant(0),
      constant(-1),
      constant(nil)
    ])
  end

  # Result generator: varied JSON values
  defp json_result_generator do
    # Use frequency to weight common cases
    frequency([
      {30, constant(nil)},
      {20, boolean()},
      {20, integer()},
      {15, string(:printable, max_length: 200)},
      {10, list_of(integer(), max_length: 50)},
      {5, nested_object_generator()}
    ])
  end

  # Generate nested objects (common in eth_getLogs results)
  defp nested_object_generator do
    map_of(
      string(:alphanumeric, min_length: 1, max_length: 20),
      one_of([
        integer(),
        string(:alphanumeric, max_length: 66),  # hex strings like tx hashes
        boolean(),
        constant(nil)
      ]),
      max_keys: 10
    )
  end

  # Generate complete JSON-RPC response strings
  defp json_rpc_response_generator do
    gen all id <- integer(1..1000),
            result <- json_result_generator() do
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
    end
  end
end
```

**What these tests verify:**

| Property | Invariant | Why It Matters |
|----------|-----------|----------------|
| Raw bytes preservation | `raw_bytes == input` | Zero-copy correctness |
| Decode roundtrip | `decode_result == Jason.decode["result"]` | Lazy decode correctness |
| ID parsing | `parsed_id == decoded_id` | Request correlation |
| Never crashes | Returns `{:ok, _}` or `{:error, _}` | Robustness to malformed input |
| Batch item preservation | Each item's bytes unchanged | Batch passthrough correctness |
| Batch reconstruction | Output is valid JSON array | Client receives valid response |
| Key order independence | Works with any field order | Handles all providers |

### 13.3 EnvelopeParser Test Coverage (IMPLEMENTED)

**Location**: `test/lasso/rpc/envelope_parser_test.exs`

**Test count**: 67 tests (all passing)

| Category | Tests | Coverage |
|----------|-------|----------|
| Key ordering | 4 | Standard, result-first, id-first, error ordering |
| ID types | 5 | Integer, string, null, missing, negative |
| Whitespace handling | 2 | Pretty-printed, extra whitespace |
| Error responses | 3 | Full error object, nested, braces in strings |
| Large results | 2 | Not parsed, raw_bytes preserved |
| Edge cases | 7 | Escapes, long IDs, deep nesting, missing keys |
| passthrough_eligible?/2 | 4 | ID match, mismatch, error response, nil expected |
| Real-world responses | 4 | eth_blockNumber, eth_getLogs, rate limit, block range |
| Bug fixes | 13 | Binary injection, integer parsing, unicode, dual-field |
| **Batch parsing** | 23 | Empty, single, multi, whitespace, escapes, errors |

**Batch-specific tests:**
- Empty batch `[]`
- Single-item batch
- Multi-item batches (2-3 items)
- Mixed success/error items
- Structural characters in strings (`[`, `]`, `,`)
- Escaped quotes in batch items
- Large ID values in batch
- Nested arrays/objects in results
- Whitespace variations
- Trailing comma handling
- Error cases (not array, unterminated, invalid items)
- Real-world batch scenarios

### 13.4 Integration Tests

TBD - Focus on touchpoints from Section 11.

---

## 14. Risk Analysis

### 14.1 Technical Risks

| Risk | Probability | Impact | Mitigation | Status |
|------|-------------|--------|------------|--------|
| EnvelopeParser misses edge case | Low | Medium | 67 tests, property tests | ✅ Mitigated |
| Batch reconstruction invalid JSON | Low | High | Property tests, JSON validation | ✅ Mitigated |
| Stack overflow on large batches | Low | High | `@max_batch_items 10_000` guard | ✅ Mitigated |
| Binary injection via string values | Low | Medium | String-aware key scanning | ✅ Fixed |
| Escape sequence bounds overflow | Low | High | Bounds check before `pos + 2` | ✅ Fixed |

### 14.2 Security Considerations

1. **No Code Execution**: Raw bytes are only passed through, never evaluated
2. **Provider Trust**: We trust upstream providers (same as current architecture)
3. **Resource Limits**: Max batch items (10,000), max object depth (100), scan limit (2,000 bytes)
4. **Bounds Checking**: All binary access via safe helpers with bounds verification

---
