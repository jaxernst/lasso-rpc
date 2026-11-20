defmodule Lasso.RPC.Selection.HeadSuitability do
  @moduledoc """
  Whether fresh, attributed head evidence shows a route can serve a request's
  block requirement.

  A selection phase captures its evidence once from the scope's head snapshot,
  which carries every scope transport's latest observation and is refreshed when
  observations are written: the observations, the scope mark, the band and the
  chain's cadence. The mark is the highest fresh observation in the scope, from
  any instance or transport. When the snapshot has a qualified reference, a
  fresh observation more than the band above it, after crediting the blocks the
  chain could have produced between the two observations, is an outlier and
  cannot be the mark. `assess/2` is pure over that capture:

  - `:against` needs a fresh observation at the qualified reference height
    with a different block hash, or:
  - `:supports` needs fresh evidence at or above the target height;
  - `:against` needs fresh evidence that stays short of the target even when
    credited with the blocks the chain could have produced since it was
    observed, at the fastest cadence the chain has shown, or at twice the
    configured rate until cadence is measured; without either, an exact request
    height uses the observed height while moving-head and recovery requirements
    remain unknown;
  - everything else is `:unknown`.

  The target is the requirement's height, or the mark minus the band for a
  moving head. A verdict orders routes inside their availability tier and never
  excludes one.
  """

  alias Lasso.BlockSync.Observation
  alias Lasso.Observations.{HeadCadence, HeadComparison, HeadSnapshot}
  alias Lasso.RPC.{ExecutionEnvelope, RequestAnalysis, RoutingPlan}

  # Methods whose omitted block parameter clients resolve to the moving head.
  # Required-selector omissions keep no requirement. Client sources:
  # docs/ROUTING.md#head-freshness
  @optional_head_methods ~w(
    eth_estimateGas eth_call eth_getBalance eth_getCode eth_getTransactionCount
    eth_getProof eth_getStorageValues eth_getStorageAt eth_createAccessList eth_simulateV1
    debug_traceCall trace_call trace_callMany
  )

  @enforce_keys [:requirement, :band, :cadence, :captured_at_ms, :evidence]
  defstruct @enforce_keys ++ [:mark, outliers: []]

  @typedoc """
  A request height comes from the request's own block facts; a recovery height
  comes from block continuity. They are never merged into one height.
  """
  @type requirement ::
          {:request_height, non_neg_integer()}
          | {:recovery_height, non_neg_integer()}
          | :at_head

  @type verdict :: :supports | :unknown | :against
  @type reason ::
          :at_or_above_height
          | :within_band
          | :below_height
          | :branch_conflict
          | :behind_mark
          | :within_credit
          | :cadence_unknown
          | :observation_stale
          | :no_observation

  @type route :: {String.t(), :http | :ws}

  @typedoc "Ordering class within an availability tier: 0 precedes 1, and 2 is deferred."
  @type class :: 0 | 1 | 2

  @type evidence :: %{
          height: non_neg_integer(),
          observed_at_ms: integer(),
          block_hash: String.t() | nil,
          fresh?: boolean(),
          branch_conflict?: boolean()
        }
  @type mark :: %{
          height: non_neg_integer(),
          route: route(),
          observed_at_ms: integer()
        }

  @type t :: %__MODULE__{
          requirement: requirement(),
          band: non_neg_integer(),
          cadence: HeadCadence.t(),
          captured_at_ms: integer(),
          evidence: %{route() => evidence()},
          mark: mark() | nil,
          outliers: [mark()]
        }

  @doc """
  The selection phase's requirement. A recovery height, when present, is the
  phase's only requirement. A range uses its upper bound, and an omitted upper
  bound means `latest`; a single selector uses its block. An omitted optional
  block parameter means `latest`; an omitted required one carries none. Hash
  selectors, `earliest`, `safe`, `finalized`, `pending` and unusable selectors
  carry none. A replay-safe read with no block parameter, such as a lookup by
  transaction hash, needs the moving head; writes and subscriptions carry none.
  """
  @spec requirement(String.t(), RequestAnalysis.block_facts(), non_neg_integer() | nil) ::
          requirement() | nil
  def requirement(_method, _facts, recovery_height) when is_integer(recovery_height),
    do: {:recovery_height, recovery_height}

  def requirement(_method, %{range: {_from, :omitted}}, nil), do: :at_head
  def requirement(_method, %{range: {_from, to}}, nil), do: selector_requirement(to)

  def requirement(method, %{block: :omitted}, nil) when method in @optional_head_methods,
    do: :at_head

  def requirement(_method, %{block: block}, nil), do: selector_requirement(block)

  def requirement(method, nil, nil) do
    if ExecutionEnvelope.classify(method) == :replay_safe, do: :at_head
  end

  defp selector_requirement({:number, height}), do: {:request_height, height}
  defp selector_requirement({:tag, :latest, nil}), do: :at_head
  defp selector_requirement(_selector), do: nil

  @doc """
  Captures one selection phase's evidence from the scope's head snapshot, or
  returns `nil` when the request has no requirement. Cadence is a precomputed
  scalar carried by the same snapshot; selection reads no cadence sample table.
  """
  @spec capture(
          RoutingPlan.t(),
          String.t(),
          RequestAnalysis.block_facts(),
          non_neg_integer() | nil,
          HeadSnapshot.t() | :unavailable,
          integer()
        ) :: t() | nil
  def capture(
        %RoutingPlan{} = plan,
        method,
        block_facts,
        recovery_height,
        head_snapshot,
        now_ms \\ System.system_time(:millisecond)
      ) do
    case requirement(method, block_facts, recovery_height) do
      nil -> nil
      requirement -> build(plan, requirement, head_snapshot, now_ms)
    end
  end

  defp build(plan, requirement, head_snapshot, now_ms) do
    reference_hash = qualified_reference_hash(head_snapshot, now_ms)

    evidence =
      Map.new(route_heads(plan, now_ms), fn {route, head} ->
        {route, Map.put(head, :branch_conflict?, branch_conflict?(head, reference_hash))}
      end)

    capture = %__MODULE__{
      requirement: requirement,
      band: HeadComparison.agreement_blocks(plan.head_scope.policy),
      cadence:
        HeadCadence.with_seed(
          nil,
          Map.get(plan, :block_time_seed_ms, plan.head_scope.policy.block_time_ms),
          now_ms
        ),
      captured_at_ms: now_ms,
      evidence: evidence
    }

    if requirement == :at_head do
      reference = qualified_reference(head_snapshot, now_ms)

      {outliers, candidates} =
        split_outliers(evidence, reference, capture, plan.head_scope.policy.block_time_ms)

      %{
        capture
        | mark: candidates |> Enum.max_by(&{&1.height, &1.observed_at_ms}, fn -> nil end),
          outliers: Enum.sort_by(outliers, & &1.height, :desc)
      }
    else
      capture
    end
  end

  # Freshness is the observation layer's verdict, which honours an
  # observation's own longer window such as a slow HTTP poll interval.
  defp route_heads(plan, now_ms) do
    for provider <- plan.providers,
        transport <- provider.transports,
        {fresh?, observation} <- [read_head(plan.chain_id, provider, transport, now_ms)],
        into: %{},
        do:
          {{provider.instance_id, transport},
           %{
             height: observation.height,
             observed_at_ms: observation.observed_at_ms,
             block_hash: normalize_hash(observation.metadata[:hash]),
             fresh?: fresh?
           }}
  end

  defp read_head(chain_id, provider, transport, now_ms) do
    case Observation.read_transport(
           chain_id,
           provider.instance_id,
           transport,
           now_ms,
           Map.fetch!(provider.head_freshness_ms, transport)
         ) do
      {:ok, observation} -> {true, observation}
      {:error, {:stale, observation}} -> {false, observation}
      {:error, :not_found} -> nil
    end
  end

  defp normalize_hash(hash) when is_binary(hash) and hash != "", do: String.downcase(hash)
  defp normalize_hash(_unknown), do: nil

  # The qualified reference's height and hash; a fresh route at that height on
  # another hash is on a branch the scope's majority does not report.
  defp qualified_reference_hash(
         %HeadSnapshot{qualification: :qualified, reference_block_hash: hash} = snapshot,
         now_ms
       )
       when is_binary(hash) and now_ms <= snapshot.valid_through_ms,
       do: {snapshot.reference_height, hash}

  defp qualified_reference_hash(_snapshot, _now_ms), do: nil

  defp branch_conflict?(%{height: height, block_hash: hash}, {height, reference_hash})
       when is_binary(hash),
       do: hash != reference_hash

  defp branch_conflict?(_head, _reference), do: false

  defp qualified_reference(%HeadSnapshot{} = snapshot, now_ms) do
    with true <- now_ms <= snapshot.valid_through_ms,
         {:ok, reference} <- HeadSnapshot.reference(snapshot) do
      %{
        height: reference.height,
        observed_at_ms: reference.observed_at_ms || snapshot.computed_at_ms
      }
    else
      _unqualified -> nil
    end
  end

  defp qualified_reference(_unavailable, _now_ms), do: nil

  # Without a qualified reference the raw maximum stands, so two disagreeing
  # providers can still be judged. Unlike `against`, the outlier test may fall
  # back to the comparison policy's block time: it only protects the mark.
  defp split_outliers(evidence, reference, capture, fallback_block_time_ms) do
    fresh =
      for {route, %{fresh?: true} = observation} <- evidence,
          do: %{
            route: route,
            height: observation.height,
            observed_at_ms: observation.observed_at_ms
          }

    case reference do
      nil ->
        {[], fresh}

      reference ->
        Enum.split_with(fresh, fn observation ->
          elapsed_ms = max(observation.observed_at_ms - reference.observed_at_ms, 0)

          credit =
            credit(capture, elapsed_ms) ||
              HeadCadence.credit_blocks(
                HeadCadence.resolve(nil, fallback_block_time_ms),
                elapsed_ms
              )

          observation.height > reference.height + capture.band + credit
        end)
    end
  end

  @doc "The verdict and its reason for one route under the captured evidence."
  @spec assess(t(), route()) :: {verdict(), reason()}
  def assess(%__MODULE__{} = capture, route) do
    case Map.fetch(capture.evidence, route) do
      {:ok, %{fresh?: true, branch_conflict?: true}} -> {:against, :branch_conflict}
      {:ok, %{fresh?: true} = observation} -> judge(capture, observation)
      {:ok, _stale} -> {:unknown, :observation_stale}
      :error -> {:unknown, :no_observation}
    end
  end

  # A fresh observation exists, so a moving requirement always has a mark.
  defp judge(capture, observation) do
    target = target_height(capture)

    cond do
      observation.height >= target ->
        {:supports, supports_reason(capture.requirement)}

      is_nil(capture.cadence.credit_block_time_ms) ->
        without_cadence(capture.requirement)

      observation.height +
        credit(capture, max(capture.captured_at_ms - observation.observed_at_ms, 0)) < target ->
        {:against, against_reason(capture.requirement)}

      true ->
        {:unknown, :within_credit}
    end
  end

  defp without_cadence({:request_height, _height}), do: {:against, :below_height}
  defp without_cadence(_requirement), do: {:unknown, :cadence_unknown}

  defp supports_reason(:at_head), do: :within_band
  defp supports_reason(_height), do: :at_or_above_height

  defp against_reason(:at_head), do: :behind_mark
  defp against_reason(_height), do: :below_height

  @doc "The height a route must have reached: the requirement's, or the mark minus the band."
  @spec target_height(t()) :: non_neg_integer() | nil
  def target_height(%__MODULE__{requirement: {_source, height}}), do: height
  def target_height(%__MODULE__{requirement: :at_head, mark: nil}), do: nil

  def target_height(%__MODULE__{requirement: :at_head, mark: mark, band: band}),
    do: max(mark.height - band, 0)

  defp credit(%__MODULE__{cadence: cadence}, elapsed_ms),
    do: HeadCadence.credit_blocks(cadence, elapsed_ms)

  @doc """
  The route's ordering class with its verdict and reason. Only evidence against
  a route defers it. Supporting and unknown routes keep strategy order for every
  read until head observations cover routes often enough to compare them: an
  unobserved route is not known to lag. A recovery height keeps its two-class
  preference and defers nothing.
  """
  @spec classify(t() | nil, route()) :: {class(), verdict() | nil, reason() | nil}
  def classify(nil, _route), do: {0, nil, nil}

  def classify(%__MODULE__{} = capture, route) do
    {verdict, reason} = assess(capture, route)
    {verdict_class(capture.requirement, verdict), verdict, reason}
  end

  @spec class(t() | nil, route()) :: class()
  def class(capture, route), do: capture |> classify(route) |> elem(0)

  defp verdict_class(_requirement, :supports), do: 0
  defp verdict_class({:recovery_height, _height}, _verdict), do: 1
  defp verdict_class(_requirement, :against), do: 2
  defp verdict_class(_requirement, :unknown), do: 0

  @doc """
  Whether the route's current observation shows it reached the target, for
  explanation only. For an exact height this counts an observation of any age:
  a fixed block does not disappear from a provider that reported a height past
  it. It reads the latest observation retained for this upstream identity and
  transport, so a newer lower observation or a new credential ends it. It never
  orders routes, admits historical depth, qualifies learning, establishes
  canonicality, or grants a recovery or extra send.
  """
  @spec reached?(t(), route()) :: boolean()
  def reached?(%__MODULE__{requirement: {:request_height, height}} = capture, route) do
    match?({:ok, %{height: observed}} when observed >= height, Map.fetch(capture.evidence, route))
  end

  def reached?(%__MODULE__{} = capture, route), do: match?({:supports, _}, assess(capture, route))

  @doc """
  Whether a route is in the best class among the candidate routes, which a
  cached winner must be before it may be returned ahead of ranking. Routes are
  enumerated only when the route itself is not in the first class, so callers
  may pass a lazy stream.
  """
  @spec leads?(t() | nil, route(), Enumerable.t()) :: boolean()
  def leads?(nil, _route, _routes), do: true

  def leads?(%__MODULE__{} = capture, route, routes) do
    case class(capture, route) do
      0 -> true
      class -> Enum.all?(routes, &(class(capture, &1) >= class))
    end
  end
end
