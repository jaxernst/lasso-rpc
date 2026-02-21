defmodule Lasso.RPC.Providers.Adapters.Alchemy do
  @moduledoc """
  Alchemy Ethereum adapter.

  Alchemy is a commercial RPC provider with generous free tier:
  - Supports all standard methods except local_only
  - eth_getLogs limited to 10 block range on free tier, 2000 on paid
  - Supports eth_getBlockReceipts (Alchemy enhanced)

  ## Error Messages Observed

  - {"jsonrpc":"2.0","id":"ce9218c78f27f4c3b9b4b72bfbcd9f3e","error":{"code":-32600,"message":"Under the Free tier plan, you can make eth_getLogs requests with up to a 10 block range. Based on your parameters, this block range should work: [0x1180fca, 0x1180fd3]. Upgrade to PAYG for expanded block range."}}
  """

  @behaviour Lasso.RPC.ProviderAdapter

  alias Lasso.RPC.MethodRegistry
  alias Lasso.RPC.Providers.Generic

  import Lasso.RPC.Providers.AdapterHelpers

  @doc """
  Default block range limit for eth_getLogs based on production error logs.
  Free tier: 10 blocks, Paid tier: 2000 blocks
  Can be overridden per-provider via adapter_config.
  """
  @default_eth_get_logs_block_range 10

  # ============================================
  # Phase 1: Method-Level Filtering (Fast)
  # ============================================

  @impl true
  def supports_method?(method, _transport, _context) do
    category = MethodRegistry.method_category(method)

    case category do
      :local_only -> {:error, :method_unsupported}
      _ -> :ok
    end
  end

  @impl true
  def validate_params("eth_getLogs", params, _transport, ctx) do
    # Get block range limit from provider config or use default
    block_range_limit =
      get_adapter_config(ctx, :eth_get_logs_block_range, @default_eth_get_logs_block_range)

    case validate_block_range(params, ctx, block_range_limit) do
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

  # Normalization - delegate to Generic adapter

  @impl true
  defdelegate normalize_request(request, ctx), to: Generic

  @impl true
  defdelegate normalize_response(response, ctx), to: Generic

  @impl true
  defdelegate normalize_error(error, ctx), to: Generic

  @impl true
  defdelegate headers(ctx), to: Generic

  # ============================================
  # Error Classification
  # ============================================

  @impl true
  def classify_error(_code, message) when is_binary(message) do
    cond do
      String.contains?(message, "block range") and String.contains?(message, "Upgrade") ->
        {:ok, :capability_violation}

      String.contains?(message, "compute units") ->
        {:ok, :rate_limit}

      true ->
        :default
    end
  end

  def classify_error(_code, _message), do: :default

  # ============================================
  # Metadata
  # ============================================

  @impl true
  def metadata do
    %{
      type: :paid,
      tier: :free,
      known_limitations: [
        "eth_getLogs limited to #{@default_eth_get_logs_block_range} block range on free tier (configurable)",
        "Compute unit limits on free tier"
      ],
      unsupported_categories: [:local_only],
      unsupported_methods: [],
      conditional_support: %{
        "eth_getLogs" =>
          "Max #{@default_eth_get_logs_block_range} block range on free tier, 2000 on paid tier"
      },
      last_verified: ~D[2025-01-17]
    }
  end
end
