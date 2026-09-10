defmodule Lasso.BlockPublication.Admission do
  @moduledoc "Request-local admission. Open grants use ETS; handoffs may wait for local notification."
  alias Lasso.BlockPublication.{Gate, Handoff}
  alias Lasso.Core.Request.ExecutionScope
  alias Lasso.JSONRPC.{Error, Quantity}
  alias Lasso.RPC.{HeadPolicy, PreparedRequest, RequestContext}
  alias Lasso.RPC.Response.Success

  @spec choose(RequestContext.t(), ExecutionScope.CallerGuard.t() | nil) ::
          {:continue, RequestContext.t()}
          | {:ok, Success.t(), RequestContext.t()}
          | {:error, Error.t() | :caller_abandoned | :deadline_exhausted, RequestContext.t()}
  def choose(ctx, caller_guard \\ nil) do
    if protected_method?(ctx) do
      key = {ctx.opts.profile, ctx.chain_id}

      case read_grant(key, ctx, caller_guard) do
        {:ok, grant} ->
          choose_grant(ctx, key, grant)

        {:error, reason} when reason in [:caller_abandoned, :deadline_exhausted] ->
          {:error, reason, ctx}

        {:error, reason} ->
          {:error, error(reason), ctx}

        :unmanaged ->
          if match?(%{mode: "global"}, ctx.head_policy),
            do: {:error, error(:publication_pending), ctx},
            else: {:continue, ctx}
      end
    else
      {:continue, ctx}
    end
  end

  defp read_grant(key, ctx, caller_guard) do
    case Gate.read(key) do
      {:error, :publication_changing} ->
        Handoff.await(
          key,
          ctx.execution_envelope.deadline_us,
          ExecutionScope.caller_monitor(caller_guard)
        )

      result ->
        result
    end
  end

  defp choose_grant(ctx, key, grant) do
    evidence = %{
      policy: "global",
      scope: "profile_chain_fleet",
      source: "published_block",
      instance: Lasso.Cluster.Topology.self_node_id(),
      generation: Gate.boot(),
      publication_epoch: grant.epoch,
      block_number: grant.block["number"],
      block_hash: grant.block["hash"],
      max_head_age_ms: grant.max_age_ms,
      block_age_ms: max(0, System.system_time(:millisecond) - grant.block["timestamp_ms"]),
      regional_evidence: grant.evidence,
      chain_change: grant.chain_change,
      canonicality: "provider_observed"
    }

    ctx = %{
      ctx
      | head_policy: %{
          key: key,
          mode: "global",
          grant: grant,
          evidence: evidence,
          last_error: nil
        }
    }

    if ctx.method == "eth_getBlockByNumber" and Enum.at(ctx.params, 1) == true do
      {:continue, ctx}
    else
      json = if ctx.method == "eth_blockNumber", do: grant.number_json, else: grant.header_json
      id = ctx.rpc_request["id"]

      response = %Success{
        id: id,
        jsonrpc: "2.0",
        raw_bytes:
          IO.iodata_to_binary([
            ~s({"jsonrpc":"2.0","id":),
            Jason.encode!(id),
            ",\"result\":",
            json,
            "}"
          ])
      }

      {:ok, response, ctx}
    end
  end

  @spec selection_request(RequestContext.t()) :: {String.t(), list()}
  def selection_request(ctx),
    do: {"eth_getBlockByHash", [ctx.head_policy.grant.block["hash"], true]}

  @spec prepare_attempt(RequestContext.t()) :: RequestContext.t()
  def prepare_attempt(ctx) do
    {method, params} = selection_request(ctx)
    request = %{ctx.rpc_request | "method" => method, "params" => params}
    {:ok, prepared} = PreparedRequest.new(request, ctx.prepared_request.transport_id)
    %{ctx | prepared_request: prepared}
  end

  @spec accept(Success.t(), RequestContext.t()) ::
          {:ok, Success.t(), RequestContext.t()} | {:retry, Error.t(), RequestContext.t()}
  def accept(response, ctx) do
    block = ctx.head_policy.grant.block

    with {:ok, %{"number" => number, "hash" => hash, "transactions" => txs}} <-
           Success.decode_result(response),
         {:ok, height} <- Quantity.decode(number),
         true <-
           height == block["height"] and is_binary(hash) and
             String.downcase(hash) == block["hash"],
         true <- is_list(txs) and Enum.all?(txs, &is_map/1) do
      {:ok, response, ctx}
    else
      _ ->
        error = error(:published_block_unavailable)
        {:retry, error, %{ctx | head_policy: %{ctx.head_policy | last_error: error}}}
    end
  end

  @spec guarded?(RequestContext.t()) :: boolean()
  def guarded?(ctx) do
    protected_method?(ctx) and Gate.read({ctx.opts.profile, ctx.chain_id}) != :unmanaged
  end

  defp protected_method?(ctx),
    do: ctx.opts.request_origin == :client and HeadPolicy.acquisition?(ctx.method, ctx.params)

  @spec error(atom()) :: Error.t()
  def error(reason) do
    Error.new(-32_001, "Published block is unavailable",
      category: :block_not_available,
      retriable?: true,
      breaker_penalty?: false,
      data: %{policy: "global", scope: "profile_chain_fleet", reason: Atom.to_string(reason)}
    )
  end
end
