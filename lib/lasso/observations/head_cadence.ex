defmodule Lasso.Observations.HeadCadence do
  @moduledoc """
  A chain's block cadence, measured from attributed head observations.

  A sample is one route's head advancing across a window: the elapsed time
  between two observations of the same upstream transport and the blocks it
  gained. Elapsed time over blocks gained across the retained samples is the
  measured block time. The per-sample rates, weighted by blocks, give its
  descriptive percentile spread. Negative inference separately credits the
  fastest retained sample so acceleration cannot be hidden by older windows.

  The measurement qualifies only with enough samples over enough time. Until
  then the configured seed applies, and without a seed cadence stays unknown.
  Nothing here adapts routing tolerances; the band is the caller's.
  """

  @window_ms 10_000
  @max_sample_ms 300_000
  @min_samples 8
  @min_elapsed_ms 30_000
  @stall_intervals 4
  @stall_floor_ms 2_000

  @type route :: {String.t(), :http | :ws}
  @type sample :: %{
          elapsed_ms: pos_integer(),
          blocks: pos_integer(),
          route: route(),
          at_ms: integer()
        }
  @type anchor :: %{height: non_neg_integer(), at_ms: integer()}
  @type samples :: %{anchors: %{route() => anchor()}, samples: [sample()]}
  @type source :: :measured | :seed | :unknown

  @type t :: %__MODULE__{
          source: source(),
          block_time_ms: pos_integer() | nil,
          credit_block_time_ms: pos_integer() | nil,
          low_ms: pos_integer() | nil,
          high_ms: pos_integer() | nil,
          samples: non_neg_integer(),
          elapsed_ms: non_neg_integer(),
          routes: non_neg_integer(),
          seed_ms: pos_integer() | nil,
          measured_at_ms: integer() | nil,
          expires_at_ms: integer() | nil
        }

  defstruct source: :unknown,
            block_time_ms: nil,
            credit_block_time_ms: nil,
            low_ms: nil,
            high_ms: nil,
            samples: 0,
            elapsed_ms: 0,
            routes: 0,
            seed_ms: nil,
            measured_at_ms: nil,
            expires_at_ms: nil

  @spec empty() :: samples()
  def empty, do: %{anchors: %{}, samples: []}

  @doc """
  Folds one observation of a route into the samples. A route's first
  observation anchors it; a later, higher observation at least one window
  after the anchor becomes a sample and re-anchors the route. A lower
  observation, or one more than the longest plausible sample after the
  anchor, only re-anchors.
  """
  @spec observe(samples(), route(), non_neg_integer(), integer()) :: samples()
  def observe(%{anchors: anchors, samples: samples} = state, route, height, at_ms)
      when is_integer(height) and height >= 0 and is_integer(at_ms) do
    anchors =
      Map.filter(anchors, fn {_route, anchor} -> at_ms - anchor.at_ms <= @max_sample_ms end)

    samples = Enum.filter(samples, &(at_ms - &1.at_ms <= @max_sample_ms))
    state = %{state | anchors: anchors, samples: samples}
    anchor = %{height: height, at_ms: at_ms}

    case Map.get(anchors, route) do
      %{at_ms: anchored_at} when at_ms < anchored_at ->
        state

      %{height: anchored_height, at_ms: anchored_at}
      when height > anchored_height and at_ms - anchored_at >= @window_ms and
             at_ms - anchored_at <= @max_sample_ms ->
        sample = %{
          elapsed_ms: at_ms - anchored_at,
          blocks: height - anchored_height,
          route: route,
          at_ms: at_ms
        }

        %{
          state
          | anchors: Map.put(anchors, route, anchor),
            samples: [sample | samples]
        }

      %{height: anchored_height, at_ms: anchored_at}
      when height >= anchored_height and at_ms - anchored_at <= @max_sample_ms ->
        state

      _missing_regressed_or_too_old ->
        %{state | anchors: Map.put(anchors, route, anchor)}
    end
  end

  @doc "Retains each route's windows by age, independently of route count."
  @spec prune(samples(), integer()) :: samples()
  def prune(%{anchors: anchors, samples: samples}, now_ms) do
    %{
      anchors:
        Map.filter(anchors, fn {_route, anchor} ->
          now_ms - anchor.at_ms <= @max_sample_ms
        end),
      samples: Enum.filter(samples, &(now_ms - &1.at_ms <= @max_sample_ms))
    }
  end

  @doc "The cadence the retained samples establish, falling back to the seed."
  @spec resolve(samples() | nil, pos_integer() | nil) :: t()
  def resolve(state, seed_ms) do
    samples = if is_map(state), do: state.samples, else: []
    elapsed_ms = samples |> Enum.map(& &1.elapsed_ms) |> Enum.sum()

    span_ms =
      case samples do
        [] ->
          0

        samples ->
          Enum.max(Enum.map(samples, & &1.at_ms)) -
            Enum.min(Enum.map(samples, &(&1.at_ms - &1.elapsed_ms)))
      end

    blocks = samples |> Enum.map(& &1.blocks) |> Enum.sum()

    expires_at_ms =
      samples |> Enum.map(&(&1.at_ms + @max_sample_ms + 1)) |> Enum.min(fn -> nil end)

    cond do
      length(samples) >= @min_samples and span_ms >= @min_elapsed_ms and blocks > 0 ->
        rates = samples |> Enum.map(&{&1.elapsed_ms / &1.blocks, &1.blocks}) |> Enum.sort()
        low_ms = rates |> weighted_percentile(blocks, 0.1) |> ceil_ms()

        %__MODULE__{
          source: :measured,
          expires_at_ms: expires_at_ms,
          block_time_ms: max(div(elapsed_ms + blocks - 1, blocks), 1),
          credit_block_time_ms: rates |> hd() |> elem(0) |> ceil_ms(),
          low_ms: low_ms,
          high_ms: rates |> weighted_percentile(blocks, 0.9) |> ceil_ms(),
          samples: length(samples),
          elapsed_ms: elapsed_ms,
          routes: samples |> Enum.map(& &1.route) |> Enum.uniq() |> length(),
          seed_ms: seed_ms,
          measured_at_ms: samples |> Enum.map(& &1.at_ms) |> Enum.max(fn -> nil end)
        }

      is_integer(seed_ms) and seed_ms > 0 ->
        %__MODULE__{
          source: :seed,
          expires_at_ms: expires_at_ms,
          block_time_ms: seed_ms,
          credit_block_time_ms: max(div(seed_ms, 2), 1),
          samples: length(samples),
          elapsed_ms: elapsed_ms,
          seed_ms: seed_ms
        }

      true ->
        %__MODULE__{
          samples: length(samples),
          elapsed_ms: elapsed_ms,
          expires_at_ms: expires_at_ms
        }
    end
  end

  @doc "Applies scalar expiry and the plan's seed without reading cadence samples."
  @spec with_seed(t() | nil, pos_integer() | nil, integer()) :: t()
  def with_seed(cadence, seed_ms, now_ms \\ System.system_time(:millisecond))

  def with_seed(%__MODULE__{source: :measured, expires_at_ms: expiry} = cadence, seed_ms, now_ms)
      when is_integer(expiry) and now_ms < expiry,
      do: %{cadence | seed_ms: seed_ms}

  def with_seed(%__MODULE__{expires_at_ms: expiry}, seed_ms, now_ms)
      when is_integer(expiry) and now_ms >= expiry,
      do: fallback(seed_ms)

  def with_seed(cadence, seed_ms, _now_ms) do
    resolved = fallback(seed_ms)

    if is_struct(cadence, __MODULE__),
      do: %{
        resolved
        | samples: cadence.samples,
          elapsed_ms: cadence.elapsed_ms,
          expires_at_ms: cadence.expires_at_ms
      },
      else: resolved
  end

  @doc "Blocks a route could have produced since an observation of the given age."
  @spec credit_blocks(t(), non_neg_integer()) :: non_neg_integer() | nil
  def credit_blocks(%__MODULE__{credit_block_time_ms: nil}, _age_ms), do: nil

  def credit_blocks(%__MODULE__{credit_block_time_ms: block_time_ms}, age_ms)
      when is_integer(age_ms) and age_ms >= 0,
      do: div(age_ms + block_time_ms - 1, block_time_ms)

  @doc "How long without an observed advance before fresh observations describe a stall."
  @spec stall_after_ms(t(), pos_integer()) :: pos_integer()
  def stall_after_ms(%__MODULE__{block_time_ms: nil}, fallback_ms), do: fallback_ms

  def stall_after_ms(%__MODULE__{block_time_ms: block_time_ms}, _fallback_ms),
    do: max(block_time_ms * @stall_intervals, @stall_floor_ms)

  defp fallback(seed_ms) when is_integer(seed_ms) and seed_ms > 0 do
    %__MODULE__{
      source: :seed,
      block_time_ms: seed_ms,
      credit_block_time_ms: max(div(seed_ms, 2), 1),
      seed_ms: seed_ms
    }
  end

  defp fallback(_seed_ms), do: %__MODULE__{}

  defp weighted_percentile(rates, total, quantile) do
    target = total * quantile

    rates
    |> Enum.reduce_while(0, fn {rate, weight}, seen ->
      if seen + weight >= target, do: {:halt, rate}, else: {:cont, seen + weight}
    end)
    |> case do
      rate when is_number(rate) -> rate
      _exhausted -> rates |> Enum.map(&elem(&1, 0)) |> Enum.max()
    end
  end

  defp ceil_ms(rate), do: max(trunc(Float.ceil(rate * 1.0)), 1)
end
