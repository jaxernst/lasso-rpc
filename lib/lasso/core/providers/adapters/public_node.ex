defmodule Lasso.RPC.Providers.Adapters.PublicNode do
  @moduledoc """
  PublicNode Ethereum adapter.

  PublicNode is a free public RPC provider with significant limitations:
  - No eth_getLogs or filter methods
  - No debug/trace methods
  - Limited archive depth (~1000 blocks)
  - Aggressive rate limiting

  ## Error Messages Observed

  - "Please, specify less number of addresses" (Production logs 2025-01-05)
  - "This range of parameters is not supported"

  ## Implementation Strategy

  - Phase 1: Block entire unsupported categories and specific methods
  - Phase 2: Validate archive depth for state methods
  - Fail safe: Conservative limits to avoid rejection

  Delegates normalization to Generic adapter using `defdelegate` for clarity and simplicity.
  """

  @behaviour Lasso.RPC.ProviderAdapter

  alias Lasso.RPC.{MethodRegistry, Providers.Generic}

  @max_archive_depth 1000

  # ============================================
  # Phase 1: Method-Level Filtering (Fast)
  # ============================================

  @impl true
  def supports_method?(method, _transport, _context) do
    category = MethodRegistry.method_category(method)

    cond do
      # Unsupported categories
      category in [:debug, :trace, :txpool, :local_only, :eip4844] ->
        {:error, :method_unsupported}

      # Specific unsupported methods (filters)
      method in ["eth_getLogs", "eth_newFilter", "eth_getFilterChanges",
                 "eth_getFilterLogs", "eth_uninstallFilter"] ->
        {:error, :method_unsupported}

      # Subscriptions require WebSocket (handled by TransportPolicy)
      category == :subscriptions ->
        :ok

      # All other standard methods supported
      true ->
        :ok
    end
  end

  # ============================================
  # Phase 2: Parameter Validation (Slow)
  # ============================================

  @impl true
  def validate_params("eth_call", params, _transport, context) do
    # PublicNode has limited archive depth
    validate_archive_depth(params, context)
  end

  def validate_params("eth_getBalance", params, _transport, context) do
    validate_archive_depth(params, context)
  end

  def validate_params("eth_getCode", params, _transport, context) do
    validate_archive_depth(params, context)
  end

  def validate_params("eth_getStorageAt", params, _transport, context) do
    validate_archive_depth(params, context)
  end

  def validate_params("eth_getTransactionCount", params, _transport, context) do
    validate_archive_depth(params, context)
  end

  def validate_params(_method, _params, _transport, _context), do: :ok

  # ============================================
  # Private Helpers
  # ============================================

  defp validate_archive_depth(params, context) do
    block_param = List.last(params)

    case parse_block_param(block_param) do
      {:ok, :latest} ->
        :ok

      {:ok, block_num} when is_integer(block_num) ->
        current_block = Map.get(context, :current_block, :latest)

        if current_block == :latest do
          :ok  # Can't validate without current block
        else
          age = current_block - block_num

          if age <= @max_archive_depth do
            :ok
          else
            {:error, {:requires_archival,
              "Block is #{age} blocks old, PublicNode max: #{@max_archive_depth}"}}
          end
        end

      _ ->
        :ok  # Can't parse, let provider decide
    end
  end

  defp parse_block_param("latest"), do: {:ok, :latest}
  defp parse_block_param("earliest"), do: {:ok, 0}
  defp parse_block_param("pending"), do: {:ok, :latest}

  defp parse_block_param("0x" <> hex) do
    case Integer.parse(hex, 16) do
      {num, ""} -> {:ok, num}
      _ -> {:error, :invalid_hex}
    end
  end

  defp parse_block_param(_), do: {:error, :invalid_format}

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
  # PublicNode uses -32701 for capability violations (address requirements, parameter ranges)
  def classify_error(-32_701, _message), do: {:ok, :capability_violation}

  def classify_error(_code, message) when is_binary(message) do
    cond do
      String.contains?(message, "This range of parameters is not supported") ->
        {:ok, :capability_violation}

      String.contains?(message, "specify less number of addresses") ->
        {:ok, :capability_violation}

      String.contains?(message, "specify an address") ->
        {:ok, :capability_violation}

      String.contains?(message, "pruned") ->
        {:ok, :requires_archival}

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
      type: :public,
      tier: :free,
      known_limitations: [
        "No eth_getLogs support",
        "No filter methods (eth_newFilter, etc.)",
        "Limited archive depth (~#{@max_archive_depth} blocks)",
        "No debug/trace methods",
        "Aggressive rate limiting"
      ],
      unsupported_categories: [:debug, :trace, :filters, :txpool, :local_only, :eip4844],
      unsupported_methods: ["eth_getLogs", "eth_newFilter", "eth_getFilterChanges",
                            "eth_getFilterLogs", "eth_uninstallFilter"],
      conditional_support: %{
        "eth_call" => "Recent blocks only (~#{@max_archive_depth} block depth)",
        "eth_getBalance" => "Recent blocks only (~#{@max_archive_depth} block depth)",
        "eth_getCode" => "Recent blocks only (~#{@max_archive_depth} block depth)",
        "eth_getStorageAt" => "Recent blocks only (~#{@max_archive_depth} block depth)",
        "eth_getTransactionCount" => "Recent blocks only (~#{@max_archive_depth} block depth)"
      },
      last_verified: ~D[2025-01-17]
    }
  end
end
