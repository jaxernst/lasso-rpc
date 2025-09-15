defmodule Livechain.JSONRPC.Error do
  @moduledoc """
  Typed representation of a JSON-RPC 2.0 error with additional metadata
  useful for routing, retries, and analytics inside the aggregator.

  This struct is internal. At the boundary we still serialize to standard
  JSON-RPC error maps.
  """

  @enforce_keys [:code, :message]
  defstruct [
    :code,
    :message,
    :data,
    :category,
    :provider_id,
    :http_status,
    :retriable?
  ]

  @type t :: %__MODULE__{
          code: integer(),
          message: String.t(),
          data: map() | nil,
          category: atom() | nil,
          provider_id: String.t() | nil,
          http_status: integer() | nil,
          retriable?: boolean() | nil
        }
end

