defmodule Lasso.RPC.Providers.Adapters.Cloudflare do
  @moduledoc """
  Cloudflare Ethereum Gateway adapter.

  Cloudflare provides a free public RPC gateway with significant restrictions:
  - No eth_getLogs or filter methods
  - No debug/trace methods
  - No mempool methods (eth_sendRawTransaction)
  - Read-only methods only

  ## Known Limitations (as of 2025-01-06)

  - No `eth_getLogs` support
  - No `eth_getFilterLogs`, `eth_newFilter`, `eth_newBlockFilter`, `eth_getFilterChanges`, `eth_uninstallFilter`
  - No debug/trace methods
  - Read-only methods only

  ## Documentation

  https://developers.cloudflare.com/web3/ethereum-gateway/

  ## Implementation Strategy

  Uses MethodRegistry for category-based filtering with compile-time function clauses
  for O(1) pattern matching on unsupported methods.

  Delegates normalization to Generic adapter using `defdelegate` for clarity and simplicity.
  """

  @behaviour Lasso.RPC.ProviderAdapter

  alias Lasso.RPC.{MethodRegistry, Providers.Generic}

  # ============================================
  # Phase 1: Method-Level Filtering (Fast)
  # ============================================

  @impl true
  def supports_method?(method, _transport, _context) do
    category = MethodRegistry.method_category(method)

    cond do
      # Unsupported categories
      category in [:debug, :trace, :filters, :txpool, :local_only, :mempool] ->
        {:error, :method_unsupported}

      # All other standard methods supported
      true ->
        :ok
    end
  end

  @impl true
  def validate_params(_method, _params, _t, _c), do: :ok

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
  # Cloudflare capacity/rate limiting with code -32046
  def classify_error(-32_046, _message), do: {:ok, :rate_limit}

  # Message pattern: "cannot fulfill request" indicates capacity/rate limiting
  def classify_error(_code, message) when is_binary(message) do
    if String.contains?(String.downcase(message), "cannot fulfill request") do
      {:ok, :rate_limit}
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
        "No eth_getLogs support",
        "No filter methods (eth_getFilterLogs, eth_newFilter, etc.)",
        "No debug/trace methods",
        "No mempool methods (eth_sendRawTransaction)",
        "Read-only methods only"
      ],
      unsupported_categories: [:debug, :trace, :filters, :txpool, :local_only, :mempool],
      unsupported_methods: [],
      conditional_support: %{},
      last_verified: ~D[2025-01-17]
    }
  end
end
