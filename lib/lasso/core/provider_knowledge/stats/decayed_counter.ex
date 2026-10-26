defmodule Lasso.RPC.ProviderKnowledge.Stats.DecayedCounter do
  @moduledoc "A mergeable weighted count with exponential time decay."

  @version 1
  @max_bytes 256

  @enforce_keys [:half_life_ms, :as_of_ms, :mass]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          half_life_ms: pos_integer(),
          as_of_ms: non_neg_integer(),
          mass: float()
        }

  @spec new(pos_integer(), non_neg_integer()) :: t()
  def new(half_life_ms, now_ms \\ 0)
      when is_integer(half_life_ms) and half_life_ms > 0 and is_integer(now_ms) and now_ms >= 0 do
    %__MODULE__{half_life_ms: half_life_ms, as_of_ms: now_ms, mass: 0.0}
  end

  @spec observe(t(), number(), non_neg_integer()) :: t()
  def observe(%__MODULE__{} = state, weight, at_ms)
      when is_number(weight) and weight >= 0 and is_integer(at_ms) and at_ms >= 0 do
    aligned = decay(state, max(at_ms, state.as_of_ms))

    %{
      aligned
      | mass: aligned.mass + weight * decay_factor(aligned.half_life_ms, at_ms, aligned.as_of_ms)
    }
  end

  @spec decay(t(), non_neg_integer()) :: t()
  def decay(%__MODULE__{} = state, at_ms) when is_integer(at_ms) and at_ms >= state.as_of_ms do
    %{
      state
      | as_of_ms: at_ms,
        mass: state.mass * decay_factor(state.half_life_ms, state.as_of_ms, at_ms)
    }
  end

  @spec value(t(), non_neg_integer()) :: float()
  def value(%__MODULE__{} = state, at_ms) when is_integer(at_ms) and at_ms >= state.as_of_ms,
    do: decay(state, at_ms).mass

  @spec merge(t(), t()) :: t()
  def merge(
        %__MODULE__{half_life_ms: half_life_ms} = left,
        %__MODULE__{half_life_ms: half_life_ms} = right
      ) do
    at_ms = max(left.as_of_ms, right.as_of_ms)
    %{decay(left, at_ms) | mass: value(left, at_ms) + value(right, at_ms)}
  end

  @spec encode(t()) :: {:ok, binary()} | {:error, :too_large}
  def encode(%__MODULE__{} = state) do
    payload = :erlang.term_to_binary({@version, state.half_life_ms, state.as_of_ms, state.mass})
    if byte_size(payload) <= @max_bytes, do: {:ok, payload}, else: {:error, :too_large}
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, :invalid}
  def decode(payload) when is_binary(payload) and byte_size(payload) <= @max_bytes do
    case :erlang.binary_to_term(payload, [:safe]) do
      {@version, half_life_ms, as_of_ms, mass}
      when is_integer(half_life_ms) and half_life_ms > 0 and is_integer(as_of_ms) and
             as_of_ms >= 0 and is_float(mass) and mass >= 0 ->
        {:ok, %__MODULE__{half_life_ms: half_life_ms, as_of_ms: as_of_ms, mass: mass}}

      _ ->
        {:error, :invalid}
    end
  rescue
    ArgumentError -> {:error, :invalid}
  end

  def decode(_), do: {:error, :invalid}

  @doc "Finite, bounded counter state admitted from a checkpoint."
  @spec valid?(term(), pos_integer()) :: boolean()
  def valid?(%__MODULE__{half_life_ms: half_life, as_of_ms: at, mass: mass}, half_life),
    do:
      is_integer(at) and at >= 0 and at <= System.system_time(:millisecond) and
        is_float(mass) and mass >= 0 and mass <= 1.0e15

  def valid?(_, _), do: false

  defp decay_factor(half_life_ms, from_ms, to_ms),
    do: :math.pow(0.5, (to_ms - from_ms) / half_life_ms)
end
