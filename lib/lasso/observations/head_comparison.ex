defmodule Lasso.Observations.HeadComparison do
  @moduledoc """
  Derives qualified reference heads and transport-specific lag assessments.

  Reference derivation is pure and grants one vote to each upstream instance.
  The freshest observation represents an instance, with WebSocket evidence as
  the deterministic tie-breaker. Observation times are aligned only to decide
  whether votes agree. Every published height remains a concrete upstream fact;
  elapsed time never creates a synthetic head. Captured request references are
  used only when assessing the resulting HTTP or unary WebSocket observation.
  """

  alias Lasso.Observations.{HeadObservation, HeadScope, HeadSnapshot}

  defmodule Policy do
    @moduledoc "Comparison policy for one chain."

    @enforce_keys [:block_time_ms, :reference_freshness_ms, :agreement_window_ms]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            block_time_ms: pos_integer(),
            reference_freshness_ms: pos_integer(),
            agreement_window_ms: pos_integer()
          }
  end

  defmodule AssessmentPolicy do
    @moduledoc "Profile-scoped policy for assessing one route."

    @enforce_keys [:freshness_ms, :max_lag_blocks]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            freshness_ms: pos_integer(),
            max_lag_blocks: non_neg_integer()
          }
  end

  defmodule Assessment do
    @moduledoc "The head-evidence result for one concrete upstream transport."

    @enforce_keys [:status, :reason, :lag, :raw_lag, :compared_height, :age_ms]
    defstruct @enforce_keys ++ [:reference]

    @type status :: :eligible | :lagging | :unknown
    @type reason ::
            :within_lag_limit
            | :exceeds_lag_limit
            | :reference_unqualified
            | :observation_stale
            | :observation_missing
            | :poll_reference_missing
            | :poll_reference_scope_mismatch
            | :reference_stale
            | :chain_mismatch

    @type t :: %__MODULE__{
            status: status(),
            reason: reason(),
            lag: integer() | nil,
            raw_lag: integer() | nil,
            compared_height: non_neg_integer() | nil,
            age_ms: non_neg_integer(),
            reference: Lasso.Observations.HeadReference.t() | nil
          }
  end

  @type vote :: %{
          instance_id: String.t(),
          height: non_neg_integer(),
          aligned_height: non_neg_integer(),
          observed_at_ms: integer(),
          transport: HeadObservation.transport(),
          valid_through_ms: integer()
        }

  @doc "Derives a reference only from the physical upstreams in one profile's scope."
  @spec derive(HeadScope.t(), [HeadObservation.t()], integer(), non_neg_integer()) ::
          HeadSnapshot.t()
  def derive(%HeadScope{} = scope, observations, now_ms, revision)
      when is_list(observations) and is_integer(now_ms) and is_integer(revision) and
             revision >= 0 do
    allowed_instances = MapSet.new(scope.instance_ids)

    scoped_observations =
      Enum.filter(observations, fn
        %HeadObservation{instance_id: instance_id} ->
          MapSet.member?(allowed_instances, instance_id)

        _other ->
          false
      end)

    derive(scope.chain_id, scoped_observations, scope.policy, now_ms, revision, scope.scope_id)
  end

  @spec derive(
          pos_integer(),
          [HeadObservation.t()],
          Policy.t(),
          integer(),
          non_neg_integer(),
          tuple() | nil
        ) ::
          HeadSnapshot.t()
  def derive(chain_id, observations, %Policy{} = policy, now_ms, revision \\ 0, scope_id \\ nil)
      when is_integer(chain_id) and chain_id > 0 and is_list(observations) and
             is_integer(now_ms) and is_integer(revision) and revision >= 0 do
    observations = Enum.filter(observations, &match?(%HeadObservation{chain_id: ^chain_id}, &1))

    selected_observations =
      observations
      |> Enum.filter(&(age_ms(&1, now_ms) <= policy.reference_freshness_ms))
      |> Enum.group_by(& &1.instance_id)
      |> Enum.map(fn {_instance_id, instance_observations} ->
        preferred_instance_observation(instance_observations, policy)
      end)
      |> Enum.group_by(fn observation ->
        Map.get(
          observation.attributes,
          :head_voter_identity,
          observation.instance_id
        )
      end)
      |> Enum.map(fn {_capacity, capacity_observations} ->
        preferred_instance_observation(capacity_observations, policy)
      end)

    comparison_at_ms =
      selected_observations
      |> Enum.map(& &1.observed_at_ms)
      |> Enum.max(fn -> now_ms end)

    votes =
      selected_observations
      |> Enum.map(fn observation ->
        %{
          instance_id: observation.instance_id,
          height: observation.height,
          aligned_height: alignment_height(observation, policy, comparison_at_ms),
          observed_at_ms: observation.observed_at_ms,
          transport: observation.transport,
          valid_through_ms: observation.observed_at_ms + policy.reference_freshness_ms
        }
      end)
      |> Enum.sort_by(&{&1.aligned_height, &1.instance_id})

    tolerance_blocks = agreement_blocks(policy)
    support = largest_cluster(votes, tolerance_blocks)
    qualified? = length(support) >= 2 and length(support) > div(length(votes), 2)
    reference_vote = select_reference_vote(if(support == [], do: votes, else: support))
    latest_vote = select_latest_vote(votes)
    supporting_instances = Enum.map(support, & &1.instance_id)
    all_instances = MapSet.new(votes, & &1.instance_id)

    %HeadSnapshot{
      chain_id: chain_id,
      scope_id: scope_id,
      reference_height: field(reference_vote, :height),
      reference_observed_at_ms: field(reference_vote, :observed_at_ms),
      reference_instance_id: field(reference_vote, :instance_id),
      reference_transport: field(reference_vote, :transport),
      latest_observed_height: field(latest_vote, :height),
      latest_observed_at_ms: field(latest_vote, :observed_at_ms),
      latest_observed_instance_id: field(latest_vote, :instance_id),
      latest_observed_transport: field(latest_vote, :transport),
      qualification: qualification(votes, qualified?),
      support: length(support),
      voter_count: length(votes),
      spread: spread(votes),
      computed_at_ms: now_ms,
      valid_through_ms:
        valid_through_ms(
          if(qualified?, do: support, else: votes),
          now_ms,
          policy.reference_freshness_ms
        ),
      revision: revision,
      supporting_instances: supporting_instances,
      dissenting_instances:
        all_instances
        |> MapSet.difference(MapSet.new(supporting_instances))
        |> Enum.sort()
    }
  end

  @spec assess(HeadSnapshot.t(), HeadObservation.t(), AssessmentPolicy.t(), integer()) ::
          Assessment.t()
  def assess(
        %HeadSnapshot{} = snapshot,
        %HeadObservation{} = observation,
        %AssessmentPolicy{} = assessment_policy,
        now_ms
      )
      when is_integer(now_ms) do
    age_ms = age_ms(observation, now_ms)

    cond do
      snapshot.chain_id != observation.chain_id ->
        unknown(:chain_mismatch, age_ms)

      snapshot.qualification != :qualified ->
        unknown(:reference_unqualified, age_ms)

      now_ms > snapshot.valid_through_ms ->
        unknown(:reference_stale, age_ms)

      age_ms > assessment_policy.freshness_ms ->
        unknown(:observation_stale, age_ms)

      HeadObservation.request_observation?(observation) and observation.poll_references == [] ->
        unknown(:poll_reference_missing, age_ms)

      HeadObservation.request_observation?(observation) and
          is_nil(HeadObservation.poll_reference_for(observation, snapshot.scope_id)) ->
        unknown(:poll_reference_scope_mismatch, age_ms)

      true ->
        compared_height = height_for_assessment(observation)
        raw_lag = observation.height - snapshot.reference_height
        reference = assessment_reference(observation, snapshot)
        lag = assessed_lag(observation, reference, compared_height)

        if lag < -assessment_policy.max_lag_blocks do
          %Assessment{
            status: :lagging,
            reason: :exceeds_lag_limit,
            lag: lag,
            raw_lag: raw_lag,
            compared_height: compared_height,
            age_ms: age_ms,
            reference: reference
          }
        else
          %Assessment{
            status: :eligible,
            reason: :within_lag_limit,
            lag: lag,
            raw_lag: raw_lag,
            compared_height: compared_height,
            age_ms: age_ms,
            reference: reference
          }
        end
    end
  end

  @spec agreement_blocks(Policy.t()) :: pos_integer()
  def agreement_blocks(%Policy{} = policy) do
    policy.agreement_window_ms
    |> ceil_div(policy.block_time_ms)
    |> max(1)
    |> min(20)
  end

  @doc "Returns the window in which recent WebSocket evidence represents an instance."
  @spec preference_window_ms(Policy.t()) :: pos_integer()
  def preference_window_ms(%Policy{} = policy) do
    min(
      policy.reference_freshness_ms,
      max(policy.agreement_window_ms, policy.block_time_ms * 2)
    )
  end

  @doc "Selects the fact that currently represents one upstream instance."
  @spec preferred_instance_observation([HeadObservation.t()], Policy.t()) ::
          HeadObservation.t() | nil
  def preferred_instance_observation([], %Policy{}), do: nil

  def preferred_instance_observation(observations, %Policy{} = policy)
      when is_list(observations) do
    latest = Enum.max_by(observations, &observation_order/1)

    latest_ws =
      observations
      |> Enum.filter(&match?(%HeadObservation{transport: :ws}, &1))
      |> Enum.max_by(&observation_order/1, fn -> nil end)

    preference_window_ms = preference_window_ms(policy)

    case latest_ws do
      %HeadObservation{} = ws
      when latest.observed_at_ms - ws.observed_at_ms <= preference_window_ms ->
        ws

      _missing_or_old_ws ->
        latest
    end
  end

  defp assessed_lag(observation, reference, compared_height) do
    if HeadObservation.request_observation?(observation),
      do: min(0, observation.height - reference.height),
      else: compared_height - reference.height
  end

  defp assessment_reference(observation, snapshot) do
    if HeadObservation.request_observation?(observation) do
      HeadObservation.poll_reference_for(observation, snapshot.scope_id)
    else
      {:ok, reference} = HeadSnapshot.reference(snapshot)
      reference
    end
  end

  defp alignment_height(%HeadObservation{} = observation, policy, comparison_at_ms) do
    elapsed_ms = max(0, comparison_at_ms - observation.observed_at_ms)
    observation.height + div(elapsed_ms, policy.block_time_ms)
  end

  defp height_for_assessment(%HeadObservation{} = observation), do: observation.height

  defp largest_cluster([], _tolerance_blocks), do: []

  defp largest_cluster(votes, tolerance_blocks) do
    votes
    |> Enum.map(fn center ->
      Enum.filter(votes, fn vote ->
        abs(vote.aligned_height - center.aligned_height) <= tolerance_blocks
      end)
    end)
    |> Enum.max_by(&{length(&1), -spread(&1)}, fn -> [] end)
  end

  defp observation_order(%HeadObservation{} = observation) do
    {observation.observed_at_ms, transport_rank(observation.transport)}
  end

  defp transport_rank(:ws), do: 1
  defp transport_rank(:http), do: 0

  defp qualification([], _qualified?), do: :unavailable
  defp qualification([_vote], _qualified?), do: :uncorroborated
  defp qualification(_votes, true), do: :qualified
  defp qualification(_votes, false), do: :ambiguous

  defp spread([]), do: nil
  defp spread(votes), do: List.last(votes).aligned_height - hd(votes).aligned_height

  defp valid_through_ms([], now_ms, reference_freshness_ms),
    do: now_ms + reference_freshness_ms

  defp valid_through_ms(votes, _now_ms, _reference_freshness_ms),
    do: votes |> Enum.map(& &1.valid_through_ms) |> Enum.min()

  defp age_ms(observation, now_ms), do: max(0, now_ms - observation.observed_at_ms)

  defp select_reference_vote([]), do: nil

  defp select_reference_vote(votes) do
    concrete_center =
      votes
      |> Enum.map(& &1.height)
      |> Enum.sort()
      |> Enum.at(div(length(votes), 2))

    Enum.min_by(votes, fn vote ->
      {
        abs(vote.height - concrete_center),
        -vote.observed_at_ms,
        -transport_rank(vote.transport),
        -vote.height
      }
    end)
  end

  defp select_latest_vote([]), do: nil

  defp select_latest_vote(votes) do
    Enum.max_by(votes, &{&1.observed_at_ms, transport_rank(&1.transport), &1.height})
  end

  defp field(nil, _key), do: nil
  defp field(value, key), do: Map.fetch!(value, key)

  defp unknown(reason, age_ms) do
    %Assessment{
      status: :unknown,
      reason: reason,
      lag: nil,
      raw_lag: nil,
      compared_height: nil,
      age_ms: age_ms
    }
  end

  defp ceil_div(dividend, divisor), do: div(dividend + divisor - 1, divisor)
end
