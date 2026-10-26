defmodule Lasso.RPC.ProviderKnowledge.Learners.SpanBracket do
  @moduledoc "Outcome bracket for numeric eth_getLogs spans on one connection."
  @behaviour Lasso.RPC.ProviderKnowledge.Learner

  alias Lasso.RPC.ProviderKnowledge.Evidence
  alias Lasso.RPC.ProviderKnowledge.Stats.Bracket

  @version 2
  @ttl_ms 86_400_000
  @freshness_ms :timer.minutes(30)
  @max_state_bytes 16_384

  @enforce_keys [:key, :epoch, :bracket]
  defstruct @enforce_keys ++ [:observed_at_ms]

  @type t :: %__MODULE__{}

  @impl true
  def bounds, do: %{max_keys: 4_096, max_state_bytes: @max_state_bytes, version: @version}

  @impl true
  def key(
        %Evidence{method: "eth_getLogs", shape: {:logs_span, :number, _}, shape_value: span} =
          evidence
      )
      when is_integer(span) and span >= 0 do
    if observation_kind(evidence) == :skip,
      do: :skip,
      else: {evidence.subject, evidence.partition, :logs}
  end

  def key(_), do: :skip

  @impl true
  def init(key), do: %__MODULE__{key: key, epoch: 0, bracket: Bracket.new(@ttl_ms)}

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
                    evidence.shape_value,
                    evidence.observed_at_ms,
                    observation_id(evidence)
                  ),
                observed_at_ms: max_optional(state.observed_at_ms, evidence.observed_at_ms)
            }
        end
    end
  end

  @impl true
  def decay(%__MODULE__{} = state, now_ms) do
    bracket = Bracket.decay(state.bracket, now_ms)
    if MapSet.size(bracket.observations) == 0, do: :expired, else: %{state | bracket: bracket}
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

  def merge(%__MODULE__{key: key} = left, %__MODULE__{key: key} = right) do
    %{
      left
      | bracket: Bracket.merge(left.bracket, right.bracket),
        observed_at_ms: max_optional(left.observed_at_ms, right.observed_at_ms)
    }
  end

  @impl true
  def hints(%__MODULE__{key: {_subject, _partition, :logs}} = state, {:span_limit, :logs}) do
    now_ms = System.system_time(:millisecond)
    fresh = Bracket.decay(state.bracket, now_ms)
    bounds = Bracket.bounds(fresh)
    witness = supported_failure(fresh, now_ms)

    if witness do
      [
        %{
          kind: :span_limit,
          dimension: :logs,
          value: witness.value,
          support: %{
            largest_success: bounds.largest_success,
            smallest_failure: witness.value,
            observations: MapSet.size(fresh.observations)
          },
          learner: __MODULE__,
          version: @version,
          observed_at_ms: witness.latest_at_ms,
          expires_at_ms: witness.earliest_at_ms + @freshness_ms
        }
      ]
    else
      []
    end
  end

  def hints(_, _), do: []

  @impl true
  def publication(%__MODULE__{} = state) do
    hints = hints(state, {:span_limit, :logs})

    {{Enum.sort(state.bracket.observations),
      Enum.map(hints, &Map.take(&1, [:value, :observed_at_ms, :expires_at_ms]))},
     if(hints != [], do: :timer.minutes(15))}
  end

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
        normalize_state(state)

      {1, %__MODULE__{}} ->
        {:error, {:unsupported_version, 1}}

      _ ->
        {:error, :invalid}
    end
  rescue
    _ -> {:error, :invalid}
  end

  def decode(_), do: {:error, :invalid}

  defp normalize_state(
         %__MODULE__{
           key: {subject, partition, :logs},
           epoch: epoch,
           observed_at_ms: observed,
           bracket: %Bracket{ttl_ms: @ttl_ms, observations: %MapSet{} = rows} = bracket
         } = state
       ) do
    with true <- is_binary(subject) and byte_size(subject) in 1..128,
         true <- partition in Lasso.RPC.RoutingEvidence.Workload.partitions(),
         true <- is_integer(epoch) and epoch >= 0,
         true <-
           is_integer(observed) and observed >= 0 and
             observed <= System.system_time(:millisecond),
         true <- MapSet.size(rows) in 1..128,
         {:ok, payload} <- Bracket.encode(bracket),
         {:ok, normalized} <- Bracket.decode(payload),
         true <-
           Enum.all?(normalized.observations, fn {at, _, value, _, height} ->
             at <= observed and is_integer(value) and value >= 0 and
               value <= 9_223_372_036_854_775_807 and is_nil(height)
           end) do
      {:ok, %{state | bracket: normalized}}
    else
      _ -> {:error, :invalid}
    end
  end

  defp normalize_state(_), do: {:error, :invalid}

  defp observation_kind(%Evidence{outcome: :success, qualification: :accepted}), do: :success

  defp observation_kind(%Evidence{outcome: :application_error, constraint_kind: :block_range}),
    do: :failure

  defp observation_kind(_), do: :skip

  defp supported_failure(bracket, now_ms) do
    successes = Enum.filter(bracket.observations, &(elem(&1, 1) == :success))

    failures =
      Enum.filter(bracket.observations, fn
        {at, :failure, span, <<"request:", _hash::binary-size(43)>>, _} ->
          now_ms - at < @freshness_ms and
            not Enum.any?(successes, fn {s_at, _, s_span, _, _} ->
              s_at >= at and s_span >= span
            end)

        _ ->
          false
      end)

    candidate =
      failures
      |> Enum.sort_by(&elem(&1, 2))
      |> Enum.uniq_by(&elem(&1, 3))
      |> Enum.at(1)

    with {_, _, value, _, _} <- candidate do
      times =
        failures
        |> Enum.filter(&(elem(&1, 2) <= value))
        |> Enum.reduce(%{}, fn {at, _, _, request, _}, witnesses ->
          Map.update(witnesses, request, at, &max(&1, at))
        end)
        |> Map.values()
        |> Enum.sort(:desc)
        |> Enum.take(2)

      %{value: value, earliest_at_ms: List.last(times), latest_at_ms: hd(times)}
    end
  end

  defp observation_id(evidence) do
    hash = :crypto.hash(:sha256, evidence.request_nonce) |> Base.url_encode64(padding: false)
    "request:" <> hash
  end

  defp max_optional(nil, value), do: value
  defp max_optional(value, nil), do: value
  defp max_optional(left, right), do: max(left, right)
end
