defmodule Lasso.RPC.ProviderKnowledge.DisprovalWitness do
  @moduledoc """
  Joins a provider error to the peer that then served the same request.

  An upstream error on a replay-safe read is held on the request. When a
  different upstream instance's success is served to the client, each held
  error becomes a disproval on the feedback lane, attributed to that peer. A
  missing-block answer that null recovery holds or returns serves nothing, so
  it disproves nothing.

  Errors another mechanism already owns feed that mechanism instead: credential
  health for authentication, capacity tiers and the quota latch for rate limits
  and quota, method refusal for unknown methods, head suitability for missing
  blocks, and the span and history learners for typed constraints.
  """

  alias Lasso.Core.Support.ErrorClassifier
  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.RPC.{AttemptTerminal, ExecutionEnvelope, ProviderKnowledge}
  alias Lasso.RPC.ProviderKnowledge.Constraint

  @max_candidates 4
  @owned [
    :auth_error,
    :rate_limit,
    :quota,
    :quota_exhausted,
    :method_not_found,
    :block_not_available
  ]

  @doc "Holds an upstream error that a later served peer would disprove."
  @spec observe(map(), map(), map(), keyword()) :: map()
  def observe(
        ctx,
        %{learning_subject: %{id: _}} = channel,
        %{fact: %AttemptTerminal.Response{kind: :application_error} = fact, result: result} =
          outcome,
        opts
      ) do
    if ExecutionEnvelope.classify(ctx.method) == :replay_safe and
         length(ctx.disproval_candidates) < @max_candidates and unowned?(outcome, result) do
      opts = Keyword.put(opts, :template_fingerprint, fingerprint(result))
      %{ctx | disproval_candidates: ctx.disproval_candidates ++ [{channel, fact, opts}]}
    else
      ctx
    end
  end

  def observe(ctx, _channel, _outcome, _opts), do: ctx

  @doc "Attributes the held errors to the channel whose success the client receives."
  @spec served(map(), map()) :: map()
  def served(%{disproval_candidates: [_ | _] = candidates} = ctx, witness) do
    for {channel, fact, opts} <- candidates, channel.instance_id != witness.instance_id do
      ProviderKnowledge.record_disproval(channel, ctx, fact, opts, witness)
    end

    %{ctx | disproval_candidates: []}
  end

  def served(ctx, _witness), do: ctx

  defp unowned?(outcome, result) do
    case error(result) do
      %JError{category: category} ->
        category not in @owned and is_nil(Constraint.kind(outcome))

      nil ->
        false
    end
  end

  defp error({:error, %JError{} = error, _elapsed}), do: error
  defp error({:error, %JError{} = error}), do: error
  defp error(_result), do: nil

  defp fingerprint({:error, %JError{message: message}, _elapsed}), do: fingerprint_of(message)
  defp fingerprint({:error, %JError{message: message}}), do: fingerprint_of(message)
  defp fingerprint(_result), do: nil

  defp fingerprint_of(message) when is_binary(message),
    do: ErrorClassifier.message_fingerprint(message)

  defp fingerprint_of(_message), do: nil
end
