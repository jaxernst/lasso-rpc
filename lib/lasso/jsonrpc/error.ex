defmodule Lasso.JSONRPC.Error do
  @moduledoc """
  Pure data structure for JSON-RPC 2.0 errors with Lasso-specific metadata.

  This module defines the error struct and provides serialization functions.
  All categorization and business logic lives in ErrorNormalizer and ErrorClassification.

  ## Fields

  - `code` - JSON-RPC error code (integer)
  - `message` - Human-readable error message
  - `data` - Optional additional error data
  - `category` - Semantic error category (atom)
  - `provider_id` - Which provider generated this error
  - `http_status` - HTTP status code if applicable
  - `retriable?` - Should we retry with another provider?
  - `breaker_penalty?` - Should this count against circuit breaker?
  - `original_code` - Preserve original code before normalization
  - `source` - Where the error originated (:jsonrpc, :transport, etc.)
  - `transport` - Which transport generated this error (:http, :ws)
  """

  @derive {Jason.Encoder,
           only: [
             :code,
             :message,
             :data,
             :category,
             :provider_id,
             :http_status,
             :retriable?,
             :breaker_penalty?,
             :original_code,
             :source,
             :transport
           ]}

  @enforce_keys [:code, :message]
  defstruct [
    :code,
    :message,
    :data,
    :category,
    :provider_id,
    :http_status,
    :retriable?,
    :breaker_penalty?,
    :original_code,
    :source,
    :transport
  ]

  alias Lasso.Core.Support.{ErrorClassification, ErrorNormalizer}

  @type t :: %__MODULE__{
          code: integer(),
          message: String.t(),
          data: any() | nil,
          category: atom() | nil,
          provider_id: String.t() | nil,
          http_status: integer() | nil,
          retriable?: boolean() | nil,
          breaker_penalty?: boolean() | nil,
          original_code: integer() | nil,
          source: :jsonrpc | :transport | :infrastructure | :health_check | nil,
          transport: :http | :ws | nil
        }

  @doc """
  Creates a new JSON-RPC error with automatic classification.

  Automatically classifies errors using ErrorClassification unless explicit
  category and retriable? values are provided.

  ## Examples

      iex> new(-32_602, "Invalid params")
      %Lasso.JSONRPC.Error{code: -32_602, message: "Invalid params", category: :invalid_params, retriable?: false}

      iex> new(-32_005, "Rate limit exceeded")
      %Lasso.JSONRPC.Error{code: -32_005, message: "Rate limit exceeded", category: :rate_limit, retriable?: true}

      iex> new(-32_000, "Server error", category: :server_error, retriable?: true)
      %Lasso.JSONRPC.Error{code: -32_000, message: "Server error", category: :server_error, retriable?: true}
  """
  @spec new(integer(), String.t(), keyword()) :: t()
  def new(code, message, opts \\ []) do
    # Normalize HTTP 429 to JSON-RPC -32_005 (rate limit code)
    {normalized_code, original_code} =
      if code == 429 do
        {-32_005, code}
      else
        {code, Keyword.get(opts, :original_code, code)}
      end

    # Auto-classify if not explicitly provided
    category = Keyword.get(opts, :category) || ErrorClassification.categorize(normalized_code, message)
    retriable? = Keyword.get(opts, :retriable?) || ErrorClassification.retriable?(normalized_code, message)
    breaker_penalty? = Keyword.get(opts, :breaker_penalty?) || ErrorClassification.breaker_penalty?(category)

    %__MODULE__{
      code: normalized_code,
      message: message,
      data: Keyword.get(opts, :data),
      category: category,
      provider_id: Keyword.get(opts, :provider_id),
      http_status: Keyword.get(opts, :http_status),
      retriable?: retriable?,
      breaker_penalty?: breaker_penalty?,
      original_code: original_code,
      source: Keyword.get(opts, :source),
      transport: Keyword.get(opts, :transport)
    }
  end

  @doc """
  Converts error to standard JSON-RPC error object for wire format.

  ## Examples

      iex> error = new(-32_602, "Invalid params", data: %{"details" => "missing field"})
      iex> to_map(error)
      %{"code" => -32_602, "message" => "Invalid params", "data" => %{"details" => "missing field"}}
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = error) do
    base = %{"code" => error.code, "message" => error.message}
    if error.data, do: Map.put(base, "data", error.data), else: base
  end

  @doc """
  Converts error to full JSON-RPC response format with request ID.

  ## Examples

      iex> error = new(-32_602, "Invalid params")
      iex> to_response(error, 1)
      %{"jsonrpc" => "2.0", "error" => %{"code" => -32_602, "message" => "Invalid params"}, "id" => 1}
  """
  @spec to_response(t(), any()) :: map()
  def to_response(%__MODULE__{} = error, id) do
    %{"jsonrpc" => "2.0", "error" => to_map(error), "id" => id}
  end

  @doc """
  Coerces any error shape into a properly categorized JError.

  This is a convenience function that delegates to `ErrorNormalizer.normalize/2`.
  Provided for backward compatibility and ergonomics at call sites.

  ## Examples

      iex> from({:rate_limit, %{}}, provider_id: "test")
      %Lasso.JSONRPC.Error{category: :rate_limit, retriable?: true}

      iex> from(%{"error" => %{"code" => -32_602}}, provider_id: "test")
      %Lasso.JSONRPC.Error{code: -32_602, category: :invalid_params}
  """
  @spec from(any(), keyword()) :: t()
  def from(error, opts \\ [])
  def from(%__MODULE__{} = error, _opts), do: error
  def from(error, opts), do: ErrorNormalizer.normalize(error, opts)
end
