defmodule Lasso.BlockPublication.Probe do
  @moduledoc "Regional block evidence acquired through the bounded RPC execution path."
  alias Lasso.BlockPublication.Block
  alias Lasso.JSONRPC.Quantity
  alias Lasso.Providers.Catalog
  alias Lasso.RPC.{BoundedIdentifier, RequestOptions, RequestPipeline}
  alias Lasso.RPC.Response.Success

  @spec latest({String.t(), pos_integer()}, pos_integer()) ::
          {:ok, Block.t(), map()} | {:error, term()}
  def latest(key, max_age_ms), do: block(key, "latest", max_age_ms)

  @spec prepare({String.t(), pos_integer()}, Block.t(), Block.t() | nil, pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def prepare(key, candidate, published, max_age_ms) do
    with {:ok, observed, route} <- block(key, Quantity.encode(candidate["height"]), max_age_ms),
         true <- Block.same?(candidate, observed),
         {:ok, anchor_hash} <- anchor(key, published, route) do
      {:ok,
       %{
         "block_hash" => observed["hash"],
         "anchor_hash" => anchor_hash,
         "provider_id" => BoundedIdentifier.encode(route.provider_id),
         "instance_id" => route.instance_id,
         "observed_at_ms" => System.system_time(:millisecond)
       }}
    else
      false -> {:error, :candidate_hash_mismatch}
      error -> error
    end
  end

  defp block(key, selector, max_age_ms) do
    with {:ok, header, route} <- fetch(key, selector),
         {:ok, block} <- Block.decode(header, System.system_time(:millisecond), max_age_ms) do
      {:ok, block, route}
    end
  end

  defp anchor(_, nil, _), do: {:ok, nil}

  defp anchor(key, published, route) do
    with {:ok, header, observed_route} <- fetch(key, Quantity.encode(published["height"]), route),
         true <- observed_route.instance_id == route.instance_id,
         %{"number" => number, "hash" => hash} <- header,
         {:ok, height} <- Quantity.decode(number),
         true <- height == published["height"] and Block.valid_hash?(hash) do
      {:ok, String.downcase(hash)}
    else
      _ -> {:error, :anchor_unavailable}
    end
  end

  defp fetch({profile, chain_id}, selector, route \\ nil) do
    opts = %RequestOptions{
      profile: if(route, do: route.profile, else: profile),
      request_origin: :system,
      provider_override: route && route.provider_id,
      transport: route && route.transport,
      failover_on_override: false,
      strategy: :priority,
      timeout_ms: 3_000,
      jsonrpc_id: "block-publication"
    }

    case RequestPipeline.execute_via_channels(
           chain_id,
           "eth_getBlockByNumber",
           [selector, false],
           opts
         ) do
      {:ok, response, ctx} ->
        with {:ok, header} <- Success.decode_result(response),
             {:ok, locator} <- execution_locator(ctx) do
          {:ok, header, locator}
        end

      {:error, _, _} ->
        {:error, :provider_unavailable}
    end
  end

  defp execution_locator(ctx) do
    route = ctx.executed_channel
    profile = ctx.opts.profile

    # Observability identifiers may be hashed; execution needs the catalog's ID.
    with %{generation: generation} = snapshot <- Catalog.snapshot(),
         true <- generation == route.route_generation,
         {:ok, plan} <- Catalog.get_routing_plan(snapshot, profile, ctx.chain_id),
         provider when not is_nil(provider) <-
           Enum.find(plan.providers, fn provider ->
             BoundedIdentifier.encode(provider.id) == route.provider_id and
               BoundedIdentifier.encode(provider.instance_id) == route.instance_id
           end) do
      {:ok, %{route | profile: profile, provider_id: provider.id}}
    else
      _ -> {:error, :provider_binding_unavailable}
    end
  end
end
