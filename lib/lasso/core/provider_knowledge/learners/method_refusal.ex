defmodule Lasso.RPC.ProviderKnowledge.Learners.MethodRefusal do
  @moduledoc "Request-supported method refusal and bounded credential-wide exhaustion."
  @behaviour Lasso.RPC.ProviderKnowledge.Learner

  alias Lasso.RPC.{BoundedIdentifier, MethodRegistry}
  alias Lasso.RPC.ProviderKnowledge.Evidence
  alias Lasso.RPC.ProviderKnowledge.Stats.DecayedCounter
  alias Lasso.RPC.RoutingEvidence.Workload

  @version 2
  @methods MethodRegistry.all_methods()
  @quota_version 3
  @metered_methods @methods -- ["eth_chainId", "net_version", "web3_clientVersion"]
  @unregistered_limit 64
  @half_life_ms 3_600_000
  @sample_limit 64
  @max_state_bytes 8_192

  @enforce_keys [:key, :epoch, :refusals, :successes, :samples]
  defstruct @enforce_keys ++ [:observed_at_ms]

  @type t :: %__MODULE__{}

  @impl true
  def bounds,
    do: %{
      max_keys: 8_192,
      max_state_bytes: @max_state_bytes,
      version: @quota_version
    }

  @spec unregistered_limit() :: pos_integer()
  def unregistered_limit, do: @unregistered_limit

  @impl true
  def key(%Evidence{method: method} = evidence) when is_binary(method) do
    if outcome_kind(evidence) == :skip,
      do: :skip,
      else: {evidence.subject, evidence.partition, method}
  end

  def key(_), do: :skip

  @doc "One reserved credential-wide row, separate from ordinary method evidence."
  @spec quota_key(Evidence.t()) :: {binary(), :client, :quota} | :skip
  def quota_key(%Evidence{} = evidence) do
    with kind when kind != :skip <- quota_kind(evidence),
         partition when partition == :client <- quota_partition(evidence) do
      {evidence.subject, partition, :quota}
    else
      _ -> :skip
    end
  end

  @spec quota_partition(map()) :: :client | nil
  def quota_partition(%{partition: partition}) do
    if Workload.client?(partition) or Workload.system?(partition), do: :client
  end

  @doc "Static identity replies cannot demonstrate recovery of a metered credential."
  @spec quota_recovery?(term(), term()) :: boolean()
  def quota_recovery?("eth_blockNumber", verification), do: verification == :known_answer
  def quota_recovery?(method, _verification), do: method in @metered_methods

  @impl true
  def init(key) do
    %__MODULE__{
      key: key,
      epoch: 0,
      refusals: DecayedCounter.new(@half_life_ms),
      successes: DecayedCounter.new(@half_life_ms),
      samples: MapSet.new()
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

  defp observe_current(%{key: {_, _, :quota}} = state, evidence) do
    case quota_kind(evidence) do
      :skip ->
        state

      kind ->
        %{
          state
          | samples:
              retain_quota(
                MapSet.put(state.samples, {evidence.observed_at_ms, kind, evidence.request_nonce})
              ),
            observed_at_ms: max_optional(state.observed_at_ms, evidence.observed_at_ms)
        }
    end
  end

  defp observe_current(state, evidence) do
    now_ms = evidence.observed_at_ms

    case outcome_kind(evidence) do
      :refusal ->
        %{
          state
          | refusals: DecayedCounter.observe(state.refusals, 1, now_ms),
            samples:
              retain(MapSet.put(state.samples, {now_ms, :refusal, evidence.request_nonce})),
            observed_at_ms: max_optional(state.observed_at_ms, now_ms)
        }

      :success ->
        %{
          state
          | successes: DecayedCounter.observe(state.successes, 1, now_ms),
            samples:
              retain(MapSet.put(state.samples, {now_ms, :success, evidence.request_nonce})),
            observed_at_ms: max_optional(state.observed_at_ms, now_ms)
        }

      :skip ->
        state
    end
  end

  @impl true
  def decay(%__MODULE__{key: {_, _, :quota}} = state, now_ms),
    do:
      if(
        MapSet.size(state.samples) == 0 or not is_integer(state.observed_at_ms) or
          now_ms - state.observed_at_ms >= :timer.hours(24),
        do: :expired,
        else: state
      )

  def decay(%__MODULE__{} = state, now_ms) do
    samples = fresh_samples(state.samples, now_ms)

    if MapSet.size(samples) == 0 do
      :expired
    else
      %{
        state
        | refusals: DecayedCounter.decay(state.refusals, max(now_ms, state.refusals.as_of_ms)),
          successes: DecayedCounter.decay(state.successes, max(now_ms, state.successes.as_of_ms)),
          samples: samples
      }
    end
  end

  @impl true
  def merge(%__MODULE__{epoch: left_epoch} = left, %__MODULE__{
        epoch: right_epoch
      })
      when left_epoch > right_epoch,
      do: left

  def merge(
        %__MODULE__{epoch: left_epoch},
        %__MODULE__{epoch: right_epoch} = right
      )
      when left_epoch < right_epoch,
      do: right

  def merge(%__MODULE__{key: {_, _, :quota} = key} = left, %__MODULE__{key: key} = right) do
    %{
      left
      | samples: retain_quota(MapSet.union(left.samples, right.samples)),
        observed_at_ms: max_optional(left.observed_at_ms, right.observed_at_ms)
    }
  end

  def merge(%__MODULE__{key: key} = left, %__MODULE__{key: key} = right) do
    %{
      left
      | refusals: DecayedCounter.merge(left.refusals, right.refusals),
        successes: DecayedCounter.merge(left.successes, right.successes),
        samples: retain(MapSet.union(left.samples, right.samples)),
        observed_at_ms: max_optional(left.observed_at_ms, right.observed_at_ms)
    }
  end

  @impl true
  def hints(%__MODULE__{key: {_, _, :quota}} = state, {:quota_exhaustion, :quota}) do
    failures = Enum.filter(state.samples, &(elem(&1, 1) == :refusal))

    if length(failures) == 2 and state.observed_at_ms <= System.system_time(:millisecond) and
         System.system_time(:millisecond) - state.observed_at_ms < :timer.hours(24) do
      [
        %{
          kind: :quota_exhaustion,
          dimension: :quota,
          value: true,
          support: %{distinct_requests: 2, failures: 2},
          learner: __MODULE__,
          version: @quota_version,
          observed_at_ms: state.observed_at_ms
        }
      ]
    else
      []
    end
  end

  def hints(%__MODULE__{key: {_subject, _partition, method}} = state, {:method_refusal, method})
      when is_binary(method) do
    now_ms = System.system_time(:millisecond)
    refusals = DecayedCounter.value(state.refusals, max(now_ms, state.refusals.as_of_ms))
    successes = DecayedCounter.value(state.successes, max(now_ms, state.successes.as_of_ms))
    denominator = refusals + successes

    refusal_samples =
      state.samples
      |> fresh_samples(now_ms)
      |> Enum.filter(fn {_at_ms, kind, _nonce} -> kind == :refusal end)

    distinct_requests =
      refusal_samples
      |> Enum.map(&elem(&1, 2))
      |> Enum.uniq()
      |> length()

    rate = if denominator > 0, do: refusals / denominator, else: 0.0

    if is_integer(state.observed_at_ms) and now_ms < state.observed_at_ms + @half_life_ms and
         rate >= 0.8 and length(refusal_samples) >= 3 and distinct_requests >= 2 do
      [
        %{
          kind: :method_refusal,
          dimension: method,
          value: true,
          support: %{
            refusal_rate: rate,
            refusals: length(refusal_samples),
            successes:
              Enum.count(fresh_samples(state.samples, now_ms), &(elem(&1, 1) == :success)),
            decayed_refusals: refusals,
            decayed_successes: successes,
            distinct_requests: distinct_requests
          },
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

  def hints(_, _), do: []

  @impl true
  def publication(%__MODULE__{key: {_, _, :quota}} = state) do
    deferral = hints(state, {:quota_exhaustion, :quota}) != []
    {{state.samples, deferral}, if(deferral, do: :timer.minutes(30))}
  end

  def publication(%__MODULE__{key: {_, _, method}} = state) do
    recovery = Enum.any?(state.samples, &(elem(&1, 1) == :success))
    deferral = hints(state, {:method_refusal, method}) != []
    {{recovery, deferral}, if(deferral, do: :timer.minutes(30))}
  end

  @doc "Fresh answered/refused evidence, including facts below the deferral threshold."
  @spec fact(t()) :: map() | nil
  def fact(%__MODULE__{key: {_, _, :quota}}), do: nil

  def fact(%__MODULE__{key: {_subject, _partition, method}} = state) do
    now_ms = System.system_time(:millisecond)
    samples = fresh_samples(state.samples, now_ms)

    if MapSet.size(samples) > 0 do
      %{
        kind: :method_refusal,
        dimension: method,
        support: %{
          refusals: Enum.count(samples, &(elem(&1, 1) == :refusal)),
          successes: Enum.count(samples, &(elem(&1, 1) == :success))
        },
        observed_at_ms: state.observed_at_ms,
        expires_at_ms: state.observed_at_ms + @half_life_ms,
        deferral?: hints(state, {:method_refusal, method}) != []
      }
    end
  end

  @impl true
  def encoded_size_upper_bound(%__MODULE__{} = state),
    do: :erlang.external_size({wire_version(state), state}, compressed: 6)

  defp wire_version(%{key: {_, _, :quota}}), do: @quota_version
  defp wire_version(_state), do: @version

  @impl true
  def encode(%__MODULE__{} = state) do
    payload = :erlang.term_to_binary({wire_version(state), state}, compressed: 6)
    if byte_size(payload) <= @max_state_bytes, do: {:ok, payload}, else: {:error, :too_large}
  end

  @impl true
  def decode(payload) when is_binary(payload) and byte_size(payload) <= @max_state_bytes do
    case :erlang.binary_to_term(payload, [:safe]) do
      {@quota_version, %__MODULE__{key: {subject, partition, :quota}} = state}
      when is_binary(subject) and partition == :client ->
        if valid_state?(state) and valid_quota?(state), do: {:ok, state}, else: {:error, :invalid}

      {@version, %__MODULE__{key: {subject, partition, method}} = state}
      when is_binary(subject) and is_atom(partition) ->
        if BoundedIdentifier.valid?(method) and valid_state?(state),
          do: {:ok, state},
          else: {:error, :invalid}

      {1, %__MODULE__{key: {_subject, _partition, method}} = state} when method in @methods ->
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

  defp quota_kind(%Evidence{
         outcome: :application_error,
         constraint_kind: :quota_exhaustion,
         dispatch_certainty: :dispatched
       }),
       do: :refusal

  defp quota_kind(%Evidence{
         outcome: :success,
         qualification: :accepted,
         dispatch_certainty: :dispatched,
         method: method,
         result_verification: verification
       }) do
    if quota_recovery?(method, verification), do: :success, else: :skip
  end

  defp quota_kind(_), do: :skip

  defp retain_quota(samples) do
    latest_success = samples |> Enum.filter(&(elem(&1, 1) == :success)) |> Enum.max(fn -> nil end)
    recovered_at = if latest_success, do: elem(latest_success, 0), else: -1

    failures =
      samples
      |> Enum.filter(fn {at, kind, _} -> kind == :refusal and at > recovered_at end)
      |> Enum.sort(:desc)
      |> Enum.uniq_by(&elem(&1, 2))
      |> Enum.take(2)

    MapSet.new(if latest_success, do: [latest_success | failures], else: failures)
  end

  # Keep serialized struct tags from bypassing the serving-state contract. Counter
  # masses are bounded well below floating-point overflow even after writer merges.
  defp valid_state?(%__MODULE__{
         key: {subject, partition, dimension},
         epoch: epoch,
         observed_at_ms: observed,
         refusals: refusals,
         successes: successes,
         samples: %MapSet{} = samples
       }) do
    is_binary(subject) and byte_size(subject) in 1..128 and
      partition in Workload.partitions() and is_integer(epoch) and epoch >= 0 and
      is_integer(observed) and observed >= 0 and observed <= System.system_time(:millisecond) and
      DecayedCounter.valid?(refusals, @half_life_ms) and
      DecayedCounter.valid?(successes, @half_life_ms) and
      MapSet.size(samples) in 1..@sample_limit and
      Enum.all?(samples, fn
        {at, kind, nonce}
        when is_integer(at) and at >= 0 and at <= observed and
               kind in [:refusal, :success] ->
          is_binary(nonce) and byte_size(nonce) in 1..128

        _ ->
          false
      end) and
      (dimension == :quota or
         (refusals.as_of_ms <= System.system_time(:millisecond) and
            successes.as_of_ms <= System.system_time(:millisecond)))
  end

  defp valid_state?(_), do: false

  defp valid_quota?(state),
    do: MapSet.size(state.samples) <= 3 and retain_quota(state.samples) == state.samples

  defp outcome_kind(%Evidence{outcome: :success, qualification: :accepted}), do: :success

  defp outcome_kind(evidence),
    do: if(Evidence.method_refusal?(evidence), do: :refusal, else: :skip)

  defp fresh_samples(samples, now_ms) do
    samples
    |> Enum.filter(fn {at_ms, _kind, _nonce} ->
      at_ms <= now_ms and now_ms - at_ms < @half_life_ms
    end)
    |> MapSet.new()
  end

  defp retain(samples),
    do: samples |> Enum.sort(:desc) |> Enum.take(@sample_limit) |> MapSet.new()

  defp max_optional(nil, value), do: value
  defp max_optional(value, nil), do: value
  defp max_optional(left, right), do: max(left, right)
end
