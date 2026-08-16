defmodule Lasso.RPC.RoutingEvidence do
  @moduledoc """
  Architecture-neutral seams for recording terminal attempts and reading published summaries.

  The default recorder emits telemetry only. The evidence-store topology is intentionally supplied
  by a later measured backend rather than by the request pipeline.
  """

  alias Lasso.RPC.{AttemptProjection, Channel}
  alias Lasso.RPC.RoutingEvidence.{AttemptEvent, Summary}

  @type upstream_key :: {String.t(), :http | :ws}

  @doc "Records one terminal attempt event."
  @spec record(AttemptEvent.t()) :: :ok
  def record(%AttemptEvent{} = event) do
    recorder().record(event)
  end

  @doc "Reads published evidence for concrete channel instances in one batch."
  @spec batch_get_summaries([Channel.t() | map()], pos_integer(), atom()) ::
          %{upstream_key() => Summary.t() | nil}
  def batch_get_summaries(channels, chain_id, workload_key) do
    profile =
      channels
      |> List.first()
      |> then(&if(&1, do: Map.get(&1, :profile, "public"), else: "public"))

    batch_get_summaries(profile, channels, chain_id, workload_key)
  end

  @doc false
  @spec batch_get_summaries(binary(), [Channel.t() | map()], pos_integer(), atom()) ::
          %{upstream_key() => Summary.t() | nil}
  def batch_get_summaries(profile, channels, chain_id, workload_key),
    do: AttemptProjection.batch_summaries(profile, channels, chain_id, workload_key)

  @doc false
  @spec summary_for_channel(map(), map()) :: Summary.t() | nil
  def summary_for_channel(summaries, channel) do
    case Map.get(channel, :instance_id) do
      instance_id when is_binary(instance_id) ->
        Map.get(summaries, {instance_id, channel.transport})

      _ ->
        nil
    end
  end

  @doc false
  @spec qualified?(Summary.t() | nil) :: boolean()
  def qualified?(%Summary{state: :qualified, successful_mean_latency_ms: mean})
      when is_number(mean) and mean > 0,
      do: true

  def qualified?(_summary), do: false

  @doc false
  @spec emit_availability_degradation(
          binary(),
          atom(),
          pos_integer(),
          atom(),
          non_neg_integer()
        ) :: :ok
  def emit_availability_degradation(
        profile,
        strategy,
        chain_id,
        workload_key,
        _candidate_count
      ) do
    _result =
      AttemptProjection.record_availability_degradation(
        profile,
        chain_id,
        strategy,
        workload_key
      )

    :ok
  end

  defp recorder do
    Application.get_env(:lasso, :attempt_evidence_recorder, __MODULE__.TelemetryRecorder)
  end

  defmodule TelemetryRecorder do
    @moduledoc false

    alias Lasso.RPC.RoutingEvidence.AttemptEvent

    @spec record(AttemptEvent.t()) :: :ok
    def record(%AttemptEvent{} = event) do
      duration_ms = event.elapsed_io_ms || event.censoring_boundary_ms

      :telemetry.execute(
        [:lasso, :rpc, :attempt, :stop],
        %{count: 1, duration_ms: duration_ms},
        %{
          request_id: event.request_id,
          upstream_instance_id: event.upstream_instance_id,
          chain_id: event.chain_id,
          provider_id: event.provider_id,
          transport: event.transport,
          workload_key: event.workload_key,
          observed_at_ms: event.observed_at_ms,
          outcome: event.outcome,
          censored: not is_nil(event.censoring_boundary_ms),
          error_category: event.error_category
        }
      )

      :ok
    end
  end
end
