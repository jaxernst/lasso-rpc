defmodule Lasso.RPC.ProviderKnowledge.Stats.Bracket do
  @moduledoc "A bounded mergeable success/failure bracket for a numeric request dimension."

  @version 3
  @max_observations 128
  @max_bytes 16_384

  @enforce_keys [:ttl_ms, :observations]
  defstruct @enforce_keys

  @type height :: {non_neg_integer(), non_neg_integer()} | nil
  @type observation ::
          {non_neg_integer(), :success | :failure, non_neg_integer() | nil, binary(), height()}
  @type t :: %__MODULE__{ttl_ms: pos_integer(), observations: map()}

  @spec new(pos_integer()) :: t()
  def new(ttl_ms) when is_integer(ttl_ms) and ttl_ms > 0,
    do: %__MODULE__{ttl_ms: ttl_ms, observations: MapSet.new()}

  @spec observe(
          t(),
          :success | :failure,
          non_neg_integer() | nil,
          non_neg_integer(),
          binary(),
          height()
        ) :: t()
  def observe(state, kind, value, at_ms, observation_id, height \\ nil)

  def observe(%__MODULE__{} = state, kind, value, at_ms, observation_id, height)
      when kind in [:success, :failure] and (is_nil(value) or (is_integer(value) and value >= 0)) and
             is_integer(at_ms) and at_ms >= 0 and is_binary(observation_id) and
             byte_size(observation_id) in 1..64 do
    %{
      state
      | observations:
          retain(
            MapSet.put(
              normalize(state).observations,
              {at_ms, kind, value, observation_id, height}
            )
          )
    }
  end

  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{ttl_ms: ttl_ms} = left, %__MODULE__{ttl_ms: ttl_ms} = right),
    do: %{
      left
      | observations:
          retain(MapSet.union(normalize(left).observations, normalize(right).observations))
    }

  @spec decay(t(), non_neg_integer()) :: t()
  def decay(%__MODULE__{} = state, now_ms) when is_integer(now_ms) and now_ms >= 0 do
    observations =
      normalize(state).observations
      |> Enum.filter(fn {at_ms, _, _, _, _} ->
        at_ms <= now_ms and now_ms - at_ms < state.ttl_ms
      end)
      |> MapSet.new()

    %{state | observations: observations}
  end

  @spec bounds(t()) :: %{
          largest_success: non_neg_integer() | nil,
          smallest_failure: non_neg_integer() | nil
        }
  def bounds(%__MODULE__{} = state) do
    normalize(state).observations
    |> Enum.sort()
    |> Enum.reduce(%{largest_success: nil, smallest_failure: nil}, fn
      {_at, :success, value, _id, _height}, bounds when is_integer(value) ->
        failure = bounds.smallest_failure
        failure = if is_integer(failure) and value >= failure, do: nil, else: failure

        %{
          bounds
          | largest_success: max_optional(bounds.largest_success, value),
            smallest_failure: failure
        }

      {_at, :failure, value, _id, _height}, bounds when is_integer(value) ->
        success = bounds.largest_success
        success = if is_integer(success) and value <= success, do: nil, else: success

        %{
          bounds
          | largest_success: success,
            smallest_failure: min_optional(bounds.smallest_failure, value)
        }

      _observation, bounds ->
        bounds
    end)
  end

  @doc "Normalize older four-tuples before every observation union."
  @spec normalize(t()) :: t()
  def normalize(%__MODULE__{} = state) do
    %{
      state
      | observations:
          MapSet.new(state.observations, fn
            {at, kind, value, id} -> {at, kind, value, id, nil}
            {_, _, _, _, _} = observation -> observation
          end)
    }
  end

  @spec encode(t()) :: {:ok, binary()} | {:error, :too_large}
  def encode(%__MODULE__{} = state) do
    payload =
      :erlang.term_to_binary({@version, state.ttl_ms, Enum.sort(normalize(state).observations)})

    if byte_size(payload) <= @max_bytes, do: {:ok, payload}, else: {:error, :too_large}
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, :invalid}
  def decode(payload) when is_binary(payload) and byte_size(payload) <= @max_bytes do
    case :erlang.binary_to_term(payload, [:safe]) do
      {version, ttl_ms, observations}
      when version in [1, 2, @version] and is_integer(ttl_ms) and ttl_ms > 0 and
             is_list(observations) and
             length(observations) <= @max_observations ->
        state = normalize(%__MODULE__{ttl_ms: ttl_ms, observations: MapSet.new(observations)})

        if Enum.all?(state.observations, &valid_observation?/1) do
          {:ok, state}
        else
          {:error, :invalid}
        end

      _ ->
        {:error, :invalid}
    end
  rescue
    _ -> {:error, :invalid}
  end

  def decode(_), do: {:error, :invalid}

  defp retain(observations) do
    observations
    |> Enum.sort(:desc)
    |> Enum.take(@max_observations)
    |> MapSet.new()
  end

  defp valid_observation?({at_ms, kind, value, id, height}),
    do:
      is_integer(at_ms) and at_ms >= 0 and kind in [:success, :failure] and
        (is_nil(value) or (is_integer(value) and value >= 0)) and
        (not is_nil(value) or not is_nil(height)) and valid_height?(height) and is_binary(id) and
        byte_size(id) in 1..64

  defp valid_observation?(_), do: false

  @spec valid_height?(term()) :: boolean()
  def valid_height?(nil), do: true

  def valid_height?({lo, hi}),
    do:
      is_integer(lo) and lo >= 0 and is_integer(hi) and hi >= lo and
        hi <= 9_223_372_036_854_775_807

  def valid_height?(_), do: false

  defp max_optional(nil, value), do: value
  defp max_optional(current, value), do: max(current, value)
  defp min_optional(nil, value), do: value
  defp min_optional(current, value), do: min(current, value)
end
