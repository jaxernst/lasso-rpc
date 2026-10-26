defmodule Lasso.RPC.ProviderKnowledge.Stats.LatencyHistogram do
  @moduledoc "Fixed logarithmic latency buckets with the same decay as a counter."
  import Bitwise

  alias Lasso.RPC.ProviderKnowledge.Stats.DecayedCounter

  @version 1
  @max_bucket 31
  @max_bytes 4_096

  @enforce_keys [:half_life_ms, :buckets]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          half_life_ms: pos_integer(),
          buckets: %{non_neg_integer() => DecayedCounter.t()}
        }

  @spec new(pos_integer()) :: t()
  def new(half_life_ms) when is_integer(half_life_ms) and half_life_ms > 0,
    do: %__MODULE__{half_life_ms: half_life_ms, buckets: %{}}

  @spec observe(t(), non_neg_integer(), non_neg_integer()) :: t()
  def observe(%__MODULE__{} = state, latency_us, at_ms)
      when is_integer(latency_us) and latency_us >= 0 and is_integer(at_ms) and at_ms >= 0 do
    bucket = bucket(latency_us)
    counter = Map.get(state.buckets, bucket, DecayedCounter.new(state.half_life_ms, at_ms))
    %{state | buckets: Map.put(state.buckets, bucket, DecayedCounter.observe(counter, 1, at_ms))}
  end

  @spec decay(t(), non_neg_integer()) :: t()
  def decay(%__MODULE__{} = state, at_ms) do
    buckets =
      Map.new(state.buckets, fn {bucket, counter} ->
        {bucket, DecayedCounter.decay(counter, max(at_ms, counter.as_of_ms))}
      end)

    %{state | buckets: buckets}
  end

  @spec merge(t(), t()) :: t()
  def merge(
        %__MODULE__{half_life_ms: half_life_ms} = left,
        %__MODULE__{half_life_ms: half_life_ms} = right
      ) do
    keys = (Map.keys(left.buckets) ++ Map.keys(right.buckets)) |> Enum.uniq()

    buckets =
      Map.new(keys, fn key ->
        merged =
          case {Map.get(left.buckets, key), Map.get(right.buckets, key)} do
            {nil, counter} -> counter
            {counter, nil} -> counter
            {a, b} -> DecayedCounter.merge(a, b)
          end

        {key, merged}
      end)

    %{left | buckets: buckets}
  end

  @spec count(t(), non_neg_integer()) :: float()
  def count(%__MODULE__{} = state, at_ms),
    do:
      Enum.reduce(state.buckets, 0.0, fn {_bucket, counter}, total ->
        total + DecayedCounter.value(counter, max(at_ms, counter.as_of_ms))
      end)

  @spec quantile(t(), float(), non_neg_integer()) :: non_neg_integer() | nil
  def quantile(%__MODULE__{} = state, q, at_ms) when is_number(q) and q >= 0 and q <= 1 do
    total = count(state, at_ms)

    if total == 0 do
      nil
    else
      state.buckets
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce_while(0.0, fn {bucket, counter}, cumulative ->
        next = cumulative + DecayedCounter.value(counter, max(at_ms, counter.as_of_ms))
        if next >= max(q * total, 0.000001), do: {:halt, upper_bound(bucket)}, else: {:cont, next}
      end)
    end
  end

  @spec bucket(non_neg_integer()) :: 0..31
  def bucket(0), do: 0

  def bucket(latency_us) when is_integer(latency_us) and latency_us > 0,
    do: min(:erlang.floor(:math.log2(latency_us)) + 1, @max_bucket)

  @spec encode(t()) :: {:ok, binary()} | {:error, :too_large}
  def encode(%__MODULE__{} = state) do
    rows =
      Enum.map(state.buckets, fn {bucket, counter} -> {bucket, counter.as_of_ms, counter.mass} end)

    payload = :erlang.term_to_binary({@version, state.half_life_ms, rows})
    if byte_size(payload) <= @max_bytes, do: {:ok, payload}, else: {:error, :too_large}
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, :invalid}
  def decode(payload) when is_binary(payload) and byte_size(payload) <= @max_bytes do
    case :erlang.binary_to_term(payload, [:safe]) do
      {@version, half_life_ms, rows}
      when is_integer(half_life_ms) and half_life_ms > 0 and is_list(rows) and
             length(rows) <= @max_bucket + 1 ->
        with true <- Enum.all?(rows, &valid_row?/1),
             true <- rows |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == length(rows) do
          buckets =
            Map.new(rows, fn {bucket, as_of_ms, mass} ->
              {bucket,
               %DecayedCounter{half_life_ms: half_life_ms, as_of_ms: as_of_ms, mass: mass}}
            end)

          {:ok, %__MODULE__{half_life_ms: half_life_ms, buckets: buckets}}
        else
          _ -> {:error, :invalid}
        end

      _ ->
        {:error, :invalid}
    end
  rescue
    ArgumentError -> {:error, :invalid}
  end

  def decode(_), do: {:error, :invalid}

  defp valid_row?({bucket, at_ms, mass}),
    do:
      is_integer(bucket) and bucket in 0..@max_bucket and is_integer(at_ms) and at_ms >= 0 and
        is_float(mass) and mass >= 0

  defp valid_row?(_), do: false

  defp upper_bound(0), do: 0
  defp upper_bound(bucket), do: 1 <<< bucket
end
