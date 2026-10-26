defmodule Lasso.RPC.MissingBlock do
  @moduledoc "Logical-request census of numeric-block answers and recovery."

  alias Lasso.BlockSync.Registry, as: BlockSyncRegistry
  alias Lasso.JSONRPC.Error
  alias Lasso.Observations.HeadSnapshot
  alias Lasso.Providers.Catalog
  alias Lasso.RPC.Response.Success
  alias Lasso.RPC.{RoutingPlan, Selection.CandidateCursor}
  alias Lasso.RPC.Selection.HeadSuitability

  @null_methods ~w(eth_getBlockByNumber eth_getBlockReceipts eth_getBlockTransactionCountByNumber)

  @doc "Whether a validated numeric answer needs head evidence for its missing-block decision."
  @spec candidate?(term(), term()) :: boolean()
  def candidate?(%{method: method} = ctx, outcome) do
    answer = answer(outcome)
    not is_nil(height(ctx)) and (missing?(method, answer) or empty_logs?(method, answer))
  end

  def candidate?(_ctx, _outcome), do: false

  @doc "Records the first ordinary answer and first missing answer independently of retries."
  @spec observe(map(), map(), map(), HeadSuitability.t() | nil) :: map()
  def observe(ctx, channel, outcome, head) do
    case height(ctx) do
      nil -> ctx
      height -> observe_answer(ctx, channel, outcome, head, height)
    end
  end

  defp observe_answer(ctx, channel, outcome, head, height) do
    answer = answer(outcome)
    missing? = missing?(ctx, answer, head, channel)
    metadata = metadata(ctx, channel)

    census =
      if match?({:ok, _}, answer) and not ctx.missing_block.original? do
        emit(:original, Map.put(metadata, :result, if(missing?, do: :missing, else: :present)))
        %{ctx.missing_block | original?: true}
      else
        ctx.missing_block
      end

    census =
      if missing? and is_nil(census.missing) do
        metadata = Map.put(metadata, :position, position(head, channel, height))
        emit(:missing, metadata)
        %{census | missing: metadata}
      else
        census
      end

    %{ctx | missing_block: census}
  end

  @doc "The numeric selector already validated and bounded by request analysis."
  @spec height(term()) :: non_neg_integer() | nil
  def height(%{block_facts: %{block: {:number, height}}})
      when is_integer(height) and height >= 0,
      do: height

  def height(%{block_facts: %{range: {{:number, from}, {:number, to}}}})
      when is_integer(from) and is_integer(to) and from >= 0 and to >= from,
      do: to

  def height(_ctx), do: nil

  @doc "Reads fresh evidence in the current phase's scope, including pinned-provider requests."
  @spec capture(map(), map(), term()) :: HeadSuitability.t() | nil
  def capture(ctx, _channel, %CandidateCursor{plan: plan}), do: capture_plan(plan, ctx)

  def capture(ctx, channel, _source) do
    with %{} = snapshot <- Catalog.snapshot(),
         {:ok, plan} <- Catalog.get_routing_plan(snapshot, channel.profile, ctx.chain_id) do
      capture_plan(plan, ctx)
    else
      _unavailable -> nil
    end
  end

  defp capture_plan(%RoutingPlan{} = plan, ctx) do
    snapshot =
      case BlockSyncRegistry.get_head_snapshot(
             plan.head_scope,
             plan.generation,
             System.system_time(:millisecond)
           ) do
        {:ok, %HeadSnapshot{} = snapshot} -> snapshot
        _unavailable -> :unavailable
      end

    HeadSuitability.capture(plan, ctx.method, ctx.block_facts, height(ctx), snapshot)
  end

  defp answer(%{result: {:ok, result, _latency}}), do: {:ok, result}
  defp answer(%{result: {:error, error, _latency}}), do: {:error, error}
  defp answer(%{result: result}), do: result
  defp answer(_outcome), do: :none

  @doc "Whether a numeric-block answer reports a missing block."
  @spec missing?(String.t(), term()) :: boolean()
  def missing?(method, {:ok, %Success{} = result}) when method in @null_methods,
    do: Success.null_result?(result)

  def missing?(_method, {:error, %Error{category: :block_not_available}}), do: true
  def missing?(_method, _answer), do: false

  @doc "Empty logs are missing only with fresh evidence of a propagation gap."
  @spec missing?(map(), term(), HeadSuitability.t() | nil, map()) :: boolean()
  def missing?(
        %{method: "eth_getLogs"} = ctx,
        {:ok, %Success{} = result},
        %HeadSuitability{evidence: evidence},
        channel
      ) do
    with height when is_integer(height) <- height(ctx),
         true <- Success.empty_array_result?(result),
         %{fresh?: true, height: observed} when is_integer(observed) and observed < height <-
           Map.get(evidence, {channel.instance_id, channel.transport}) do
      Enum.any?(evidence, fn {{instance, _transport}, head} ->
        instance != channel.instance_id and reached?(head, height)
      end)
    else
      _legitimate_empty -> false
    end
  end

  def missing?(ctx, answer, _head, _channel), do: missing?(ctx.method, answer)

  defp empty_logs?("eth_getLogs", {:ok, %Success{} = result}),
    do: Success.empty_array_result?(result)

  defp empty_logs?(_method, _answer), do: false

  defp position(%HeadSuitability{evidence: evidence}, channel, height) do
    route = {channel.instance_id, channel.transport}

    cond do
      reached?(Map.get(evidence, route), height) ->
        :at_or_below_answering

      Enum.any?(evidence, fn {other, head} -> other != route and reached?(head, height) end) ->
        :reached_by_other

      Enum.any?(evidence, fn {_route, head} -> match?(%{fresh?: true}, head) end) ->
        :above_all_fresh

      true ->
        :unknown
    end
  end

  defp position(_head, _channel, _height), do: :unknown

  defp reached?(%{fresh?: true, height: observed}, height) when is_integer(observed),
    do: observed >= height

  defp reached?(_head, _height), do: false

  @doc "Records one final outcome, attributed to its final answering route."
  @spec finish(:ok | :error, term(), map()) :: :ok
  def finish(status, value, ctx) do
    if height(ctx) do
      result =
        cond do
          final_missing?(ctx, {status, value}) -> :missing
          status == :ok -> :present
          true -> :error
        end

      metadata =
        ctx
        |> metadata(ctx.executed_channel)
        |> Map.merge(%{result: result, account_id: ctx.account_id})

      envelope = ctx.execution_envelope

      :telemetry.execute(
        [:lasso, :rpc, :missing_block, :final],
        %{
          count: 1,
          dispatch_count: envelope.dispatch_count,
          elapsed_us: max(System.monotonic_time(:microsecond) - envelope.started_at_us, 0)
        },
        metadata
      )
    end

    :ok
  end

  defp final_missing?(%{missing_block: %{missing: %{provider_id: original}}} = ctx, answer) do
    missing?(ctx.method, answer) or
      (empty_logs?(ctx.method, answer) and provider(ctx.executed_channel) == original)
  end

  defp final_missing?(ctx, answer), do: missing?(ctx.method, answer)

  @doc "Folds recovery decisions into the census of original missing answers."
  @spec decision(map(), atom()) :: :ok
  def decision(%{missing_block: %{missing: metadata}}, reason) when is_map(metadata) do
    :telemetry.execute(
      [:lasso, :rpc, :null_recovery, :decision],
      %{count: 1},
      Map.merge(metadata, %{result: reason, reason: reason})
    )
  end

  def decision(_ctx, _reason), do: :ok

  defp metadata(ctx, channel) do
    %{
      profile: ctx.routing_profile || ctx.opts.profile,
      chain_id: ctx.chain_id,
      method: ctx.method,
      transport: ctx.opts.ingress_transport,
      request_origin: ctx.opts.request_origin,
      provider_id: provider(channel)
    }
  end

  defp provider(%{provider_id: provider}), do: provider
  defp provider(_channel), do: :none

  defp emit(:original, metadata),
    do: :telemetry.execute([:lasso, :rpc, :missing_block, :original], %{count: 1}, metadata)

  defp emit(:missing, metadata),
    do: :telemetry.execute([:lasso, :rpc, :missing_block, :missing], %{count: 1}, metadata)
end
