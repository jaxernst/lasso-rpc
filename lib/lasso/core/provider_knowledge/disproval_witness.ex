defmodule Lasso.RPC.ProviderKnowledge.DisprovalWitness do
  @moduledoc """
  Joins a provider error to the peer that then served the same request.

  An upstream error on a replay-safe read is held on the request. When a
  different upstream instance's success is served to the client, each held
  error becomes a disproval on the feedback lane, attributed to that peer. A
  missing-block answer that null recovery holds or returns serves nothing, so
  it disproves nothing.

  Only errors that `Constraint.evidence_options/3` marks as disprovable, by
  their message fingerprint, are held; errors another mechanism owns feed that
  mechanism instead.
  """

  alias Lasso.RPC.{AttemptTerminal, ExecutionEnvelope, ProviderKnowledge}

  @max_candidates 4

  @doc "Holds an upstream error that a later served peer would disprove."
  @spec observe(map(), map(), map(), keyword()) :: map()
  def observe(
        ctx,
        %{learning_subject: %{id: _}} = channel,
        %{fact: %AttemptTerminal.Response{kind: :application_error} = fact},
        opts
      ) do
    if Keyword.has_key?(opts, :template_fingerprint) and
         ExecutionEnvelope.classify(ctx.method) == :replay_safe and
         length(ctx.disproval_candidates) < @max_candidates,
       do: %{ctx | disproval_candidates: ctx.disproval_candidates ++ [{channel, fact, opts}]},
       else: ctx
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
end
