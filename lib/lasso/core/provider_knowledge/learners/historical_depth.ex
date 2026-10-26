defmodule Lasso.RPC.ProviderKnowledge.Learners.HistoricalDepth do
  @moduledoc """
  Retained history observations classified off path as an age cutoff, a height
  floor, or non-monotone evidence withheld from routing. Age wins monotone ties.
  Request readers consume the cached hint, never traverse observations.
  """
  @behaviour Lasso.RPC.ProviderKnowledge.Learner
  alias Lasso.RPC.ProviderKnowledge.Evidence
  alias Lasso.RPC.ProviderKnowledge.Stats.Bracket
  @version 3
  @retention_ms :timer.hours(24 * 30)
  @freshness_ms :timer.minutes(30)
  @max_state_bytes 16_384
  @enforce_keys [:key, :epoch, :bracket]
  defstruct @enforce_keys ++ [:observed_at_ms, :hint, :memory, classification: :unknown]
  @type t :: %__MODULE__{}

  @impl true
  def bounds, do: %{max_keys: 4_096, max_state_bytes: @max_state_bytes, version: @version}

  @impl true
  def key(%Evidence{historical_resource: resource, method: method} = evidence)
      when is_binary(method) do
    if resource in [:blocks, :balance, :state, :logs, :receipts, :proofs, :traces] and
         ((is_integer(evidence.historical_age) and evidence.historical_age >= 0) or
            (not is_nil(Map.get(evidence, :historical_height)) and
               Bracket.valid_height?(evidence.historical_height))) and
         observation_kind(evidence) != :skip,
       do: {evidence.subject, evidence_partition(evidence), {resource, method}},
       else: :skip
  end

  def key(_), do: :skip

  @impl true
  def evidence_partition(evidence),
    do: Map.get(evidence, :revalidation_partition) || evidence.partition

  @impl true
  def init(key), do: %__MODULE__{key: key, epoch: 0, bracket: Bracket.new(@retention_ms)}

  @spec lifecycle() :: %{retention_ms: pos_integer(), freshness_ms: pos_integer()}
  def lifecycle, do: %{retention_ms: @retention_ms, freshness_ms: @freshness_ms}

  @doc "Cached retained diagnostics and recovery target, independent of serving freshness."
  @spec retained(t()) :: map() | nil
  def retained(%__MODULE__{memory: nil}), do: nil

  def retained(%__MODULE__{memory: memory} = state) do
    if memory.retained_until_ms > System.system_time(:millisecond),
      do:
        Map.put(
          memory,
          :qualified?,
          memory.qualified? and hints(state, {:historical_depth, memory.dimension}) != []
        )
  end

  @impl true
  def observe(%__MODULE__{} = state, %Evidence{} = evidence) do
    cond do
      evidence.epoch < state.epoch ->
        state

      evidence.epoch > state.epoch ->
        observe(%{init(state.key) | epoch: evidence.epoch}, evidence)

      true ->
        case observation_kind(evidence) do
          :skip ->
            state

          kind ->
            %{
              state
              | bracket:
                  Bracket.observe(
                    state.bracket,
                    kind,
                    evidence.historical_age,
                    evidence.observed_at_ms,
                    observation_id(evidence.request_nonce),
                    Map.get(evidence, :historical_height)
                  ),
                observed_at_ms: max_optional(state.observed_at_ms, evidence.observed_at_ms)
            }
            |> classify(System.system_time(:millisecond))
        end
    end
  end

  @impl true
  def decay(%__MODULE__{} = state, now_ms) do
    state = %{state | bracket: Bracket.decay(state.bracket, now_ms)}
    if MapSet.size(state.bracket.observations) == 0, do: :expired, else: classify(state, now_ms)
  end

  @impl true
  def merge(%__MODULE__{epoch: l} = left, %__MODULE__{epoch: r}) when l > r, do: left
  def merge(%__MODULE__{epoch: l}, %__MODULE__{epoch: r} = right) when l < r, do: right

  def merge(%__MODULE__{key: key} = left, %__MODULE__{key: key} = right) do
    %{
      left
      | bracket: Bracket.merge(left.bracket, right.bracket),
        observed_at_ms: max_optional(left.observed_at_ms, right.observed_at_ms)
    }
    |> classify(System.system_time(:millisecond))
  end

  @impl true
  def hints(%__MODULE__{key: {_, _, {resource, _}}, hint: hint}, {:historical_depth, resource})
      when is_map(hint) do
    if hint.expires_at_ms > System.system_time(:millisecond), do: [hint], else: []
  end

  def hints(_, _), do: []

  @impl true
  def publication(%__MODULE__{key: {_, _, {resource, _}}} = state) do
    hints = hints(state, {:historical_depth, resource})

    recovery =
      for {at, :success, age, _request, height} <- state.bracket.observations,
          do: {at, age, height}

    fingerprint =
      {state.classification,
       Enum.map(hints, &Map.take(&1, [:value, :coordinate, :qualified?, :dimension])),
       Enum.sort(recovery), hints != []}

    {fingerprint, if(hints != [], do: :timer.minutes(15))}
  end

  @doc "Off-path local/imported reconciliation shared by serving projection and retained explanation."
  @spec reconcile(t() | nil, t() | nil, atom()) :: map() | nil
  def reconcile(local, imported, resource) do
    state =
      case {local, imported} do
        {nil, nil} -> nil
        {nil, imported} -> imported
        {local, nil} -> local
        {local, imported} -> merge(local, imported)
      end

    with state when not is_nil(state) <- state,
         hint when not is_nil(hint) <- reconciled_hint(state, resource) do
      local_hint =
        if local && local.epoch == state.epoch,
          do: reconciled_hint(local, resource)

      source =
        if local_hint && local_hint.coordinate == hint.coordinate &&
             local_hint.value == hint.value &&
             Map.get(local_hint, :qualified?) == Map.get(hint, :qualified?),
           do: :local,
           else: :imported

      Map.merge(hint, %{source: source, epoch: state.epoch})
    else
      _ -> nil
    end
  end

  defp reconciled_hint(state, resource) do
    case decay(state, System.system_time(:millisecond)) do
      :expired -> nil
      current when resource == :retained -> retained(current)
      current -> List.first(hints(current, {:historical_depth, resource}))
    end
  end

  @doc "One precomputed cutoff comparison; a range must be wholly below a floor."
  @spec unavailable?(map(), non_neg_integer() | nil, Bracket.height()) :: boolean()
  def unavailable?(%{coordinate: :height, value: floor}, _age, {_lo, hi}), do: hi <= floor
  def unavailable?(%{coordinate: :height}, _age, _height), do: false

  def unavailable?(%{value: cutoff} = hint, age, _height) when is_integer(age) and age >= 0 do
    if Map.get(hint, :source) in [:declared, :observed_by_probe],
      do: age > cutoff,
      else: age >= cutoff
  end

  def unavailable?(_, _, _), do: false

  @impl true
  def encoded_size_upper_bound(state), do: :erlang.external_size({@version, state}, compressed: 6)
  @impl true
  def encode(%__MODULE__{} = state) do
    payload = :erlang.term_to_binary({@version, state}, compressed: 6)
    if byte_size(payload) <= @max_state_bytes, do: {:ok, payload}, else: {:error, :too_large}
  end

  @impl true
  def decode(payload) when is_binary(payload) and byte_size(payload) <= @max_state_bytes do
    case :erlang.binary_to_term(payload, [:safe]) do
      {version, %__MODULE__{} = state} when version in [2, @version] ->
        state = struct(__MODULE__, Map.from_struct(state))
        state = %{state | bracket: Bracket.normalize(state.bracket)}

        if valid_state?(state),
          do: {:ok, classify(state, System.system_time(:millisecond))},
          else: {:error, :invalid}

      {1, %__MODULE__{}} ->
        {:error, {:unsupported_version, 1}}

      _ ->
        {:error, :invalid}
    end
  rescue
    _ -> {:error, :invalid}
  end

  def decode(_), do: {:error, :invalid}

  defp classify(state, now_ms) do
    bracket = Bracket.decay(state.bracket, now_ms)
    rows = Enum.to_list(bracket.observations)
    successes = Enum.filter(rows, &(elem(&1, 1) == :success))
    failures = Enum.filter(rows, &(elem(&1, 1) == :failure))
    fresh = Enum.filter(failures, &(now_ms - elem(&1, 0) < @freshness_ms))

    age_failures =
      Enum.filter(fresh, fn {at, _, age, _, _} ->
        is_integer(age) and
          not Enum.any?(successes, fn {s_at, _, s_age, _, _} ->
            s_at >= at and is_integer(s_age) and s_age >= age
          end)
      end)

    height_failures =
      Enum.filter(fresh, fn {at, _, _, _, height} ->
        not is_nil(height) and
          not Enum.any?(successes, fn {s_at, _, _, _, s_height} ->
            s_at >= at and contains?(s_height, height)
          end)
      end)

    age_bound = supported(age_failures, &elem(&1, 2), :asc)
    height_bound = supported(height_failures, &(elem(&1, 4) |> elem(0)), :desc)

    age_monotone? =
      is_map(age_bound) and
        Enum.all?(successes, fn {_, _, age, _, _} ->
          is_integer(age) and Enum.all?(age_failures, &(age < elem(&1, 2)))
        end)

    height_monotone? =
      is_map(height_bound) and
        Enum.all?(successes, fn {_, _, _, _, height} ->
          not is_nil(height) and
            Enum.all?(height_failures, &(elem(elem(&1, 4), 1) < elem(height, 0)))
        end)

    {coordinate, bound} =
      cond do
        age_monotone? -> {:age, age_bound}
        height_monotone? -> {:height, height_bound}
        length(fresh) >= 2 -> {:non_monotone, nil}
        true -> {:unknown, nil}
      end

    {_, _, {resource, method}} = state.key

    hint =
      if is_map(bound),
        do: %{
          kind: :historical_depth,
          coordinate: coordinate,
          dimension: resource,
          method: method,
          value: bound.value,
          support: %{
            largest_success: maximum_age(successes),
            smallest_failure: bound.value,
            distinct_failure_requests: 2,
            failure_window_ms: bound.latest_at_ms - bound.earliest_at_ms
          },
          learner: __MODULE__,
          version: @version,
          observed_at_ms: bound.latest_at_ms,
          expires_at_ms: bound.earliest_at_ms + @freshness_ms
        }

    memory = retained_memory(state.key, coordinate, hint, failures, successes)

    %{state | bracket: bracket, classification: coordinate, hint: hint, memory: memory}
  end

  defp retained_memory({_, partition, {resource, method}}, coordinate, hint, failures, successes) do
    # Recovery retracts a failed interval only when the newer successful request
    # contains it. A point or overlapping range cannot clear another range.
    unresolved =
      Enum.reject(failures, fn {at, _, age, _, height} ->
        Enum.any?(successes, fn {s_at, _, s_age, _, s_height} ->
          s_at >= at and
            if(height,
              do: contains?(s_height, height),
              else: is_integer(s_age) and is_integer(age) and s_age >= age
            )
        end)
      end)

    if unresolved != [] do
      latest = unresolved |> Enum.map(&elem(&1, 0)) |> Enum.max()

      highest =
        unresolved
        |> Enum.flat_map(fn {_, _, _, _, h} -> if h, do: [elem(h, 1)], else: [] end)
        |> Enum.max(fn -> nil end)

      ages =
        Enum.flat_map(unresolved, fn {_, _, age, _, _} ->
          if is_integer(age), do: [age], else: []
        end)

      value = if coordinate == :height, do: hint.value, else: Enum.min(ages, fn -> nil end)

      relevant =
        Enum.filter(unresolved, fn {_, _, age, _, height} ->
          if coordinate == :height,
            do: not is_nil(height) and elem(height, 0) == value,
            else: age == value
        end)

      latest = relevant |> Enum.map(&elem(&1, 0)) |> Enum.max(fn -> latest end)

      %{
        kind: :historical_depth,
        coordinate: coordinate,
        dimension: resource,
        method: method,
        partition: partition,
        value: value,
        probe_height: if(coordinate == :height, do: value, else: highest),
        support: %{
          largest_success: maximum_age(successes),
          smallest_failure: Enum.min(ages, fn -> nil end)
        },
        qualified?: not is_nil(hint) and hint.value == value,
        observed_at_ms: latest,
        retained_until_ms: latest + @retention_ms
      }
    end
  end

  defp supported(rows, value, direction) do
    rows
    |> Enum.sort_by(value, direction)
    |> Enum.reduce_while(%{}, fn row, witnesses ->
      witnesses = Map.update(witnesses, elem(row, 3), elem(row, 0), &max(&1, elem(row, 0)))

      if map_size(witnesses) >= 2 do
        times = Map.values(witnesses)

        {:halt,
         %{value: value.(row), earliest_at_ms: Enum.min(times), latest_at_ms: Enum.max(times)}}
      else
        {:cont, witnesses}
      end
    end)
    |> case do
      %{value: _} = bound -> bound
      _ -> nil
    end
  end

  defp contains?({lo, hi}, {other_lo, other_hi}), do: lo <= other_lo and hi >= other_hi
  defp contains?(_, _), do: false

  defp maximum_age(rows),
    do:
      rows
      |> Enum.flat_map(fn {_, _, age, _, _} -> if is_integer(age), do: [age], else: [] end)
      |> Enum.max(fn -> nil end)

  defp valid_state?(
         %__MODULE__{
           key: {subject, partition, {resource, method}},
           bracket: %Bracket{ttl_ms: @retention_ms}
         } = state
       ) do
    is_binary(subject) and byte_size(subject) in 1..128 and
      partition in Lasso.RPC.RoutingEvidence.Workload.partitions() and
      resource in [:blocks, :balance, :state, :logs, :receipts, :proofs, :traces] and
      method in Lasso.RPC.MethodRegistry.all_methods() and
      is_integer(state.epoch) and state.epoch >= 0 and
      (is_nil(state.observed_at_ms) or
         (is_integer(state.observed_at_ms) and state.observed_at_ms >= 0)) and
      with {:ok, payload} <- Bracket.encode(state.bracket),
           {:ok, _} <- Bracket.decode(payload),
           do: true,
           else: (_ -> false)
  end

  defp valid_state?(_), do: false

  @doc "Qualified historical evidence shared by learning and shadow comparison."
  @spec observation_kind(Evidence.t() | nil) :: :success | :failure | :skip
  def observation_kind(%Evidence{
        outcome: :success,
        qualification: :accepted,
        result_verification: v
      })
      when v in [:known_answer, :non_empty],
      do: :success

  def observation_kind(%Evidence{outcome: :application_error, constraint_kind: :archival}),
    do: :failure

  def observation_kind(_), do: :skip

  defp observation_id(nonce),
    do: :crypto.hash(:sha256, nonce) |> Base.url_encode64(padding: false)

  defp max_optional(nil, value), do: value
  defp max_optional(value, nil), do: value
  defp max_optional(left, right), do: max(left, right)
end
