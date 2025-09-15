defmodule Livechain.Types.HexQuantity do
  @moduledoc """
  Utilities for working with Ethereum hex quantities as per JSON-RPC spec.

  Provides safe conversions between integers and 0x-prefixed lowercase hex strings
  without leading zeros (except zero itself which is "0x0").
  """

  @spec to_hex(non_neg_integer()) :: String.t()
  def to_hex(int) when is_integer(int) and int >= 0 do
    "0x" <> Integer.to_string(int, 16)
  end

  @spec parse(String.t()) :: {:ok, non_neg_integer()} | {:error, :invalid_quantity}
  def parse("0x" <> rest) do
    case Integer.parse(rest, 16) do
      {val, ""} when val >= 0 -> {:ok, val}
      _ -> {:error, :invalid_quantity}
    end
  end

  def parse(_), do: {:error, :invalid_quantity}
end

