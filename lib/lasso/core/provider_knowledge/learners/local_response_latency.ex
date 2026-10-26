defmodule Lasso.RPC.ProviderKnowledge.Learners.LocalResponseLatency do
  @moduledoc """
  Recent accepted response latency for one concrete route on one serving node.

  The histogram has at most five percent relative bucket error. Failures and
  censored attempts are counted separately and never enter its quantiles.
  This state is deliberately excluded from cross-node snapshot exchange.
  """

  @behaviour Lasso.RPC.ProviderKnowledge.Learner

  alias Lasso.RPC.BoundedIdentifier
  alias Lasso.RPC.ProviderKnowledge.Evidence
  alias Lasso.RPC.ProviderKnowledge.Stats.DecayedCounter
  alias Lasso.RPC.RoutingEvidence.Workload

  @version 2
  @half_life_ms :timer.minutes(10)
  @expires_ms :timer.minutes(15)
  @min_samples 64
  @min_effective_successes 48.0
  @max_state_bytes 16_384
  @max_bucket 512
  @bucket_base 1.05

  @enforce_keys [
    :key,
    :epoch,
    :latency,
    :accepted_samples,
    :successes,
    :failures,
    :censored,
    :incomplete
  ]
  defstruct @enforce_keys ++ [:observed_at_ms, :accepted_at_ms, :p50_latency_us, :p95_latency_us]

  @type t :: %__MODULE__{}

  @impl true
  def exchange_scope, do: :local

  @impl true
  def bounds, do: %{max_keys: 2_048, max_state_bytes: @max_state_bytes, version: @version}

  @impl true
  def key(%Evidence{} = evidence),
    do:
      {evidence.subject, evidence.partition,
       {evidence.origin_node, evidence.instance_id, evidence.method}}

  @impl true
  def init(key) do
    %__MODULE__{
      key: key,
      epoch: 0,
      latency: %{},
      accepted_samples: 0,
      successes: DecayedCounter.new(@half_life_ms),
      failures: DecayedCounter.new(@half_life_ms),
      censored: DecayedCounter.new(@half_life_ms),
      incomplete: DecayedCounter.new(@half_life_ms)
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
        updated =
          state
          |> observe_outcome(evidence)
          |> Map.put(:observed_at_ms, max(state.observed_at_ms || 0, evidence.observed_at_ms))

        summarize(updated, updated.observed_at_ms)
    end
  end

  defp observe_outcome(state, %Evidence{outcome: :success, qualification: :accepted} = evidence)
       when evidence.latency_us > 0 and evidence.dispatch_certainty == :dispatched do
    bucket = bucket(evidence.latency_us)
    counter = Map.get(state.latency, bucket, DecayedCounter.new(@half_life_ms))

    %{
      state
      | latency:
          Map.put(
            state.latency,
            bucket,
            DecayedCounter.observe(counter, 1, evidence.observed_at_ms)
          ),
        accepted_samples: min(state.accepted_samples + 1, 1_000_000_000),
        successes: DecayedCounter.observe(state.successes, 1, evidence.observed_at_ms),
        accepted_at_ms: max(state.accepted_at_ms || 0, evidence.observed_at_ms)
    }
  end

  defp observe_outcome(state, %Evidence{outcome: outcome} = evidence)
       when outcome in [:cancelled, :deadline],
       do: %{state | censored: DecayedCounter.observe(state.censored, 1, evidence.observed_at_ms)}

  defp observe_outcome(state, %Evidence{outcome: :success} = evidence),
    do: %{
      state
      | incomplete: DecayedCounter.observe(state.incomplete, 1, evidence.observed_at_ms)
    }

  defp observe_outcome(state, evidence),
    do: %{state | failures: DecayedCounter.observe(state.failures, 1, evidence.observed_at_ms)}

  @impl true
  def decay(%__MODULE__{observed_at_ms: nil}, _now_ms), do: :expired

  def decay(%__MODULE__{observed_at_ms: observed_at_ms}, now_ms)
      when now_ms - observed_at_ms >= @expires_ms,
      do: :expired

  def decay(%__MODULE__{} = state, now_ms), do: summarize(state, now_ms)

  @impl true
  def merge(%__MODULE__{epoch: left_epoch} = left, %__MODULE__{
        epoch: right_epoch
      })
      when left_epoch > right_epoch,
      do: left

  def merge(
        %__MODULE__{epoch: left_epoch},
        %__MODULE__{
          epoch: right_epoch
        } = right
      )
      when left_epoch < right_epoch,
      do: right

  def merge(%__MODULE__{key: key} = left, %__MODULE__{key: key} = right) do
    at_ms = max(left.observed_at_ms || 0, right.observed_at_ms || 0)

    %{
      left
      | observed_at_ms: at_ms,
        accepted_at_ms: max(left.accepted_at_ms || 0, right.accepted_at_ms || 0),
        latency:
          Map.merge(left.latency, right.latency, fn _bucket, a, b ->
            DecayedCounter.merge(a, b)
          end),
        accepted_samples: min(left.accepted_samples + right.accepted_samples, 1_000_000_000),
        successes: DecayedCounter.merge(left.successes, right.successes),
        failures: DecayedCounter.merge(left.failures, right.failures),
        censored: DecayedCounter.merge(left.censored, right.censored),
        incomplete: DecayedCounter.merge(left.incomplete, right.incomplete)
    }
    |> summarize(at_ms)
  end

  @impl true
  def hints(
        %__MODULE__{key: {_subject, _partition, dimension}} = state,
        {:response_latency, dimension}
      ) do
    now_ms = System.system_time(:millisecond)
    successes = DecayedCounter.value(state.successes, max(now_ms, state.successes.as_of_ms))

    if is_integer(state.accepted_at_ms) and state.accepted_at_ms <= now_ms and
         now_ms - state.accepted_at_ms < @expires_ms and
         state.accepted_samples >= @min_samples and
         successes >= @min_effective_successes and is_integer(state.p95_latency_us) do
      [
        %{
          kind: :response_latency,
          dimension: dimension,
          value: %{p50_us: state.p50_latency_us, p95_us: state.p95_latency_us},
          support: %{
            accepted_samples: state.accepted_samples,
            accepted_successes: successes,
            failures: DecayedCounter.value(state.failures, max(now_ms, state.failures.as_of_ms)),
            censored: DecayedCounter.value(state.censored, max(now_ms, state.censored.as_of_ms)),
            incomplete:
              DecayedCounter.value(state.incomplete, max(now_ms, state.incomplete.as_of_ms))
          },
          resolution: :five_percent_buckets,
          learner: __MODULE__,
          version: @version,
          observed_at_ms: state.accepted_at_ms,
          expires_at_ms:
            min(
              state.accepted_at_ms + @expires_ms,
              now_ms + trunc(@half_life_ms * :math.log2(successes / @min_effective_successes))
            )
        }
      ]
    else
      []
    end
  end

  def hints(_state, _query), do: []

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
      {@version, %__MODULE__{key: {subject, partition, {origin, instance, _method}}} = state}
      when is_binary(subject) and is_atom(partition) and is_binary(origin) and
             is_binary(instance) and map_size(state.latency) <= @max_bucket + 1 ->
        if valid_state?(state),
          do: {:ok, summarize(state, state.observed_at_ms)},
          else: {:error, :invalid}

      _ ->
        {:error, :invalid}
    end
  rescue
    _ -> {:error, :invalid}
  end

  def decode(_), do: {:error, :invalid}

  defp valid_state?(%__MODULE__{
         key: {subject, partition, {origin, instance, method}},
         epoch: epoch,
         observed_at_ms: observed,
         accepted_at_ms: accepted,
         latency: latency,
         accepted_samples: samples,
         successes: successes,
         failures: failures,
         censored: censored,
         incomplete: incomplete,
         p50_latency_us: _,
         p95_latency_us: _
       }) do
    now = System.system_time(:millisecond)

    valid_identity?(subject, partition, origin, instance, method) and
      is_integer(epoch) and epoch >= 0 and
      is_integer(observed) and observed >= 0 and observed <= now and
      (is_nil(accepted) or (is_integer(accepted) and accepted >= 0 and accepted <= observed)) and
      is_integer(samples) and samples in 0..1_000_000_000 and
      Enum.all?(
        [successes, failures, censored, incomplete],
        &DecayedCounter.valid?(&1, @half_life_ms)
      ) and
      valid_latency?(latency) and
      (samples == 0 or (is_integer(accepted) and map_size(latency) > 0))
  end

  defp valid_state?(_), do: false

  defp valid_identity?(subject, partition, origin, instance, method),
    do:
      is_binary(subject) and byte_size(subject) in 1..128 and
        partition in Workload.partitions() and
        Enum.all?([origin, instance, method], &BoundedIdentifier.valid?/1)

  defp valid_latency?(latency),
    do:
      is_map(latency) and map_size(latency) <= @max_bucket + 1 and
        Enum.all?(latency, fn {bucket, counter} ->
          is_integer(bucket) and bucket in 0..@max_bucket and
            DecayedCounter.valid?(counter, @half_life_ms)
        end)

  defp summarize(state, at_ms) do
    {weighted, total} =
      Enum.reduce(state.latency, {[], 0.0}, fn {bucket, counter}, {weighted, total} ->
        weight = DecayedCounter.value(counter, max(at_ms, counter.as_of_ms))
        {[{bucket, weight} | weighted], total + weight}
      end)

    sorted = Enum.sort_by(weighted, &elem(&1, 0))

    %{
      state
      | p50_latency_us: quantile(sorted, total, 0.50),
        p95_latency_us: quantile(sorted, total, 0.95)
    }
  end

  defp quantile(_sorted, total, _quantile) when total == 0, do: nil

  defp quantile(sorted, total, quantile) do
    result =
      Enum.reduce_while(sorted, 0.0, fn {bucket, weight}, cumulative ->
        next = cumulative + weight

        if next >= quantile * total,
          do: {:halt, ceil(:math.pow(@bucket_base, bucket))},
          else: {:cont, next}
      end)

    if is_integer(result),
      do: result,
      else: sorted |> List.last() |> elem(0) |> then(&ceil(:math.pow(@bucket_base, &1)))
  end

  defp bucket(latency_us),
    do: min(ceil(:math.log(latency_us) / :math.log(@bucket_base)), @max_bucket)
end
