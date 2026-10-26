defmodule Lasso.RPC.ProviderKnowledge.Census do
  @moduledoc "Private aggregate census of recent provider outcome and feedback-lane loss."

  alias Lasso.Core.ProjectionDispatcher
  alias Lasso.RPC.ProviderKnowledge.Learners.{LocalResponseLatency, OutcomeStatistics}
  alias Lasso.RPC.ProviderKnowledge.Persistence
  alias Lasso.RPC.ProviderKnowledge.ReadModel
  alias Lasso.RPC.ProviderKnowledge.ShadowAgreement
  alias Lasso.RPC.ProviderKnowledge.TemplateClassification
  alias Lasso.RPC.RoutingEvidence.Workload

  @dispatcher Lasso.ExecutionProjectionDispatcher
  @zero_loss %{total: 0, counters: %{}}
  @loss_reasons [
    :bucket_contended,
    :coalesced,
    :expired,
    :invalid_payload,
    :invalid_scope,
    :sink_failure,
    :unavailable,
    :worker_restart
  ]

  @doc "Returns the local node's rolling 48-hour or seven-day census."
  @spec report(pos_integer(), keyword()) :: map()
  def report(hours \\ 48, opts \\ [])
      when hours in [48, 168] and is_list(opts) do
    now_ms = Keyword.get(opts, :now_ms, System.system_time(:millisecond))
    states = ReadModel.snapshot(OutcomeStatistics) |> Enum.map(&elem(&1, 1))

    states
    |> summarize(hours, now_ms, lane_loss(), ReadModel.stats(OutcomeStatistics),
      apply_loss: Persistence.adapter().apply_loss(),
      profile: Keyword.get(opts, :profile)
    )
    |> Map.put(:shadow_since_boot, ShadowAgreement.counts())
    |> Map.put(:classifier_shadow_since_boot, TemplateClassification.counts())
    |> Map.put(:response_latency_read_model, ReadModel.stats(LocalResponseLatency))
  end

  @doc "Aggregates already read local learner snapshots without provider identities."
  @spec summarize([OutcomeStatistics.t()], 48 | 168, non_neg_integer(), map(), map(), keyword()) ::
          map()
  def summarize(states, hours, now_ms, loss, read_model, opts \\ [])
      when hours in [48, 168] and is_list(states) and is_list(opts) do
    apply_loss = Keyword.get(opts, :apply_loss, @zero_loss)
    profile = Keyword.get(opts, :profile)

    {client_states, system_states} = Enum.split_with(states, &client_state?/1)

    scoped_states =
      if profile, do: Enum.filter(client_states, &(&1.profile == profile)), else: client_states

    total = window_counts(scoped_states, now_ms, hours)

    %{
      generated_at: DateTime.from_unix!(now_ms, :millisecond) |> DateTime.to_iso8601(),
      node: Atom.to_string(Node.self()),
      window_hours: hours,
      profile_filter: profile,
      total: summary(total),
      by_profile_class_chain_family: by_class_chain_family(scoped_states, now_ms, hours),
      by_profile: by_profile(client_states, now_ms, hours),
      top_patterns: top_patterns(scoped_states, now_ms, hours),
      system: %{
        total: summary(window_counts(system_states, now_ms, hours)),
        by_profile_class_chain_family: by_class_chain_family(system_states, now_ms, hours)
      },
      lane_loss: loss,
      apply_loss: apply_loss,
      read_model: read_model,
      decision_floor: floor(total, loss, read_model, apply_loss)
    }
  end

  defp client_state?(%{key: {_subject, partition, _dimension}}), do: Workload.client?(partition)

  defp window_counts(states, now_ms, hours) do
    Enum.reduce(states, OutcomeStatistics.empty_counts(), fn state, total ->
      OutcomeStatistics.combine_counts(total, OutcomeStatistics.window(state, now_ms, hours))
    end)
  end

  defp by_class_chain_family(states, now_ms, hours) do
    states
    |> Enum.group_by(&{&1.profile_class, &1.chain_id, &1.method_family})
    |> Enum.map(fn {{profile_class, chain_id, family}, grouped} ->
      %{profile_class: profile_class, chain_id: chain_id, method_family: family}
      |> Map.merge(summary(window_counts(grouped, now_ms, hours)))
    end)
    |> Enum.sort_by(&{&1.profile_class, &1.chain_id, &1.method_family})
  end

  defp by_profile(states, now_ms, hours) do
    states
    |> Enum.group_by(& &1.profile)
    |> Enum.map(fn {profile, grouped} ->
      %{profile: profile} |> Map.merge(summary(window_counts(grouped, now_ms, hours)))
    end)
    |> Enum.sort_by(& &1.profile)
  end

  defp summary(counts) do
    %{
      replay_safe_requests: counts.requests,
      non_replay_safe_requests: counts.non_replay_safe_requests,
      attempts: counts.attempts,
      successes: counts.successes,
      non_quota_failures: counts.non_quota_failures,
      replay_safe_non_quota_failures: counts.replay_safe_non_quota_failures,
      quota_failures: counts.quota_failures,
      within_request_repeats: counts.within_request_repeats,
      across_request_repeats: counts.across_request_repeats,
      comparison_evictions: counts.comparison_evictions,
      repeated_non_quota_failures_per_1000: rate(counts.across_request_repeats, counts.requests),
      elapsed_io_ms: Float.round(counts.elapsed_us / 1_000, 1)
    }
  end

  defp top_patterns(states, now_ms, hours) do
    states
    |> Enum.flat_map(fn state ->
      {_subject, _partition, {_profile, method, shape}} = state.key
      counts = OutcomeStatistics.window(state, now_ms, hours)

      Enum.map(counts.across_classes, fn {class, repeats} ->
        {{state.profile_class, state.chain_id, method, class, shape}, repeats}
      end)
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {{profile_class, chain_id, method, class, shape}, repeats} ->
      %{
        profile_class: profile_class,
        chain_id: chain_id,
        method: to_string(method),
        outcome_class: class,
        shape: inspect(shape),
        across_request_repeats: Enum.sum(repeats)
      }
    end)
    |> Enum.sort_by(&{-&1.across_request_repeats, &1.method, &1.shape})
    |> Enum.take(20)
  end

  defp lane_loss do
    case ProjectionDispatcher.stats(@dispatcher, :learned_feedback) do
      %{counters: counters} ->
        %{
          total: Enum.reduce(@loss_reasons, 0, &(&2 + Map.get(counters, &1, 0))),
          counters: counters
        }

      _ ->
        %{status: :unavailable}
    end
  catch
    :exit, _ -> %{status: :unavailable}
  end

  defp floor(counts, loss, read_model, apply_loss) do
    rate = rate(counts.across_request_repeats, counts.requests)
    pending_items = get_in(apply_loss, [:pending, :items])

    %{
      required_per_1000: 10,
      required_comparable_repeats: 100,
      status:
        cond do
          Map.get(loss, :status) == :unavailable ->
            :lane_unavailable

          Map.get(loss, :total, 0) > 0 or Map.get(apply_loss, :total, 0) > 0 or
            read_model.evictions > 0 or read_model.invalid_state > 0 ->
            :evidence_loss

          get_in(apply_loss, [:pending, :status]) == :unavailable ->
            :lane_unavailable

          is_integer(pending_items) and pending_items > 0 ->
            :evidence_pending

          counts.comparison_evictions > 0 ->
            :comparison_loss

          is_nil(rate) ->
            :insufficient_denominator

          counts.across_request_repeats < 100 ->
            :insufficient_repeats

          rate >= 10 ->
            :met

          true ->
            :below_floor
        end
    }
  end

  defp rate(_numerator, 0), do: nil
  defp rate(numerator, denominator), do: Float.round(numerator * 1_000 / denominator, 2)
end
