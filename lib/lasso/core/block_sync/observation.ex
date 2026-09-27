defmodule Lasso.BlockSync.Observation do
  @moduledoc """
  Reads block-height evidence under the instance's effective freshness contract.
  """

  alias Lasso.BlockSync.{Registry, Worker}
  alias Lasso.Observations.HeadObservation

  @default_stale_after_ms 60_000

  @type t :: %{
          height: non_neg_integer(),
          observed_at_ms: integer(),
          source: :http | :ws,
          metadata: map(),
          stale_after_ms: pos_integer(),
          age_ms: non_neg_integer()
        }

  @spec read(pos_integer(), String.t(), integer()) ::
          {:ok, t()} | {:error, :not_found | {:stale, t()}}
  def read(chain_id, instance_id, now_ms \\ System.system_time(:millisecond))
      when is_integer(chain_id) and chain_id > 0 and is_binary(instance_id) and
             is_integer(now_ms) do
    case Registry.get_height(chain_id, instance_id) do
      {:ok, {height, observed_at_ms, source, metadata}} ->
        stale_after_ms =
          case Map.get(metadata, :stale_after_ms) do
            value when is_integer(value) and value > 0 -> value
            _missing_or_invalid -> stale_after_ms(instance_id, chain_id, source)
          end

        observation = %{
          height: height,
          observed_at_ms: observed_at_ms,
          source: source,
          metadata: metadata,
          stale_after_ms: stale_after_ms,
          age_ms: max(0, now_ms - observed_at_ms)
        }

        if fresh?(observation, now_ms),
          do: {:ok, observation},
          else: {:error, {:stale, observation}}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc "Reads a matching stored transport using the captured route freshness window."
  @spec read_transport(pos_integer(), String.t(), :http | :ws, integer(), pos_integer()) ::
          {:ok, t()} | {:error, :not_found | {:stale, t()}}
  def read_transport(chain_id, instance_id, transport, now_ms, compiled_freshness_ms)
      when transport in [:http, :ws] and is_integer(compiled_freshness_ms) and
             compiled_freshness_ms > 0 do
    case Registry.get_observation(chain_id, instance_id, transport) do
      {:ok, %HeadObservation{} = fact} ->
        classify_transport(
          fact.height,
          fact.observed_at_ms,
          transport,
          observation_metadata(fact),
          now_ms,
          compiled_freshness_ms
        )

      {:error, :not_found} ->
        case Registry.get_height(chain_id, instance_id) do
          {:ok, {height, observed_at_ms, ^transport, metadata}} ->
            classify_transport(
              height,
              observed_at_ms,
              transport,
              metadata,
              now_ms,
              compiled_freshness_ms
            )

          _missing_transport ->
            {:error, :not_found}
        end
    end
  end

  @spec fresh?(map(), integer()) :: boolean()
  def fresh?(observation, now_ms \\ System.system_time(:millisecond))
      when is_map(observation) and is_integer(now_ms) do
    observed_at_ms = Map.get(observation, :observed_at_ms, Map.get(observation, :timestamp))
    stale_after_ms = Map.get(observation, :stale_after_ms, @default_stale_after_ms)

    is_integer(observed_at_ms) and is_integer(stale_after_ms) and stale_after_ms > 0 and
      now_ms - observed_at_ms <= stale_after_ms
  end

  @spec stale_after_ms(String.t(), pos_integer(), :http | :ws | nil) :: pos_integer()
  def stale_after_ms(instance_id, chain_id, source \\ nil)
      when is_binary(instance_id) and is_integer(chain_id) and chain_id > 0 and
             source in [:http, :ws, nil] do
    config = Worker.load_config(instance_id, chain_id)
    positive(Map.get(config, :evidence_freshness_ms), @default_stale_after_ms)
  rescue
    _error -> @default_stale_after_ms
  catch
    :exit, _reason -> @default_stale_after_ms
  end

  @doc "Returns the freshness window for a retained transport fact."
  @spec effective_stale_after_ms(HeadObservation.t(), pos_integer() | nil) :: pos_integer()
  def effective_stale_after_ms(%HeadObservation{} = observation, compiled_freshness_ms) do
    base =
      if is_integer(compiled_freshness_ms) and compiled_freshness_ms > 0,
        do: compiled_freshness_ms,
        else: stale_after_ms(observation.instance_id, observation.chain_id, observation.transport)

    Enum.max([
      base,
      positive(Map.get(observation.attributes, :stale_after_ms), 0),
      3 * positive(observation.sample_interval_ms, 0)
    ])
  end

  defp classify_transport(
         height,
         observed_at_ms,
         transport,
         metadata,
         now_ms,
         compiled_freshness_ms
       ) do
    stale_after_ms =
      Enum.max([
        compiled_freshness_ms,
        positive(Map.get(metadata, :stale_after_ms), 0),
        3 * positive(Map.get(metadata, :sample_interval_ms), 0)
      ])

    observation = %{
      height: height,
      observed_at_ms: observed_at_ms,
      source: transport,
      metadata: metadata,
      stale_after_ms: stale_after_ms,
      age_ms: max(0, now_ms - observed_at_ms)
    }

    if fresh?(observation, now_ms),
      do: {:ok, observation},
      else: {:error, {:stale, observation}}
  end

  defp observation_metadata(%HeadObservation{} = observation) do
    observation.attributes
    |> Map.put(:origin_member_id, observation.origin_member_id)
    |> Map.put(:hash, observation.block_hash)
    |> Map.put(:parent_hash, observation.parent_hash)
    |> Map.put(:timestamp, observation.block_timestamp)
    |> Map.put(:latency_ms, observation.latency_ms)
    |> Map.put(:poll_references, observation.poll_references)
  end

  defp positive(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive(_value, fallback), do: fallback
end
