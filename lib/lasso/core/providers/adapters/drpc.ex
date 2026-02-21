defmodule Lasso.RPC.Providers.Adapters.DRPC do
  @moduledoc """
  DRPC adapter.

  ## Error Messages Observed

  - "Request timeout on the free tier, please upgrade your tier to the paid one" (code: 30)
    Status: 408, Category: rate_limit
    Note: This is a rate limit timeout, not a capability violation

  - "ranges over 10000 blocks are not supported on freetier" (code: 35)
    Status: 400, Category: capability_violation

  ## Implementation Strategy

  - Phase 1: Only `eth_getLogs` needs validation, all others skip params
  - Phase 2: Efficient early-exit counting to avoid full list traversal
  - Fail open: If we can't parse block numbers, allow the request

  Delegates normalization to Generic adapter using `defdelegate` for clarity and simplicity.
  """

  @behaviour Lasso.RPC.ProviderAdapter

  alias Lasso.RPC.MethodRegistry
  alias Lasso.RPC.Providers.Generic

  import Lasso.RPC.Providers.AdapterHelpers

  @doc """
  Default block range limit for eth_getLogs based on production error logs.
  Can be overridden per-provider via adapter_config.
  """
  @default_max_block_range 10_000

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

  # Normalization - delegate to Generic adapter

  @impl true
  defdelegate normalize_request(request, ctx), to: Generic

  @impl true
  defdelegate normalize_response(response, ctx), to: Generic

  @impl true
  defdelegate normalize_error(error, ctx), to: Generic

  @impl true
  defdelegate headers(ctx), to: Generic

  # Error Classification

  @impl true
  def classify_error(30, message) when is_binary(message) do
    # Code 30 with "free tier timeout" is rate limit (not capability violation)
    if String.contains?(String.downcase(message), "timeout on the free tier") do
      {:ok, :rate_limit}
    else
      :default
    end
  end

  # Code 30 without message defaults to rate limit based on observed behavior
  def classify_error(30, nil), do: {:ok, :rate_limit}

  # Code 35 is capability violation (block range limit)
  def classify_error(35, _message), do: {:ok, :capability_violation}

  # Message pattern: "ranges over X blocks" indicates block range limit
  def classify_error(_code, message) when is_binary(message) do
    if String.contains?(String.downcase(message), "ranges over") do
      {:ok, :capability_violation}
    else
      :default
    end
  end

  # All other errors: defer to centralized classification
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
        "eth_getLogs: max #{@default_max_block_range} block range on free tier (configurable)",
        "Free tier timeout errors (code 30)"
      ],
      unsupported_categories: [:local_only],
      unsupported_methods: [],
      conditional_support: %{
        "eth_getLogs" => "Max #{@default_max_block_range} block range on free tier"
      },
      last_verified: ~D[2025-01-17]
    }
  end
end
