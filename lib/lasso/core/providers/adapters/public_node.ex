defmodule Lasso.RPC.Providers.Adapters.PublicNode do
  @moduledoc """
  PublicNode Ethereum adapter.

  ## Known Limitations (observed from production errors)

  - `eth_getLogs`: max 3 addresses
  - `eth_getLogs`: max 2000 block range
  - No archival data (>10k blocks old)

  ## Error Messages Observed

  - "Please, specify less number of addresses" (Production logs 2025-01-05)

  ## Implementation Strategy

  - Phase 1: Only `eth_getLogs` needs validation, all others skip params
  - Phase 2: Efficient early-exit counting to avoid full list traversal
  - Fail open: If we can't parse block numbers, allow the request

  Delegates normalization to Generic adapter using `defdelegate` for clarity and simplicity.
  """

  @behaviour Lasso.RPC.ProviderAdapter

  alias Lasso.RPC.Providers.Generic

  @max_addresses 3
  @max_block_range 2000
  @archival_threshold 10_000

  # Capability Validation

  @impl true
  def supports_method?(_method, _t, _c), do: :ok

  @impl true
  def validate_params("eth_getLogs", params, _t, _c) do
    with :ok <- validate_address_count(params),
         :ok <- validate_block_range(params),
         :ok <- validate_archival(params) do
      :ok
    else
      {:error, reason} = err ->
        :telemetry.execute([:lasso, :capabilities, :param_reject], %{count: 1}, %{
          adapter: __MODULE__,
          method: "eth_getLogs",
          reason: reason
        })

        err
    end
  end

  def validate_params(_method, _params, _t, _c), do: :ok

  # Private validation helpers

  defp validate_address_count([%{"address" => addrs}]) when is_list(addrs) do
    # Early-exit counting for performance
    count =
      Enum.reduce_while(addrs, 0, fn _, acc ->
        if acc + 1 > @max_addresses, do: {:halt, acc + 1}, else: {:cont, acc + 1}
      end)

    if count <= @max_addresses,
      do: :ok,
      else: {:error, {:param_limit, "max #{@max_addresses} addresses (got #{count})"}}
  end

  defp validate_address_count(_), do: :ok

  defp validate_block_range([%{"fromBlock" => from, "toBlock" => to}]) do
    with {:ok, range} <- compute_block_range(from, to),
         false <- range <= @max_block_range do
      {:error, {:param_limit, "max #{@max_block_range} block range (got #{range})"}}
    else
      _ -> :ok
    end
  end

  defp validate_block_range(_), do: :ok

  defp validate_archival([%{"fromBlock" => from}]) do
    with {:ok, block_num} <- parse_block_number(from),
         true <- estimate_current_block() - block_num > @archival_threshold do
      {:error, {:requires_archival, "blocks older than #{@archival_threshold} not supported"}}
    else
      _ -> :ok
    end
  end

  defp validate_archival(_), do: :ok

  defp compute_block_range(from_block, to_block) do
    with {:ok, from_num} <- parse_block_number(from_block),
         {:ok, to_num} <- parse_block_number(to_block) do
      {:ok, abs(to_num - from_num)}
    else
      _ -> :error
    end
  end

  defp parse_block_number("latest"), do: {:ok, estimate_current_block()}
  defp parse_block_number("earliest"), do: {:ok, 0}
  defp parse_block_number("pending"), do: {:ok, estimate_current_block()}

  defp parse_block_number("0x" <> hex) do
    case Integer.parse(hex, 16) do
      {num, ""} -> {:ok, num}
      _ -> :error
    end
  end

  defp parse_block_number(num) when is_integer(num), do: {:ok, num}
  defp parse_block_number(_), do: :error

  # Rough estimate, doesn't need to be exact (used for filtering decisions)
  # TODO: Pull from block height ets tables once implemented
  defp estimate_current_block do
    # Ethereum mainnet is ~21M blocks as of Jan 2025
    # This is just for validation, doesn't need to be precise
    21_000_000
  end

  # Normalization - delegate to Generic adapter

  @impl true
  defdelegate normalize_request(request, ctx), to: Generic

  @impl true
  defdelegate normalize_response(response, ctx), to: Generic

  @impl true
  defdelegate normalize_error(error, ctx), to: Generic

  @impl true
  defdelegate headers(ctx), to: Generic

  # Metadata

  @impl true
  def metadata do
    %{
      type: :public,
      tier: :free,
      known_limitations: [
        "eth_getLogs: max #{@max_addresses} addresses",
        "eth_getLogs: max #{@max_block_range} block range",
        "No archival data (>#{@archival_threshold} blocks old)"
      ],
      sources: ["Production error logs", "Community documentation"],
      last_verified: ~D[2025-01-05]
    }
  end
end
