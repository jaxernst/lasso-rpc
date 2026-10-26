defmodule Lasso.RPC.ProviderKnowledge.ShadowAgreement do
  @moduledoc "Bounded local counts of quota proposals against actual provider attempts."

  alias Lasso.RPC.AttemptTerminal
  alias Lasso.RPC.ProviderKnowledge.Learners.MethodRefusal

  @table :lasso_provider_knowledge_shadow_agreement
  @max_keys 4_096
  @max_predictions 40

  @type verdict :: :agree | :disagree | :unobserved

  @spec create_table!() :: :ok
  def create_table! do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    :ok
  end

  @doc "Removes counters for a profile whose request and projection producers are closed."
  @spec retire_profile(binary()) :: :ok
  def retire_profile(profile) do
    :ets.match_delete(@table, {{:_, :_, :_, :_, profile, :_}, :_, :_, :_, :_, :_, :_})
    :ok
  end

  @doc "Counts bounded considered candidates without retaining request or provider identities."
  @spec consider([map()]) :: :ok
  def consider(proposals) do
    Enum.each(proposals, &update(&1, [{5, 1}]))
    :ok
  end

  @spec prepare(map(), map() | list()) :: map()
  def prepare(ctx, %{shadow_proposals: proposals}) when is_list(proposals) do
    pending =
      Enum.reduce(proposals, ctx.shadow_predictions, fn proposal, pending ->
        key = proposal_key(proposal)

        if not Map.has_key?(pending, key) and map_size(pending) < @max_predictions do
          update(proposal, [{6, 1}])
          Map.put(pending, key, Map.put(proposal, :verdict, :unobserved))
        else
          pending
        end
      end)

    %{ctx | shadow_predictions: pending}
  end

  def prepare(ctx, _candidates), do: ctx

  @spec observe(map(), map(), map(), atom(), keyword()) :: map()
  def observe(%{shadow_predictions: pending} = ctx, channel, outcome, qualification, options)
      when map_size(pending) > 0 do
    pending =
      Enum.reduce(pending, %{}, fn {key, proposal}, updated ->
        verdict =
          if proposal.instance_id == channel.instance_id and
               proposal.transport == channel.transport and proposal.verdict == :unobserved,
             do:
               verdict(
                 proposal.kind,
                 outcome,
                 qualification,
                 Keyword.put(
                   options,
                   :quota_recovery?,
                   MethodRefusal.quota_recovery?(
                     Map.get(proposal, :method),
                     Keyword.get(options, :result_verification)
                   )
                 )
               ),
             else: proposal.verdict

        Map.put(updated, key, %{proposal | verdict: verdict})
      end)

    %{ctx | shadow_predictions: pending}
  end

  def observe(ctx, _channel, _outcome, _qualification, _options), do: ctx

  @spec record(map()) :: :ok
  def record(%{shadow_predictions: pending}) do
    Enum.each(pending, fn {_key, proposal} ->
      update(proposal, [
        {position(proposal.verdict), 1},
        {7, if(proposal.verdict == :unobserved, do: 0, else: 1)}
      ])
    end)

    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec counts() :: [map()]
  def counts do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {{profile_class, cohort, chain_id, kind, profile, partition}, agree, disagree,
                    unobserved, considered, predicted, observed} ->
      %{
        profile_class: profile_class,
        cohort: cohort,
        chain_id: chain_id,
        kind: kind,
        origin_profile: profile,
        partition: partition,
        agree: agree,
        disagree: disagree,
        unobserved: unobserved,
        considered: considered,
        predicted: predicted,
        observed: observed
      }
    end)
    |> Enum.sort_by(
      &{&1.profile_class, &1.cohort, &1.chain_id, &1.kind, &1.origin_profile, &1.partition}
    )
  rescue
    ArgumentError -> []
  end

  defp proposal_key(proposal),
    do: {proposal.instance_id, proposal.transport, proposal.kind}

  defp count_key(%{kind: :quota_exhaustion} = proposal),
    do:
      {proposal.profile_class, Map.get(proposal, :cohort, :other), proposal.chain_id,
       proposal.kind, proposal.origin_profile, proposal.partition}

  defp bounded_key(key) do
    if :ets.member(@table, key) or :ets.info(@table, :size) < @max_keys - 32,
      do: key,
      else: {:overflow, elem(key, 1), 0, elem(key, 3), :overflow, :overflow}
  end

  defp update(proposal, increments) do
    key = bounded_key(count_key(proposal))
    :ets.update_counter(@table, key, increments, {key, 0, 0, 0, 0, 0, 0})
  rescue
    ArgumentError -> :ok
  end

  defp verdict(
         :quota_exhaustion,
         %{fact: %AttemptTerminal.Response{kind: :success}},
         :accepted,
         opts
       ) do
    if Keyword.get(opts, :quota_recovery?), do: :disagree, else: :unobserved
  end

  defp verdict(:quota_exhaustion, outcome, _qualification, opts) do
    if Keyword.get(opts, :constraint_kind) == :quota_exhaustion and
         match?(%AttemptTerminal.Response{kind: :application_error}, outcome.fact),
       do: :agree,
       else: :unobserved
  end

  defp position(:agree), do: 2
  defp position(:disagree), do: 3
  defp position(:unobserved), do: 4
end
