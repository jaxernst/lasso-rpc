defmodule Lasso.RPC.Providers.Adapters.Alchemy do
  @moduledoc """
  Alchemy Ethereum adapter.

  ## Error Messages Observed

  - {"jsonrpc":"2.0","id":"ce9218c78f27f4c3b9b4b72bfbcd9f3e","error":{"code":-32600,"message":"Under the Free tier plan, you can make eth_getLogs requests with up to a 10 block range. Based on your parameters, this block range should work: [0x1180fca, 0x1180fd3]. Upgrade to PAYG for expanded block range."}}
  """

  @behaviour Lasso.RPC.ProviderAdapter

  alias Lasso.RPC.Providers.Generic
  alias Lasso.RPC.ChainState

  import Lasso.RPC.Providers.AdapterHelpers

  @doc """
  Default block range limit for eth_getLogs based on production error logs.
  Can be overridden per-provider via adapter_config.
  """
  @default_eth_get_logs_block_range 10

  # Capability Validation

  @impl true
  def supports_method?(_method, _t, _c), do: :ok

  @impl true
  def validate_params("eth_getLogs", params, _transport, ctx) do
    # Get block range limit from provider config or use default
    block_range_limit =
      get_adapter_config(ctx, :eth_get_logs_block_range, @default_eth_get_logs_block_range)

    case validate_logs_block_range(params, ctx, block_range_limit) do
      :ok ->
        :ok

      {:error, reason} = err ->
        :telemetry.execute([:lasso, :capabilities, :param_reject], %{count: 1}, %{
          adapter: __MODULE__,
          method: "eth_getLogs",
          reason: reason
        })

        err
    end
  end

  def validate_params(_method, _params, _t, _ctx), do: :ok

  # Private validation helpers

  defp validate_logs_block_range([%{"fromBlock" => from, "toBlock" => to}], ctx, limit) do
    with {:ok, range} <- compute_block_range(from, to, ctx),
         true <- range > limit do
      {:error, {:param_limit, "max #{limit} block range (got #{range})"}}
    else
      _ -> :ok
    end
  end

  defp validate_logs_block_range(_params, _ctx, _limit), do: :ok

  defp compute_block_range(from_block, to_block, ctx) do
    with {:ok, from_num} <- parse_block_number(from_block, ctx),
         {:ok, to_num} <- parse_block_number(to_block, ctx) do
      {:ok, abs(to_num - from_num)}
    else
      _ -> :error
    end
  end

  defp parse_block_number("latest", ctx), do: {:ok, estimate_current_block(ctx)}
  defp parse_block_number("earliest", _ctx), do: {:ok, 0}
  defp parse_block_number("pending", ctx), do: {:ok, estimate_current_block(ctx)}

  defp parse_block_number("0x" <> hex, _ctx) do
    case Integer.parse(hex, 16) do
      {num, ""} -> {:ok, num}
      _ -> :error
    end
  end

  defp parse_block_number(num, _ctx) when is_integer(num), do: {:ok, num}
  defp parse_block_number(_value, _ctx), do: :error

  # Estimates current block from cache, skipping validation if unavailable
  # This allows requests to proceed when consensus is unavailable (fail-open)
  defp estimate_current_block(ctx) do
    chain = Map.get(ctx, :chain, "ethereum")

    case ChainState.consensus_height(chain, allow_stale: true) do
      {:ok, height} -> height
      {:ok, height, :stale} -> height
      {:error, _} -> 0
    end
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
        "eth_getLogs: max #{@default_eth_get_logs_block_range} block range (default, configurable per-chain)"
      ],
      sources: ["Production error logs"],
      last_verified: ~D[2025-01-05],
      configurable_limits: [
        eth_get_logs_block_range:
          "Maximum block range for eth_getLogs queries (default: #{@default_eth_get_logs_block_range})"
      ]
    }
  end
end
