defmodule Lasso.RPC.Providers.Adapters.PublicNode do
  @moduledoc """
  PublicNode Ethereum adapter.



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

  import Lasso.RPC.Providers.AdapterHelpers

  @doc """
  Default request params limits validated with an empircal test on 10/07/2025:
  http limit is 50, ws limit is 30

  Update 10/08/2025:
  This seems to be a dynamic limit that changes, so default to more conservative values.

  Can be overridden per-provider via adapter_config.
  """
  @default_max_addresses_http 25
  @default_max_addresses_ws 20

  # Capability Validation

  @impl true
  def supports_method?(_method, _t, _c), do: :ok

  @impl true
  def validate_params("eth_getLogs", params, transport, ctx) do
    with :ok <- validate_address_inclusion(params),
         :ok <- validate_address_count(params, transport, ctx) do
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

  # Requires address param to be included in requests
  defp validate_address_inclusion([%{"address" => _}]), do: :ok

  defp validate_address_inclusion(_),
    do: {:error, {:param_limit, "address or addresses not found"}}

  defp validate_address_count([%{"address" => addrs}], transport, ctx) when is_list(addrs) do
    max_addresses = get_max_addresses(transport, ctx)

    # Early-exit counting for performance
    count =
      Enum.reduce_while(addrs, 0, fn _, acc ->
        if acc + 1 > max_addresses, do: {:halt, acc + 1}, else: {:cont, acc + 1}
      end)

    if count <= max_addresses,
      do: :ok,
      else: {:error, {:param_limit, "max #{max_addresses} addresses (got #{count})"}}
  end

  defp validate_address_count(_, _, _), do: :ok

  defp get_max_addresses(:ws, ctx), do: get_adapter_config(ctx, :max_addresses_ws, @default_max_addresses_ws)
  defp get_max_addresses(:http, ctx), do: get_adapter_config(ctx, :max_addresses_http, @default_max_addresses_http)
  defp get_max_addresses(_, ctx), do: get_adapter_config(ctx, :max_addresses_http, @default_max_addresses_http)

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
        "eth_getLogs: max #{@default_max_addresses_http} addresses (HTTP), #{@default_max_addresses_ws} addresses (WS) - default, configurable per-chain"
      ],
      sources: ["Production error logs", "Community documentation"],
      last_verified: ~D[2025-01-05],
      configurable_limits: [
        max_addresses_http: "Maximum addresses for eth_getLogs HTTP requests (default: #{@default_max_addresses_http})",
        max_addresses_ws: "Maximum addresses for eth_getLogs WebSocket requests (default: #{@default_max_addresses_ws})"
      ]
    }
  end
end
