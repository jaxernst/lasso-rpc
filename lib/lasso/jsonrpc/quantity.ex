defmodule Lasso.JSONRPC.Quantity do
  @moduledoc """
  Encodes non-negative integers as canonical Ethereum JSON-RPC quantities.

  Quantities use the shortest lowercase hexadecimal representation with a
  `0x` prefix. Zero is encoded as `0x0`.
  """

  @spec encode(non_neg_integer()) :: String.t()
  def encode(value) when is_integer(value) and value >= 0 do
    "0x" <> (value |> Integer.to_string(16) |> String.downcase())
  end

  @doc """
  Decodes a prefixed hexadecimal quantity without raising.

  Decoding is deliberately tolerant of uppercase digits and leading zeroes in
  upstream responses. `encode/1` produces the canonical EIP-1474 form when
  Lasso emits the value again.
  """
  @spec decode(term()) :: {:ok, non_neg_integer()} | {:error, :invalid_quantity}
  def decode("0x" <> hex) when hex != "" do
    if hex_digits?(hex) do
      case Integer.parse(hex, 16) do
        {value, ""} when value >= 0 -> {:ok, value}
        _invalid -> {:error, :invalid_quantity}
      end
    else
      {:error, :invalid_quantity}
    end
  end

  def decode(_value), do: {:error, :invalid_quantity}

  @doc "Returns whether a value is already in canonical EIP-1474 quantity form."
  @spec canonical?(term()) :: boolean()
  def canonical?(value) when is_binary(value) do
    case decode(value) do
      {:ok, decoded} -> value == encode(decoded)
      {:error, :invalid_quantity} -> false
    end
  end

  def canonical?(_value), do: false

  defp hex_digits?(<<>>), do: true

  defp hex_digits?(<<digit, rest::binary>>)
       when digit in ?0..?9 or digit in ?a..?f or digit in ?A..?F,
       do: hex_digits?(rest)

  defp hex_digits?(_invalid), do: false
end
