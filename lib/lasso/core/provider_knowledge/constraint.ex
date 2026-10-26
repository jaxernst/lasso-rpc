defmodule Lasso.RPC.ProviderKnowledge.Constraint do
  @moduledoc "Conservative typed constraints derived from an application's transient error."

  alias Lasso.BlockSync.Observation
  alias Lasso.BlockSync.Registry, as: BlockSyncRegistry
  alias Lasso.Discovery.ErrorClassifier
  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.Observations.HeadSnapshot
  alias Lasso.Providers.Catalog
  alias Lasso.RPC.{AttemptTerminal, RequestAnalysis}
  alias Lasso.RPC.ProviderKnowledge.Revalidation
  alias Lasso.RPC.Response.Success

  @doc "Returns only bounded metadata needed by outcome learners."
  @spec evidence_options(map(), map(), map()) :: keyword()
  def evidence_options(channel, ctx, outcome) do
    constraint = kind(outcome)

    revalidating? =
      match?(%{request_origin: :system, observation_activity: :revalidation}, Map.get(ctx, :opts))

    verification =
      cond do
        verified_local_head?(ctx, outcome) ->
          :known_answer

        revalidating? ->
          Revalidation.verification(outcome.result, ctx.method)

        verified_nonempty?(outcome, ctx.method) ->
          :non_empty

        missing_block?(outcome, ctx.method) ->
          :missing

        true ->
          nil
      end

    historical? =
      (constraint == :archival or not is_nil(verification)) and
        is_integer(RequestAnalysis.historical_height(ctx.method, ctx.params))

    cond do
      constraint == :archival and historical? ->
        [
          constraint_kind: :archival,
          head_height: head_height(channel),
          provider_head_height: provider_head_height(channel)
        ]

      not is_nil(verification) and historical? ->
        [
          constraint_kind: constraint,
          head_height: head_height(channel),
          result_verification: verification
        ]

      true ->
        [constraint_kind: constraint, result_verification: verification]
    end
  end

  # HeadPolicy already validated the dispatched header before rewriting it to
  # the client's scalar block number. Reuse that accepted evidence, not its body.
  defp verified_local_head?(
         %{
           method: "eth_blockNumber",
           head_policy: %{
             mode: "local",
             last_error: nil,
             evidence: %{upstream_method: "eth_getBlockByNumber", block_number: number}
           }
         },
         %{
           fact: %AttemptTerminal.Response{kind: :success},
           result: {:ok, %Success{}, _elapsed}
         }
       )
       when is_binary(number) and byte_size(number) <= 66,
       do: true

  defp verified_local_head?(_ctx, _outcome), do: false

  @spec kind(map()) :: :block_range | :archival | :quota_exhaustion | :result_volume | nil
  def kind(
        %{
          fact: %AttemptTerminal.Response{kind: :application_error},
          result: {:error, %JError{} = error, _elapsed}
        } = outcome
      ) do
    if Lasso.Core.Support.ErrorClassification.quota_exhausted?(error.http_status) or
         Lasso.Core.Support.ErrorClassification.quota_exhausted?(error.message),
       do: :quota_exhaustion,
       else: request_constraint(error) || historical_kind(outcome)
  end

  def kind(%{fact: fact, result: {:error, error}}),
    do: kind(%{fact: fact, result: {:error, error, 0}})

  def kind(_), do: nil

  defp request_constraint(%JError{resolution: %{constraint_claim: :block_span}}),
    do: :block_range

  defp request_constraint(%JError{resolution: %{constraint_claim: :result_volume}}),
    do: :result_volume

  defp request_constraint(_error), do: nil

  defp historical_kind(%{
         fact: %AttemptTerminal.Response{kind: :application_error},
         result: {:error, %JError{category: :capability_violation, message: message}, _elapsed}
       })
       when is_binary(message) do
    message = String.slice(message, 0, 4_096)

    if explicit_archival?(message), do: :archival
  end

  defp historical_kind(%{
         fact: %AttemptTerminal.Response{kind: :application_error},
         result: {:error, %JError{category: :block_not_available, message: message}, _elapsed}
       })
       when is_binary(message) do
    if explicit_archival?(String.slice(message, 0, 4_096)), do: :archival
  end

  defp historical_kind(_), do: nil

  defp explicit_archival?(message) do
    msg = String.downcase(message)
    not String.contains?(msg, "header not found") and ErrorClassifier.state_unavailable?(msg)
  end

  defp verified_nonempty?(%{result: {:ok, %Success{} = response, _elapsed}}, method),
    do: Success.verifiable_nonempty?(response, method)

  defp verified_nonempty?(%{result: {:ok, %Success{} = response}}, method),
    do: Success.verifiable_nonempty?(response, method)

  defp verified_nonempty?(_, _method), do: false

  # A null block is a scoped miss for one upstream at one time. Historical-depth
  # learning counts only verified non-empty answers, so it never becomes depth
  # evidence.
  defp missing_block?(%{result: {:ok, %Success{} = response, _elapsed}}, "eth_getBlockByNumber"),
    do: Success.null_result?(response)

  defp missing_block?(%{result: {:ok, %Success{} = response}}, "eth_getBlockByNumber"),
    do: Success.null_result?(response)

  defp missing_block?(_outcome, _method), do: false

  defp head_height(channel) do
    with %{table: _table} = snapshot <- Catalog.snapshot(),
         {:ok, plan} <- Catalog.get_routing_plan(snapshot, channel.profile, channel.chain_id),
         {:ok, head_snapshot} <- BlockSyncRegistry.get_cached_head_snapshot(plan.head_scope) do
      HeadSnapshot.archive_reference_height(head_snapshot)
    else
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp provider_head_height(channel) do
    with %{table: _} = snapshot <- Catalog.snapshot(),
         {:ok, plan} <- Catalog.get_routing_plan(snapshot, channel.profile, channel.chain_id),
         provider when not is_nil(provider) <-
           Enum.find(plan.providers, &(&1.instance_id == channel.instance_id)),
         {:ok, %{height: height}} <-
           Observation.read_transport(
             channel.chain_id,
             channel.instance_id,
             channel.transport,
             System.system_time(:millisecond),
             Map.fetch!(provider.head_freshness_ms, channel.transport)
           ) do
      height
    else
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end
end
