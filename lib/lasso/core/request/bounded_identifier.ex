defmodule Lasso.RPC.BoundedIdentifier do
  @moduledoc """
  Normalizes externally supplied scalar identifiers to a fixed byte bound.
  """

  @max_bytes 128

  @spec encode(binary()) :: binary()
  def encode(value) when is_binary(value) do
    if byte_size(value) <= @max_bytes and valid_utf8?(value) do
      value
    else
      "sha256:" <> Base.url_encode64(:crypto.hash(:sha256, value), padding: false)
    end
  end

  @spec encode_optional(binary() | nil) :: binary() | nil
  def encode_optional(nil), do: nil
  def encode_optional(value), do: encode(value)

  @spec valid?(term()) :: boolean()
  def valid?(value),
    do: is_binary(value) and byte_size(value) <= @max_bytes and valid_utf8?(value)

  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  defp valid_utf8?(value) do
    is_binary(:unicode.characters_to_binary(value, :utf8, :utf8))
  end
end
