defmodule Lasso.RPC.RequestFacts do
  @moduledoc """
  Block facts and the head reference captured when a selection phase starts.

  Facts describe the request the phase selected for, independently of
  archival permission; `method` is that selection method. The reference is the
  qualified snapshot the phase's selection used, bound to the phase's profile,
  chain and head scope and kept with its expiry and spread.
  `captured_at_ms` is when this request captured it, distinct from when the
  snapshot was computed. Every dispatch of the phase, including a delayed
  retry, evaluates that same reference instead of reading a newer head.
  Nothing here admits evidence into learners or changes routing.
  """

  alias Lasso.Observations.{HeadReference, HeadSnapshot}
  alias Lasso.RPC.{RequestAnalysis, RoutingPlan}

  @enforce_keys [
    :profile,
    :chain_id,
    :scope_id,
    :method,
    :block_facts,
    :reference,
    :captured_at_ms
  ]
  defstruct @enforce_keys

  @type unavailable ::
          :no_snapshot
          | :no_height
          | :uncorroborated
          | :ambiguous
          | :unavailable
          | :scope_mismatch
          | :future_dated
          | :expired
          | :invalid_reference

  @typedoc """
  `:qualified` is the only usable disposition. Spread is the snapshot's
  observed height spread and `observed_at_ms` the reference observation's time,
  each `:unknown` when the snapshot lacks it. They are provenance, not a
  tolerance: unknown provenance never stands for zero uncertainty.
  """
  @type head_reference ::
          {:qualified, HeadReference.t(),
           %{
             valid_through_ms: integer(),
             spread: non_neg_integer() | :unknown,
             observed_at_ms: integer() | :unknown
           }}
          | {:unavailable, unavailable()}

  @type t :: %__MODULE__{
          profile: String.t(),
          chain_id: pos_integer(),
          scope_id: tuple(),
          method: String.t(),
          block_facts: RequestAnalysis.block_facts(),
          reference: head_reference(),
          captured_at_ms: integer()
        }

  @type abstention ::
          unavailable()
          | :other_request
          | :before_capture
          | :other_reference
          | :negative_age
          | :unknown_height
          | :moving_tag
          | :range
          | :omitted
          | :unusable
          | :no_selector

  @spec capture(
          RoutingPlan.t(),
          String.t(),
          RequestAnalysis.block_facts(),
          HeadSnapshot.t() | :unavailable,
          integer()
        ) :: t()
  def capture(
        %RoutingPlan{} = plan,
        method,
        block_facts,
        head_snapshot,
        now_ms \\ System.system_time(:millisecond)
      ) do
    %__MODULE__{
      profile: plan.profile,
      chain_id: plan.chain_id,
      scope_id: plan.head_scope.scope_id,
      method: method,
      block_facts: block_facts,
      reference: reference(head_snapshot, plan, now_ms),
      captured_at_ms: now_ms
    }
  end

  @doc """
  The age of the request's fixed block at one dispatch, or the reason to
  abstain.

  The reference must satisfy observation <= snapshot computation <= request
  capture <= dispatch, and the dispatch must not be after its expiry. The
  caller's expected profile and chain must match; that rejects facts from
  another profile or chain but does not establish request identity. The
  request context and the consumer remain responsible for pairing these facts
  with the same method, selector and selection phase. An unknown height, a
  moving tag, a range and a negative age also abstain.
  """
  @spec historical_age(t(), %{profile: String.t(), chain_id: pos_integer()}, integer()) ::
          {:ok, non_neg_integer(), HeadReference.t()} | {:abstain, abstention()}
  def historical_age(
        %__MODULE__{profile: profile, chain_id: chain_id} = facts,
        %{profile: profile, chain_id: chain_id},
        dispatched_at_ms
      )
      when is_integer(dispatched_at_ms) do
    with {:ok, height} <- fixed_height(facts.block_facts),
         {:ok, head} <- dispatch_reference(facts, dispatched_at_ms) do
      age = head.height - height
      if age >= 0, do: {:ok, age, head}, else: {:abstain, :negative_age}
    end
  end

  def historical_age(%__MODULE__{}, _expected, _dispatched_at_ms), do: {:abstain, :other_request}

  @doc "Numeric requested point or full logs interval, without inferring an unavailable height from a head."
  @spec numeric_interval(RequestAnalysis.block_facts() | nil) ::
          {non_neg_integer(), non_neg_integer()} | nil
  def numeric_interval(%{range: {from, to}}) do
    with {:ok, lo} <- fixed_height(%{block: from}),
         {:ok, hi} <- fixed_height(%{block: to}),
         true <- is_integer(lo) and lo >= 0 and is_integer(hi) and hi >= lo do
      {lo, hi}
    else
      _ -> nil
    end
  end

  def numeric_interval(facts) do
    case fixed_height(facts) do
      {:ok, height} when is_integer(height) and height >= 0 -> {height, height}
      _ -> nil
    end
  end

  defp dispatch_reference(%__MODULE__{reference: {:unavailable, reason}}, _at_ms),
    do: {:abstain, reason}

  defp dispatch_reference(
         %__MODULE__{reference: {:qualified, head, %{valid_through_ms: valid_through_ms}}} =
           facts,
         at_ms
       ) do
    cond do
      head.chain_id != facts.chain_id or head.scope_id != facts.scope_id ->
        {:abstain, :other_reference}

      at_ms < facts.captured_at_ms ->
        {:abstain, :before_capture}

      at_ms > valid_through_ms ->
        {:abstain, :expired}

      not HeadReference.valid_for_observation?(head, facts.chain_id, at_ms) ->
        {:abstain, :invalid_reference}

      true ->
        {:ok, head}
    end
  end

  defp fixed_height(%{block: {:number, height}}), do: {:ok, height}
  defp fixed_height(%{block: {:tag, :earliest, 0}}), do: {:ok, 0}
  defp fixed_height(%{block: {:hash, :unknown}}), do: {:abstain, :unknown_height}
  defp fixed_height(%{block: {:tag, _moving, nil}}), do: {:abstain, :moving_tag}
  defp fixed_height(%{block: reason}) when reason in [:omitted, :unusable], do: {:abstain, reason}
  defp fixed_height(%{range: {_from, _to}}), do: {:abstain, :range}
  defp fixed_height(_facts), do: {:abstain, :no_selector}

  defp reference(%HeadSnapshot{} = snapshot, plan, now_ms) do
    cond do
      snapshot.scope_id != plan.head_scope.scope_id ->
        {:unavailable, :scope_mismatch}

      snapshot.computed_at_ms > now_ms ->
        {:unavailable, :future_dated}

      now_ms > snapshot.valid_through_ms ->
        {:unavailable, :expired}

      true ->
        qualified_reference(snapshot, plan.chain_id, now_ms)
    end
  end

  defp reference(_unavailable, _plan, _now_ms), do: {:unavailable, :no_snapshot}

  # The reference's own timestamps must precede this request's capture: an
  # observation dated after the snapshot was computed is not accepted.
  defp qualified_reference(snapshot, chain_id, now_ms) do
    case HeadSnapshot.reference(snapshot) do
      {:ok, head} ->
        if HeadReference.valid_for_observation?(head, chain_id, now_ms),
          do:
            {:qualified, head,
             %{
               valid_through_ms: snapshot.valid_through_ms,
               spread: snapshot.spread || :unknown,
               observed_at_ms: head.observed_at_ms || :unknown
             }},
          else: {:unavailable, :invalid_reference}

      {:error, :unqualified} when snapshot.qualification == :qualified ->
        {:unavailable, :no_height}

      {:error, :unqualified} ->
        {:unavailable, snapshot.qualification}
    end
  end
end
