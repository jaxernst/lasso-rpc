defmodule Lasso.BlockPublication.Block do
  @moduledoc "Validated provider block evidence retained for local block choices."

  alias Lasso.JSONRPC.Quantity

  @max_header_bytes 1_048_576

  @type t :: %{required(String.t()) => term()}

  @spec decode(term(), integer(), pos_integer()) :: {:ok, t()} | {:error, term()}
  def decode(header, now_ms, max_age_ms) when is_map(header) do
    with {:ok, height} <- Quantity.decode(header["number"]),
         {:ok, timestamp} <- Quantity.decode(header["timestamp"]),
         true <- valid_hash?(header["hash"]),
         true <- valid_hash?(header["parentHash"]),
         true <- is_list(header["transactions"]),
         true <- Enum.all?(header["transactions"], &valid_hash?/1),
         true <- byte_size(Jason.encode!(header)) <= @max_header_bytes,
         :ok <- fresh?(timestamp * 1_000, now_ms, max_age_ms) do
      {:ok,
       %{
         "height" => height,
         "timestamp_ms" => timestamp * 1_000,
         "hash" => String.downcase(header["hash"]),
         "header" => header
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_block}
    end
  end

  def decode(_, _, _), do: {:error, :invalid_block}

  @spec fresh?(integer(), integer(), pos_integer()) :: :ok | {:error, atom()}
  def fresh?(timestamp_ms, now_ms, max_age_ms) do
    cond do
      timestamp_ms > now_ms + 15_000 -> {:error, :block_in_future}
      now_ms - timestamp_ms > max_age_ms -> {:error, :block_stale}
      true -> :ok
    end
  end

  @spec valid_hash?(term()) :: boolean()
  def valid_hash?(hash) when is_binary(hash), do: Regex.match?(~r/\A0x[0-9a-fA-F]{64}\z/, hash)
  def valid_hash?(_), do: false

  @spec same?(t(), t()) :: boolean()
  def same?(a, b), do: a["height"] == b["height"] and a["hash"] == b["hash"]
end
