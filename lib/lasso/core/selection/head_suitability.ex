defmodule Lasso.RPC.Selection.HeadSuitability do
  @moduledoc """
  Whether fresh, attributed head evidence shows a route can serve a request's
  block requirement.

  A selection phase captures its evidence once from the scope's head snapshot,
  which carries every scope transport's latest observation and is refreshed when
  observations are written: the observations, the round lags for a moving head
  and the band. `assess/2` is pure over that capture:

  - `:against` needs a fresh observation at the qualified reference height
    with a different block hash, or:
  - for a moving head, only the chain's head round (`Lasso.BlockSync.Round`)
    judges a route. A round with at least two of the scope's head-observing
    upstreams measures each one's lag behind the round's mark, and both of an
    upstream's routes take the lag its upstream last measured. A lag counts
    while it was measured no longer ago than the route's own observation
    freshness window: above the band it is `:against`, otherwise `:supports`.
    Routes no round measured, such as routes whose profile turns background
    observations off, are `:unknown`. Passive observations never change a
    moving-head verdict;
  - for a fixed height, fresh evidence at or above it `:supports` the route and
    fresh evidence below it is `:against`. An observation's age earns no credit:
    a route counts only the blocks it was seen to have;
  - everything else is `:unknown`.

  A verdict orders routes inside their availability tier and never excludes one.
  A read at a fixed height tries supporting routes first, then routes freshly
  observed below the height, highest first, then routes with no fresh evidence,
  then routes on a conflicting branch.
  """

  alias Lasso.BlockSync.{Observation, Registry}
  alias Lasso.Observations.{HeadComparison, HeadSnapshot}
  alias Lasso.RPC.{ExecutionEnvelope, RequestAnalysis, RoutingPlan}

  # Methods whose omitted block parameter clients resolve to the moving head.
  # Required-selector omissions keep no requirement. Client sources:
  # docs/ROUTING.md#head-freshness
  @optional_head_methods ~w(
    eth_estimateGas eth_call eth_getBalance eth_getCode eth_getTransactionCount
    eth_getProof eth_getStorageValues eth_getStorageAt eth_createAccessList eth_simulateV1
    debug_traceCall trace_call trace_callMany
  )

  @enforce_keys [:requirement, :band, :captured_at_ms, :evidence]
  defstruct @enforce_keys

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
          | :unmeasured
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
          branch_conflict?: boolean(),
          round_lag: Registry.head_lag() | nil
        }

  @type t :: %__MODULE__{
          requirement: requirement(),
          band: non_neg_integer(),
          captured_at_ms: integer(),
          evidence: %{route() => evidence()}
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
  returns `nil` when the request has no requirement.
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
    band = HeadComparison.agreement_blocks(plan.head_scope.policy)

    lags = if requirement == :at_head, do: Registry.get_head_lags(plan.head_scope), else: %{}

    evidence =
      Map.new(route_heads(plan, lags, now_ms), fn {route, head} ->
        {route, Map.put(head, :branch_conflict?, branch_conflict?(head, reference_hash))}
      end)

    %__MODULE__{
      requirement: requirement,
      band: band,
      captured_at_ms: now_ms,
      evidence: evidence
    }
  end

  # Freshness is the observation layer's verdict, which honours an
  # observation's own longer window such as a slow HTTP poll interval. A
  # route's round lag expires on the same window.
  defp route_heads(plan, lags, now_ms) do
    for provider <- plan.providers,
        transport <- provider.transports,
        {fresh?, observation} <- [read_head(plan.chain_id, provider, transport, now_ms)],
        into: %{} do
      {{provider.instance_id, transport},
       %{
         height: observation.height,
         observed_at_ms: observation.observed_at_ms,
         block_hash: normalize_hash(observation.metadata[:hash]),
         fresh?: fresh?,
         round_lag: round_lag(lags[provider.instance_id], observation, now_ms)
       }}
    end
  end

  defp round_lag(%{measured_at_ms: measured_at_ms} = lag, observation, now_ms)
       when now_ms - measured_at_ms <= observation.stale_after_ms,
       do: lag

  defp round_lag(_unmeasured, _observation, _now_ms), do: nil

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

  defp judge(%__MODULE__{requirement: :at_head, band: band}, observation) do
    case observation.round_lag do
      nil -> {:unknown, :unmeasured}
      %{lag: lag} when lag > band -> {:against, :behind_mark}
      _within_band -> {:supports, :within_band}
    end
  end

  defp judge(%__MODULE__{requirement: {_source, target}}, %{height: height})
       when height >= target,
       do: {:supports, :at_or_above_height}

  defp judge(_capture, _observation), do: {:against, :below_height}

  @doc "The height a fixed requirement needs. A moving head has none: rounds judge it by lag."
  @spec target_height(t()) :: non_neg_integer() | nil
  def target_height(%__MODULE__{requirement: {_source, height}}), do: height
  def target_height(%__MODULE__{requirement: :at_head}), do: nil

  @doc """
  The route's ordering class with its verdict and reason. For a moving head,
  only evidence against a route defers it: supporting and unknown routes keep
  strategy order, since an unobserved route is not known to lag. For a fixed
  request height, routes below it and routes without fresh evidence follow the
  supporting ones in class 1, which `rank/3` orders, and only a branch conflict
  is deferred. A recovery height keeps its two-class preference and defers
  nothing.
  """
  @spec classify(t() | nil, route()) :: {class(), verdict() | nil, reason() | nil}
  def classify(nil, _route), do: {0, nil, nil}

  def classify(%__MODULE__{} = capture, route) do
    {verdict, reason} = assess(capture, route)
    {verdict_class(capture.requirement, verdict, reason), verdict, reason}
  end

  @spec class(t() | nil, route()) :: class()
  def class(capture, route), do: capture |> classify(route) |> elem(0)

  @doc """
  The route's place inside its availability tier: its class, then, among the
  class 1 routes of a fixed request height, routes observed below it by height,
  highest first, then routes with no fresh evidence. Every other route keeps
  strategy order within its class.
  """
  @spec rank(t() | nil, route()) :: {class(), integer()}
  def rank(capture, route), do: rank(capture, route, classify(capture, route))

  @doc "The route's rank from the classification `classify/2` gave it."
  @spec rank(t() | nil, route(), {class(), verdict() | nil, reason() | nil}) ::
          {class(), integer()}
  def rank(%__MODULE__{requirement: {:request_height, _height}} = capture, route, {1, _, reason}),
    do: {1, short_position(capture, route, reason)}

  def rank(_capture, _route, {class, _verdict, _reason}), do: {class, 0}

  defp short_position(capture, route, :below_height), do: -capture.evidence[route].height
  defp short_position(_capture, _route, _unknown), do: 1

  defp verdict_class(_requirement, :supports, _reason), do: 0
  defp verdict_class({:recovery_height, _height}, _verdict, _reason), do: 1
  defp verdict_class({:request_height, _height}, _verdict, :branch_conflict), do: 2
  defp verdict_class({:request_height, _height}, _verdict, _reason), do: 1
  defp verdict_class(:at_head, :against, _reason), do: 2
  defp verdict_class(:at_head, :unknown, _reason), do: 0

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
end
