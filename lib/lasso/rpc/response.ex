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

  @type id :: integer() | String.t() | nil

  @type t :: %__MODULE__{
          id: id(),
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
  The hot path should NEVER call this - send raw_bytes directly.

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

defmodule Lasso.RPC.Response.Error do
  @moduledoc """
  Represents a JSON-RPC error response.

  Error responses are always fully parsed because:
  1. They're small (typically < 1KB)
  2. We need the error code and message for routing/retry decisions
  3. Circuit breakers need error details

  The `raw_bytes` field is optional - present if we have the original bytes
  and want to pass them through instead of re-encoding.
  """

  alias Lasso.JSONRPC.Error, as: JError

  @enforce_keys [:id, :jsonrpc, :error]
  defstruct [:id, :jsonrpc, :error, :raw_bytes]

  @type id :: integer() | String.t() | nil

  @type t :: %__MODULE__{
          id: id(),
          jsonrpc: String.t(),
          error: JError.t(),
          raw_bytes: binary() | nil
        }

  @doc """
  Create an Error response from a parsed envelope.

  The envelope's `error` field contains the fully parsed error object
  from the EnvelopeParser.
  """
  @spec from_envelope(map()) :: t()
  def from_envelope(%{id: id, jsonrpc: jsonrpc, error: error_map, raw_bytes: raw_bytes}) do
    jerror = build_jerror(error_map)

    %__MODULE__{
      id: id,
      jsonrpc: jsonrpc,
      error: jerror,
      raw_bytes: raw_bytes
    }
  end

  defp build_jerror(%{"code" => code, "message" => message} = error_map) do
    JError.new(code, message, data: Map.get(error_map, "data"))
  end

  defp build_jerror(%{"code" => code}) do
    JError.new(code, "Unknown error")
  end

  defp build_jerror(_) do
    JError.new(-32_700, "Malformed error response")
  end

  @doc """
  Serialize error response to JSON bytes.

  If raw_bytes is available, returns them directly.
  Otherwise, encodes the error structure.
  """
  @spec to_bytes(t()) :: {:ok, binary()} | {:error, term()}
  def to_bytes(%__MODULE__{raw_bytes: raw_bytes}) when is_binary(raw_bytes) do
    {:ok, raw_bytes}
  end

  def to_bytes(%__MODULE__{id: id, error: error}) do
    response = JError.to_response(error, id)

    case Jason.encode(response) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, {:encode_failed, reason}}
    end
  end
end

defmodule Lasso.RPC.Response.Notification do
  @moduledoc """
  Represents a JSON-RPC notification (server-initiated message without request ID).

  Used for subscription events like `eth_subscription`. Notifications are
  server-push messages that don't correspond to a client request.

  ## Example

      %Notification{
        method: "eth_subscription",
        params: %{
          "subscription" => "0x1234...",
          "result" => %{"blockNumber" => "0x1b4", ...}
        }
      }
  """

  @enforce_keys [:method, :params]
  defstruct [:method, :params, :raw_bytes]

  @type t :: %__MODULE__{
          method: String.t(),
          params: map(),
          raw_bytes: binary() | nil
        }

  @doc """
  Create a Notification from a parsed envelope.
  """
  @spec from_envelope(map()) :: t()
  def from_envelope(%{method: method, params: params, raw_bytes: raw_bytes}) do
    %__MODULE__{
      method: method,
      params: params,
      raw_bytes: raw_bytes
    }
  end

  @doc """
  Extract the subscription ID from an eth_subscription notification.

  Returns `nil` if not an eth_subscription or params structure is unexpected.
  """
  @spec subscription_id(t()) :: String.t() | nil
  def subscription_id(%__MODULE__{method: "eth_subscription", params: %{"subscription" => id}}) do
    id
  end

  def subscription_id(_), do: nil

  @doc """
  Extract the result payload from an eth_subscription notification.

  Returns `nil` if not an eth_subscription or params structure is unexpected.
  """
  @spec result(t()) :: term() | nil
  def result(%__MODULE__{method: "eth_subscription", params: %{"result" => result}}) do
    result
  end

  def result(_), do: nil
end

