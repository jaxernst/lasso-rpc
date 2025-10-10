defmodule Lasso.RPC.Providers.Adapters.Cloudflare do
  @moduledoc """
  Cloudflare Ethereum Gateway adapter.

  ## Known Limitations (as of 2025-01-06)

  - No `eth_getLogs` support
  - No `eth_getFilterLogs`, `eth_newFilter`, `eth_newBlockFilter`, `eth_getFilterChanges`, `eth_uninstallFilter`
  - No debug/trace methods
  - Read-only methods only

  ## Documentation

  https://developers.cloudflare.com/web3/ethereum-gateway/

  ## Implementation Strategy

  Uses compile-time function clause generation for O(1) pattern matching on unsupported methods.
  This is more efficient than runtime list membership checks.

  Delegates normalization to Generic adapter using `defdelegate` for clarity and simplicity.
  """

  @behaviour Lasso.RPC.ProviderAdapter

  alias Lasso.RPC.Providers.Generic

  # Methods explicitly unsupported by Cloudflare
  @unsupported_methods [
    "eth_getLogs",
    "eth_getFilterLogs",
    "eth_newFilter",
    "eth_newBlockFilter",
    "eth_getFilterChanges",
    "eth_uninstallFilter"
  ]

  # Capability Validation

  # Compile-time function clauses for unsupported methods (O(1) pattern matching)
  for method <- @unsupported_methods do
    @impl true
    def supports_method?(unquote(method), _t, _c), do: {:error, :method_unsupported}
  end

  @impl true
  def supports_method?("debug_" <> _, _t, _c), do: {:error, :method_unsupported}

  @impl true
  def supports_method?("trace_" <> _, _t, _c), do: {:error, :method_unsupported}

  @impl true
  def supports_method?(_method, _t, _c), do: :ok

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

  # Metadata

  @impl true
  def metadata do
    %{
      type: :public,
      tier: :free,
      documentation: "https://developers.cloudflare.com/web3/ethereum-gateway/",
      known_limitations: [
        "No eth_getLogs support",
        "No filter methods (eth_getFilterLogs, eth_newFilter, etc.)",
        "No debug/trace methods",
        "Rate limits apply"
      ],
      last_verified: ~D[2025-01-06]
    }
  end
end
