defmodule Lasso.RPC.TransactionHash do
  @moduledoc false
  @spec error_data(term()) :: map()
  def error_data(nil), do: %{}
  def error_data(data) when is_map(data), do: data
  def error_data(data), do: %{upstream_data: data}

  @doc "Hash for evidence lookup only; opaque chain-specific types pass through."
  @spec from_params(term()) :: binary() | nil
  def from_params(["0x" <> raw]) do
    case Base.decode16(raw, case: :mixed) do
      {:ok, bytes} -> "0x" <> Base.encode16(ExKeccak.hash_256(hash_payload(bytes)), case: :lower)
      :error -> nil
    end
  end

  def from_params(_), do: nil

  # Decode only enough RLP to find the first item of an EIP-4844 network
  # wrapper. The signed payload's original bytes are hashed, never reencoded.
  defp hash_payload(<<3, outer::binary>> = bytes) do
    with {:ok, :list, body, <<>>} <- rlp_item(outer),
         {:ok, :list, _payload, rest} <- rlp_item(body) do
      <<3>> <> binary_part(body, 0, byte_size(body) - byte_size(rest))
    else
      _ -> bytes
    end
  end

  defp hash_payload(bytes), do: bytes

  defp rlp_item(<<tag, rest::binary>>) when tag in 0xC0..0xF7,
    do: take_item(:list, rest, tag - 0xC0)

  defp rlp_item(<<tag, rest::binary>>) when tag in 0xF8..0xFF do
    length_size = tag - 0xF7

    with <<length::binary-size(length_size), body::binary>> <- rest,
         do: take_item(:list, body, :binary.decode_unsigned(length))
  end

  defp rlp_item(_), do: :error

  defp take_item(kind, bytes, size) when size <= byte_size(bytes) do
    <<body::binary-size(size), rest::binary>> = bytes
    {:ok, kind, body, rest}
  end

  defp take_item(_, _, _), do: :error
end