defmodule Lasso.RPC.Response.Batch do
  @moduledoc """
  Represents a batch JSON-RPC response containing multiple items.

  Batch responses maintain the original request order and support
  mixed success/error items.
  """

  alias Lasso.RPC.Response.{Error, Success}

  @enforce_keys [:items, :request_ids]
  defstruct [:items, :request_ids, :total_byte_size]

  @type id :: integer() | String.t() | nil
  @type item :: Success.t() | Error.t()
  @type t :: %__MODULE__{
          items: [item()],
          request_ids: [id()],
          total_byte_size: non_neg_integer() | nil
        }

  @doc """
  Build a Batch response from individual response items.

  Items are reordered to match the original request_ids order.

  ## Validations

  - Rejects duplicate response IDs (would cause silent data loss)
  - Rejects if any request_id is missing from responses
  """
  @spec build([item()], [id()]) :: {:ok, t()} | {:error, term()}
  def build(items, request_ids) when is_list(items) and is_list(request_ids) do
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
        {:ok,
         %__MODULE__{
           items: ordered_items,
           request_ids: request_ids,
           total_byte_size: calculate_total_size(ordered_items)
         }}

      {:error, _} = error ->
        error
    end
  end

  defp order_items(_items_by_id, [], acc), do: {:ok, Enum.reverse(acc)}

  defp order_items(items_by_id, [id | rest], acc) do
    case Map.fetch(items_by_id, id) do
      {:ok, item} ->
        order_items(items_by_id, rest, [item | acc])

      :error ->
        {:error, {:missing_response_id, id}}
    end
  end

  defp item_id(%Success{id: id}), do: id
  defp item_id(%Error{id: id}), do: id

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

  @doc """
  Count how many items are eligible for passthrough (Success responses).
  """
  @spec passthrough_count(t()) :: non_neg_integer()
  def passthrough_count(%__MODULE__{items: items}) do
    Enum.count(items, &match?(%Success{}, &1))
  end
end

defmodule Lasso.RPC.Response do
  @moduledoc """
  Unified response types for JSON-RPC responses with passthrough support.

  This module defines the canonical representation of responses flowing through
  the Lasso pipeline. All response variants are represented as structs with
  explicit types, enabling pattern matching and compile-time guarantees.

  ## Response Variants

  - `Success` - Successful response with raw bytes for passthrough
  - `Error` - Error response (fully parsed)
  - `Notification` - Server-initiated notification (e.g., eth_subscription events)
  - `Batch` - Batch response containing multiple Success/Error items

  ## Usage

      case Response.from_bytes(raw_bytes) do
        {:ok, %Response.Success{} = resp} ->
          # Send raw bytes directly
          send_resp(conn, 200, resp.raw_bytes)

        {:ok, %Response.Error{} = resp} ->
          # Handle error normally
          handle_error(conn, resp)

        {:ok, %Response.Notification{} = notif} ->
          # Handle subscription event
          handle_subscription(notif.method, notif.params)
      end
  """

  alias Lasso.RPC.EnvelopeParser

  # Re-export submodule structs for convenience
  alias __MODULE__.{Success, Error, Notification, Batch}

  @type t :: Success.t() | Error.t() | Notification.t() | Batch.t()
  @type id :: integer() | String.t() | nil
  @type parse_result :: {:ok, t()} | {:error, term()}

  @doc """
  Parse raw response bytes into a structured Response type.

  Uses envelope-only parsing to extract metadata without parsing the result.
  Notifications (messages with "method" key) are fully decoded.

  ## Examples

      iex> from_bytes(~s({"jsonrpc":"2.0","id":1,"result":"0x123"}))
      {:ok, %Response.Success{id: 1, raw_bytes: ...}}

      iex> from_bytes(~s({"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"Invalid"}}))
      {:ok, %Response.Error{id: 1, error: %JError{code: -32600, ...}}}

      iex> from_bytes(~s({"jsonrpc":"2.0","method":"eth_subscription","params":{...}}))
      {:ok, %Response.Notification{method: "eth_subscription", params: %{...}}}
  """
  @spec from_bytes(binary()) :: parse_result()
  def from_bytes(raw_bytes) when is_binary(raw_bytes) do
    case EnvelopeParser.parse(raw_bytes) do
      {:ok, %{type: :result} = envelope} ->
        {:ok, Success.from_envelope(envelope)}

      {:ok, %{type: :error} = envelope} ->
        {:ok, Error.from_envelope(envelope)}

      {:ok, %{type: :notification} = envelope} ->
        {:ok, Notification.from_envelope(envelope)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def from_bytes(_), do: {:error, :invalid_input}

  @doc """
  Parse a batch response into a Batch struct.

  Uses zero-copy batch splitting to extract individual items.

  ## Examples

      iex> from_batch_bytes(~s([{"jsonrpc":"2.0","id":1,"result":"ok"},{"jsonrpc":"2.0","id":2,"result":"ok"}]))
      {:ok, %Response.Batch{items: [%Success{}, %Success{}], request_ids: [1, 2]}}
  """
  @spec from_batch_bytes(binary()) :: {:ok, Batch.t()} | {:error, term()}
  def from_batch_bytes(raw_bytes) when is_binary(raw_bytes) do
    case EnvelopeParser.parse_batch(raw_bytes) do
      {:ok, envelopes} ->
        items =
          Enum.map(envelopes, fn
            %{type: :result} = env -> Success.from_envelope(env)
            %{type: :error} = env -> Error.from_envelope(env)
          end)

        request_ids = Enum.map(items, &id/1)

        {:ok,
         %Batch{
           items: items,
           request_ids: request_ids,
           total_byte_size: byte_size(raw_bytes)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def from_batch_bytes(_), do: {:error, :invalid_input}

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
  # Batch has no single ID
  def id(%Batch{}), do: nil
end
