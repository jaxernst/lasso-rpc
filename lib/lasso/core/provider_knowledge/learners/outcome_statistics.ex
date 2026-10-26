defmodule Lasso.RPC.ProviderKnowledge.Learners.OutcomeStatistics do
  @moduledoc "Decayed outcome rates and a seven-day, body-free repeated-failure census."
  @behaviour Lasso.RPC.ProviderKnowledge.Learner

  alias Lasso.RPC.ProviderKnowledge.Evidence

  @impl true
  def exchange_scope, do: :local
  alias Lasso.RPC.ProviderKnowledge.Stats.{DecayedCounter, LatencyHistogram}
  alias Lasso.RPC.RoutingEvidence.Workload

  @version 2
  @half_life_ms 15 * 60_000
  @repeat_window_ms 10 * 60_000
  @hour_ms 3_600_000
  @retained_hours 168
  @recent_limit 128
  @max_state_bytes 16_384
  @max_count 9_223_372_036_854_775_807

  @enforce_keys [:key, :epoch, :decayed, :latency, :buckets, :recent]
  defstruct @enforce_keys ++
              [:profile, :profile_class, :chain_id, :method_family, :observed_at_ms]

  @type t :: %__MODULE__{}

  @impl true
  def bounds, do: %{max_keys: 8_192, max_state_bytes: @max_state_bytes, version: @version}

  @impl true
  def key(%Evidence{} = evidence),
    do:
      {evidence.subject, evidence.partition,
       {evidence.profile, metric_method(evidence.method), evidence.shape}}

  @impl true
  def init(key) do
    %__MODULE__{
      key: key,
      epoch: 0,
      decayed: %{},
      latency: LatencyHistogram.new(@half_life_ms),
      buckets: %{},
      recent: %{}
    }
  end

  @impl true
  def observe(%__MODULE__{} = state, %Evidence{} = evidence) do
    cond do
      evidence.epoch < state.epoch ->
        state

      evidence.epoch > state.epoch ->
        observe(%{init(state.key) | epoch: evidence.epoch}, evidence)

      true ->
        observe_current(state, evidence)
    end
  end

  defp observe_current(state, evidence) do
    now_ms = evidence.observed_at_ms
    class = outcome_class(evidence)
    recent = prune_recent(state.recent, now_ms)
    repeat = repeat_kind(recent, class, evidence)

    {recent, comparison_evictions} =
      if comparable_failure?(class, evidence),
        do: put_recent(recent, class, evidence.request_nonce, now_ms),
        else: {recent, 0}

    counter = Map.get(state.decayed, class, DecayedCounter.new(@half_life_ms, now_ms))

    decayed =
      Map.put(state.decayed, class, DecayedCounter.observe(counter, 1, now_ms))

    latency =
      if evidence.latency_us > 0,
        do: LatencyHistogram.observe(state.latency, evidence.latency_us, now_ms),
        else: state.latency

    hour = div(now_ms, @hour_ms)

    bucket =
      state.buckets
      |> Map.get(hour, empty_bucket())
      |> count_bucket(evidence, class, repeat, comparison_evictions)

    buckets =
      state.buckets
      |> Map.put(hour, bucket)
      |> Map.filter(fn {bucket_hour, _} -> bucket_hour > hour - @retained_hours end)

    %{
      state
      | profile: evidence.profile,
        profile_class: evidence.profile_class,
        chain_id: evidence.chain_id,
        method_family: method_family(evidence.method),
        observed_at_ms: max_optional(state.observed_at_ms, now_ms),
        decayed: decayed,
        latency: latency,
        buckets: buckets,
        recent: recent
    }
  end

  @impl true
  def decay(%__MODULE__{} = state, now_ms) do
    hour = div(now_ms, @hour_ms)

    buckets =
      Map.filter(state.buckets, fn {bucket_hour, _} -> bucket_hour > hour - @retained_hours end)

    if map_size(buckets) == 0 do
      :expired
    else
      %{
        state
        | buckets: buckets,
          recent: prune_recent(state.recent, now_ms),
          decayed:
            Map.new(state.decayed, fn {class, counter} ->
              {class, DecayedCounter.decay(counter, max(now_ms, counter.as_of_ms))}
            end),
          latency: LatencyHistogram.decay(state.latency, now_ms)
      }
    end
  end

  @impl true
  def merge(
        %__MODULE__{epoch: left_epoch} = left,
        %__MODULE__{epoch: right_epoch}
      )
      when left_epoch > right_epoch,
      do: left

  def merge(
        %__MODULE__{epoch: left_epoch},
        %__MODULE__{epoch: right_epoch} = right
      )
      when left_epoch < right_epoch,
      do: right

  def merge(%__MODULE__{key: key} = left, %__MODULE__{key: key} = right) do
    decayed =
      Map.merge(left.decayed, right.decayed, fn _class, a, b -> DecayedCounter.merge(a, b) end)

    buckets = Map.merge(left.buckets, right.buckets, fn _hour, a, b -> merge_bucket(a, b) end)

    recent =
      Map.merge(left.recent, right.recent, fn _class, a, b ->
        (a ++ b) |> Enum.uniq() |> Enum.sort(:desc) |> Enum.take(@recent_limit)
      end)

    %{
      left
      | profile: max_optional(left.profile, right.profile),
        profile_class: max_optional(left.profile_class, right.profile_class),
        chain_id: max_optional(left.chain_id, right.chain_id),
        method_family: max_optional(left.method_family, right.method_family),
        observed_at_ms: max_optional(left.observed_at_ms, right.observed_at_ms),
        decayed: decayed,
        latency: LatencyHistogram.merge(left.latency, right.latency),
        buckets: buckets,
        recent: recent
    }
  end

  @impl true
  def hints(%__MODULE__{} = state, {:outcome_stats, dimension}) do
    if dimension_matches?(elem(state.key, 2), dimension) and is_integer(state.observed_at_ms) do
      now_ms = System.system_time(:millisecond)

      rates =
        Map.new(state.decayed, fn {class, counter} ->
          {class, DecayedCounter.value(counter, max(now_ms, counter.as_of_ms))}
        end)

      [
        %{
          kind: :outcome_stats,
          dimension: dimension,
          value: %{
            rates: rates,
            p95_latency_us: LatencyHistogram.quantile(state.latency, 0.95, now_ms)
          },
          support: aggregate(state.buckets),
          learner: __MODULE__,
          version: @version,
          observed_at_ms: state.observed_at_ms,
          expires_at_ms: state.observed_at_ms + @half_life_ms
        }
      ]
    else
      []
    end
  end

  def hints(_state, _query), do: []

  defp dimension_matches?({_, method, shape}, {method, shape}), do: true
  defp dimension_matches?(_, _), do: false

  @impl true
  def encoded_size_upper_bound(%__MODULE__{} = state),
    do: :erlang.external_size({@version, state}, compressed: 6)

  @impl true
  def encode(%__MODULE__{} = state) do
    payload = :erlang.term_to_binary({@version, state}, compressed: 6)
    if byte_size(payload) <= @max_state_bytes, do: {:ok, payload}, else: {:error, :too_large}
  end

  @impl true
  def decode(payload) when is_binary(payload) and byte_size(payload) <= @max_state_bytes do
    case :erlang.binary_to_term(payload, [:safe]) do
      {@version, %__MODULE__{} = state} ->
        if valid_state?(state), do: {:ok, state}, else: {:error, :invalid}

      {1, %__MODULE__{}} ->
        {:error, {:unsupported_version, 1}}

      _ ->
        {:error, :invalid}
    end
  rescue
    _ -> {:error, :invalid}
  end

  def decode(_), do: {:error, :invalid}

  defp valid_state?(%__MODULE__{
         key: {subject, partition, {profile, method, shape}},
         epoch: epoch,
         observed_at_ms: observed,
         decayed: decayed,
         latency: latency,
         buckets: buckets,
         recent: recent,
         profile: profile,
         profile_class: profile_class,
         chain_id: chain,
         method_family: family
       }) do
    now = System.system_time(:millisecond)

    is_binary(subject) and byte_size(subject) in 1..128 and
      partition in Workload.partitions() and is_binary(profile) and byte_size(profile) in 1..128 and
      method in [:other | Lasso.RPC.MethodRegistry.all_methods()] and
      valid_shape?(shape) and
      is_integer(epoch) and epoch >= 0 and
      is_integer(observed) and observed >= 0 and observed <= now and
      profile_class in [:custom, :managed] and
      is_integer(chain) and chain > 0 and is_atom(family) and
      valid_counters?(decayed) and
      valid_latency?(latency) and
      valid_buckets?(buckets, now) and valid_recent?(recent, observed)
  end

  defp valid_state?(_), do: false

  defp valid_counters?(counters),
    do:
      is_map(counters) and map_size(counters) <= 32 and
        Enum.all?(counters, fn {class, counter} ->
          is_atom(class) and DecayedCounter.valid?(counter, @half_life_ms)
        end)

  defp valid_buckets?(buckets, now) do
    is_map(buckets) and map_size(buckets) <= @retained_hours and
      Enum.all?(buckets, fn {hour, bucket} ->
        is_integer(hour) and hour >= 0 and hour <= div(now, @hour_ms) and
          valid_bucket?(bucket)
      end)
  end

  defp valid_recent?(recent, observed) do
    is_map(recent) and map_size(recent) <= 32 and
      Enum.all?(recent, fn {class, rows} ->
        is_atom(class) and is_list(rows) and length(rows) <= @recent_limit and
          Enum.all?(rows, fn
            {nonce, at} ->
              is_integer(at) and at >= 0 and at <= observed and
                is_binary(nonce) and byte_size(nonce) in 1..128

            _ ->
              false
          end)
      end)
  end

  defp valid_shape?(:other), do: true

  defp valid_shape?({:logs_span, anchor, band}),
    do: anchor in [:hash, :latest, :number] and valid_band?(band)

  defp valid_shape?({:historical_age, resource, band}),
    do:
      resource in [:blocks, :balance, :state, :logs, :receipts, :proofs, :traces] and
        valid_band?(band)

  defp valid_shape?(_), do: false
  defp valid_band?(band), do: band == :unknown or (is_integer(band) and band in 0..63)

  defp valid_latency?(%LatencyHistogram{half_life_ms: @half_life_ms, buckets: buckets}),
    do:
      is_map(buckets) and map_size(buckets) <= 32 and
        Enum.all?(buckets, fn {bucket, counter} ->
          is_integer(bucket) and bucket in 0..31 and DecayedCounter.valid?(counter, @half_life_ms)
        end)

  defp valid_latency?(_), do: false

  defp valid_bucket?(bucket) when is_map(bucket) do
    Map.keys(bucket) |> Enum.sort() == Enum.sort(Map.keys(empty_bucket())) and
      Enum.all?(bucket, fn
        {field, counts} when field in [:classes, :within_classes, :across_classes] ->
          is_map(counts) and map_size(counts) <= 32 and
            Enum.all?(counts, fn {class, n} -> is_atom(class) and valid_count?(n) end)

        {_, n} ->
          valid_count?(n)
      end) and bucket.successes <= bucket.attempts and bucket.requests <= bucket.attempts
  end

  defp valid_bucket?(_), do: false
  defp valid_count?(n), do: is_integer(n) and n >= 0 and n <= @max_count

  @spec window(t(), non_neg_integer(), pos_integer()) :: map()
  def window(%__MODULE__{} = state, now_ms, hours) when is_integer(hours) and hours > 0 do
    current = div(now_ms, @hour_ms)

    state.buckets
    |> Map.filter(fn {hour, _} -> hour > current - hours and hour <= current end)
    |> aggregate()
  end

  @spec combine_counts(map(), map()) :: map()
  def combine_counts(left, right), do: merge_bucket(left, right)

  @spec empty_counts() :: map()
  def empty_counts, do: empty_bucket()

  defp count_bucket(bucket, evidence, class, repeat, comparison_evictions) do
    bucket
    |> increment(:attempts)
    |> maybe_increment(
      :requests,
      evidence.ordinal == 1 and evidence.execution_safety == :replay_safe
    )
    |> maybe_increment(
      :non_replay_safe_requests,
      evidence.ordinal == 1 and evidence.execution_safety != :replay_safe
    )
    |> maybe_increment(:successes, class == :success)
    |> maybe_increment(:quota_failures, class == :quota)
    |> maybe_increment(:non_quota_failures, non_quota_failure?(class))
    |> maybe_increment(:replay_safe_non_quota_failures, comparable_failure?(class, evidence))
    |> maybe_increment(:within_request_repeats, repeat == :within)
    |> maybe_increment(:across_request_repeats, repeat == :across)
    |> Map.update!(:comparison_evictions, &saturating_add(&1, comparison_evictions))
    |> Map.update!(:elapsed_us, &saturating_add(&1, evidence.latency_us))
    |> update_nested(:classes, class)
    |> maybe_update_nested(:within_classes, class, repeat == :within)
    |> maybe_update_nested(:across_classes, class, repeat == :across)
  end

  defp empty_bucket do
    %{
      attempts: 0,
      requests: 0,
      non_replay_safe_requests: 0,
      successes: 0,
      quota_failures: 0,
      non_quota_failures: 0,
      replay_safe_non_quota_failures: 0,
      within_request_repeats: 0,
      across_request_repeats: 0,
      comparison_evictions: 0,
      elapsed_us: 0,
      classes: %{},
      within_classes: %{},
      across_classes: %{}
    }
  end

  defp aggregate(buckets),
    do:
      Enum.reduce(buckets, empty_bucket(), fn {_hour, bucket}, total ->
        merge_bucket(total, bucket)
      end)

  defp merge_bucket(left, right) do
    Map.new(left, fn
      {field, value} when is_map(value) ->
        {field,
         Map.merge(value, Map.fetch!(right, field), fn _class, a, b -> saturating_add(a, b) end)}

      {field, value} ->
        {field, saturating_add(value, Map.fetch!(right, field))}
    end)
  end

  defp repeat_kind(recent, class, evidence) do
    if comparable_failure?(class, evidence) do
      prior = Map.get(recent, class, [])

      cond do
        Enum.any?(prior, fn {nonce, _} -> nonce == evidence.request_nonce end) -> :within
        prior != [] -> :across
        true -> :none
      end
    else
      :none
    end
  end

  defp put_recent(recent, class, nonce, at_ms) do
    entries = [{nonce, at_ms} | Enum.reject(Map.get(recent, class, []), &(elem(&1, 0) == nonce))]

    {Map.put(recent, class, Enum.take(entries, @recent_limit)),
     max(length(entries) - @recent_limit, 0)}
  end

  defp prune_recent(recent, now_ms) do
    recent
    |> Map.new(fn {class, entries} ->
      {class,
       Enum.filter(entries, fn {_nonce, at_ms} ->
         at_ms <= now_ms and now_ms - at_ms < @repeat_window_ms
       end)}
    end)
    |> Map.reject(fn {_class, entries} -> entries == [] end)
  end

  defp outcome_class(%Evidence{outcome: :success, qualification: :accepted}), do: :success
  defp outcome_class(%Evidence{outcome: :success}), do: :policy_rejected

  defp outcome_class(%Evidence{outcome: :application_error, constraint_kind: :quota_exhaustion}),
    do: :quota

  defp outcome_class(%Evidence{outcome: :application_error, error_category: :quota}), do: :quota

  defp outcome_class(%Evidence{outcome: :application_error, error_category: category})
       when is_atom(category),
       do: category

  defp outcome_class(%Evidence{outcome: outcome}), do: outcome

  defp non_quota_failure?(class),
    do: class not in [:success, :policy_rejected, :quota, :cancelled]

  defp comparable_failure?(class, evidence),
    do: non_quota_failure?(class) and evidence.execution_safety == :replay_safe

  defp metric_method(method) when is_binary(method), do: Evidence.method_key(method)
  defp metric_method(_), do: :other

  defp method_family(method) when is_binary(method), do: Workload.family(method)
  defp method_family(_), do: :unknown
  defp increment(bucket, field), do: Map.update!(bucket, field, &saturating_add(&1, 1))
  defp maybe_increment(bucket, _field, false), do: bucket
  defp maybe_increment(bucket, field, true), do: increment(bucket, field)

  defp update_nested(bucket, field, class),
    do: Map.update!(bucket, field, &Map.update(&1, class, 1, fn n -> saturating_add(n, 1) end))

  defp maybe_update_nested(bucket, _field, _class, false), do: bucket
  defp maybe_update_nested(bucket, field, class, true), do: update_nested(bucket, field, class)
  defp saturating_add(a, b), do: min(a + b, @max_count)
  defp max_optional(nil, value), do: value
  defp max_optional(value, nil), do: value
  defp max_optional(left, right), do: max(left, right)
end
