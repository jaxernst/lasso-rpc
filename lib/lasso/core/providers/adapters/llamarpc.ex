defmodule Lasso.RPC.Providers.Adapters.LlamaRPC do
  @moduledoc """
  LlamaRPC Ethereum adapter.

  ## Error Messages Observed

  - "eth_getLogs range is too large, max is 1k blocks" (Production logs 2025-01-05)

  ## Implementation Strategy

  - Phase 1: Only `eth_getLogs` needs validation, all others skip params
  - Phase 2: Efficient early-exit counting to avoid full list traversal
  - Fail open: If we can't parse block numbers, allow the request

  Delegates normalization to Generic adapter using `defdelegate` for clarity and simplicity.
  """

  @behaviour Lasso.RPC.ProviderAdapter

  alias Lasso.RPC.{MethodRegistry, Providers.Generic, ChainState}

  import Lasso.RPC.Providers.AdapterHelpers

  @doc """
  Default block range limit for eth_getLogs based on production error logs.
  Can be overridden per-provider via adapter_config.
  """
  @default_max_block_range 1_000

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
    block_range_limit = get_adapter_config(ctx, :max_block_range, @default_max_block_range)

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

  # Private validation helpers

  defp validate_block_range([%{"fromBlock" => from, "toBlock" => to}], ctx, limit) do
    with {:ok, range} <- compute_block_range(from, to, ctx),
         true <- range > limit do
      {:error, {:param_limit, "max #{limit} block range (got #{range})"}}
    else
      _ -> :ok
    end
  end

  defp validate_block_range(_params, _ctx, _limit), do: :ok

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

    case ChainState.consensus_height(chain) do
      {:ok, height} -> height
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

  # ============================================
  # Error Classification
  # ============================================

  @impl true
  def classify_error(_code, message) when is_binary(message) do
    if String.contains?(message, "range is too large") do
      {:ok, :capability_violation}
    else
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
      type: :public,
      tier: :free,
      known_limitations: [
        "eth_getLogs: max #{@default_max_block_range} block range (configurable)"
      ],
      unsupported_categories: [:local_only],
      unsupported_methods: [],
      conditional_support: %{
        "eth_getLogs" => "Max #{@default_max_block_range} block range"
      },
      last_verified: ~D[2025-01-17]
    }
  end
end
