defmodule Lasso.RPC.Providers.Adapters.Alchemy do
  @moduledoc """
  Alchemy Ethereum adapter.

  ## Error Messages Observed

  - {"jsonrpc":"2.0","id":"ce9218c78f27f4c3b9b4b72bfbcd9f3e","error":{"code":-32600,"message":"Under the Free tier plan, you can make eth_getLogs requests with up to a 10 block range. Based on your parameters, this block range should work: [0x1180fca, 0x1180fd3]. Upgrade to PAYG for expanded block range."}}
  """

  @behaviour Lasso.RPC.ProviderAdapter

  alias Lasso.RPC.Providers.Generic

  @doc """
  Block range limit for eth_getLogs based on production error logs.
  """
  @eth_get_logs_block_range 10

  # Capability Validation

  @impl true
  def supports_method?(_method, _t, _c), do: :ok

  @impl true
  def validate_params("eth_getLogs", params, _transport, _c) do
    with :ok <- validate_logs_block_range(params) do
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

  defp validate_logs_block_range([%{"fromBlock" => from, "toBlock" => to}]) do
    with {:ok, range} <- compute_block_range(from, to),
         true <- range > @eth_get_logs_block_range do
      {:error, {:param_limit, "max #{@eth_get_logs_block_range} block range (got #{range})"}}
    else
      _ -> :ok
    end
  end

  defp validate_logs_block_range(_), do: :ok

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
        "eth_getLogs: max #{@eth_get_logs_block_range} block range"
      ],
      sources: ["Production error logs"],
      last_verified: ~D[2025-01-05]
    }
  end
end
