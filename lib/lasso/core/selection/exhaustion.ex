defmodule Lasso.RPC.Selection.Exhaustion do
  @moduledoc """
  Bounded, local evidence for exhausted profile-selection phases.

  Recorded cursor rejections describe the attempted selection. Other fields are
  explicitly a local observation at exhaustion, not a reconstruction of earlier
  state. No provider config, request params, credentials or raw errors are emitted.
  """
  require Logger

  alias Lasso.Config.ConfigStore
  alias Lasso.Core.Support.CircuitBreaker.Snapshot, as: BreakerSnapshot
  alias Lasso.Providers.{Catalog, InstanceState}

  alias Lasso.RPC.{
    BoundedIdentifier,
    Selection.CandidateCursor,
    SelectionFilters
  }

  @limit 16

  @spec record(
          Lasso.RPC.RequestContext.t(),
          CandidateCursor.t() | [Lasso.RPC.Channel.t()] | {:unavailable, map()},
          atom()
        ) :: :ok
  def record(ctx, candidates, reason), do: emit(ctx, candidates, reason, true)

  @doc "Logs a terminal no-selection failure without creating telemetry or metric series."
  @spec log_failure(Lasso.RPC.RequestContext.t(), CandidateCursor.t() | list() | tuple(), atom()) ::
          :ok
  def log_failure(ctx, candidates, reason), do: emit(ctx, candidates, reason, false)

  defp emit(ctx, candidates, reason, telemetry?) do
    evidence = evidence(ctx, candidates, reason, not telemetry?) |> bound()

    level =
      if String.starts_with?(ctx.request_id || "", "block-sync:"), do: :debug, else: :warning

    Logger.log(level, fn -> "Selection exhausted " <> Jason.encode!(evidence) end)

    if telemetry? do
      :telemetry.execute([:lasso, :routing, :selection_exhausted], %{count: 1}, evidence)
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp evidence(ctx, candidates, reason, terminal?) do
    snapshot = Catalog.snapshot()
    profile = ctx.opts.profile
    generation = ConfigStore.route_generation()
    plan = plan(candidates, snapshot, profile, ctx.chain_id)
    providers = if plan, do: plan.providers, else: []
    filters = filters(candidates, ctx, plan)

    evidence = %{
      version: 1,
      request_id: BoundedIdentifier.encode_optional(ctx.request_id),
      profile: BoundedIdentifier.encode(if(plan, do: plan.profile, else: profile)),
      chain_id: ctx.chain_id,
      method: BoundedIdentifier.encode(ctx.method),
      reason: reason,
      fallback: fallback?(ctx),
      observation: :at_exhaustion,
      capture_failure: capture_failure(candidates),
      omitted_rejections: omitted_rejections(candidates),
      catalog_available: is_map(snapshot),
      catalog_table_available: table_available?(snapshot),
      catalog_generation: catalog_generation(snapshot),
      config_generation: generation,
      captured_generation: captured_generation(candidates),
      catalog_status: catalog_status(snapshot, generation, plan),
      provider_set_empty: if(plan, do: providers == [], else: nil),
      candidate_count: length(providers),
      omitted_candidates: max(length(providers) - @limit, 0),
      candidates:
        Enum.map(Enum.take(providers, @limit), fn provider ->
          candidate(provider, plan, filters)
        end),
      recorded_rejections: rejections(candidates)
    }

    if terminal? do
      Map.merge(evidence, %{
        phase: if(is_nil(ctx.selection_start), do: :before_selection, else: :selection_completed),
        selection_latency_ms: ctx.selection_latency_ms,
        owner_observation: :not_collected,
        opening_state: :unobserved
      })
    else
      evidence
    end
  rescue
    _ -> unavailable_evidence(ctx, reason)
  catch
    :exit, _ -> unavailable_evidence(ctx, reason)
  end

  defp unavailable_evidence(ctx, reason) do
    %{
      version: 1,
      reason: reason,
      profile: BoundedIdentifier.encode_optional(ctx.opts && ctx.opts.profile),
      chain_id: ctx.chain_id,
      fallback: fallback?(ctx),
      diagnostic_status: :local_state_unavailable
    }
  end

  # A phase after a profile fallback; exhausting it usually ends the request with an error.
  defp fallback?(ctx), do: Map.get(ctx, :fallback_depth, 0) > 0

  defp plan({:unavailable, _}, snapshot, profile, chain), do: plan([], snapshot, profile, chain)

  defp plan(%CandidateCursor{plan: plan}, _snapshot, _profile, _chain), do: plan

  defp plan(snapshot_candidates, %{} = snapshot, profile, chain)
       when is_list(snapshot_candidates) do
    case Catalog.get_routing_plan(snapshot, profile, chain) do
      {:ok, plan} -> plan
      _ -> nil
    end
  end

  defp plan(_, _, _, _), do: nil

  defp catalog_generation(%{generation: generation}), do: generation
  defp catalog_generation(_), do: nil

  defp table_available?(%{table: table}), do: :ets.info(table) != :undefined
  defp table_available?(_), do: false

  defp catalog_status(nil, _generation, _plan), do: :unavailable

  defp catalog_status(%{generation: observed}, generation, _) when observed != generation,
    do: :generation_mismatch

  defp catalog_status(_snapshot, _generation, nil), do: :plan_unavailable
  defp catalog_status(_snapshot, _generation, _plan), do: :available

  defp capture_failure({:unavailable, failure}), do: failure
  defp capture_failure(_), do: nil

  defp captured_generation(%CandidateCursor{plan: plan}), do: plan.generation
  defp captured_generation(_), do: nil
  defp filters(%CandidateCursor{filters: filters}, _ctx, _plan), do: filters

  defp filters(_, ctx, _plan),
    do: SelectionFilters.new(protocol: ctx.opts.transport || :both, include_half_open: true)

  defp omitted_rejections(%CandidateCursor{} = cursor),
    do:
      max(
        Map.get(cursor.effect_context, :selection_rejection_count, 0) -
          length(Map.get(cursor.effect_context, :selection_rejections, [])),
        0
      )

  defp omitted_rejections(_), do: 0

  defp rejections(%CandidateCursor{} = cursor) do
    Enum.map(Map.get(cursor.effect_context, :selection_rejections, []), fn rejection ->
      %{rejection | provider_id: BoundedIdentifier.encode(rejection.provider_id)}
    end)
  end

  defp rejections(_), do: []

  defp candidate(provider, plan, filters) do
    %{
      provider_id: BoundedIdentifier.encode(provider.id),
      instance_id: BoundedIdentifier.encode(provider.instance_id),
      transports: Enum.map([:http, :ws], &transport(provider, &1, plan, filters))
    }
  end

  defp transport(provider, transport, plan, filters) do
    breaker = breaker(provider.instance_id, transport)
    configured? = transport in provider.transports
    requested? = filters.protocol in [nil, :both, transport]

    ws_connected? =
      transport != :ws or InstanceState.read_ws_status(provider.instance_id).status == :connected

    health = InstanceState.read_health(provider.instance_id)

    rate_limit =
      InstanceState.read_rate_limit(provider.instance_id, transport, include_learned: false)

    reasons =
      []
      |> excluded(not configured?, :transport_not_configured)
      |> excluded(not requested?, :transport_not_requested)
      |> excluded(provider.id in filters.exclude, :provider_excluded)
      |> excluded(not ws_connected?, :ws_disconnected)
      |> excluded(breaker.status != :ready, :circuit_unavailable)
      |> excluded(breaker.state == :open, :circuit_open)
      |> excluded(
        breaker.state == :half_open and not filters.include_half_open,
        :half_open_excluded
      )

    %{
      transport: transport,
      observed_exclusions: Enum.reverse(reasons),
      breaker: breaker,
      health: Map.take(health, [:status, :http_status]),
      rate_limit: Map.take(rate_limit, [:rate_limited, :remaining_ms]),
      channel_cache: channel_cache(plan, provider, transport)
    }
  end

  defp breaker(instance, transport) do
    case BreakerSnapshot.lookup({instance, transport}) do
      {:ok, snapshot} ->
        owner_alive? = Process.alive?(snapshot.owner_pid)

        %{
          status: if(snapshot.ready? and owner_alive?, do: :ready, else: :unavailable),
          state: if(snapshot.control_health == :degraded, do: :half_open, else: snapshot.state),
          raw_state: snapshot.state,
          ready: snapshot.ready?,
          owner_alive: owner_alive?,
          control_health: snapshot.control_health
        }

      _ ->
        %{status: :missing, state: :unavailable, ready: false, owner_alive: false}
    end
  rescue
    ArgumentError -> %{status: :missing, state: :unavailable, ready: false, owner_alive: false}
  end

  defp channel_cache(plan, provider, transport) do
    case :ets.lookup(
           :transport_channel_cache,
           {plan.profile, plan.chain_id, provider.id, transport}
         ) do
      [{_, channel}] ->
        if channel.instance_id == provider.instance_id and
             channel.route_generation == plan.generation,
           do: :present,
           else: :identity_mismatch

      [] ->
        :missing
    end
  rescue
    ArgumentError -> :unavailable
  end

  # Stay below the standard Logger truncation limit, including bounded IDs.
  # Telemetry and the single JSON log carry the same truncated evidence.
  defp bound(evidence) do
    if byte_size(Jason.encode!(evidence)) <= 6_000 do
      evidence
    else
      case evidence do
        %{candidates: [_ | _] = candidates} ->
          bound(%{
            evidence
            | candidates: Enum.drop(candidates, -1),
              omitted_candidates: evidence.omitted_candidates + 1
          })

        %{recorded_rejections: [_ | _] = rejections} ->
          bound(%{
            evidence
            | recorded_rejections: Enum.drop(rejections, -1),
              omitted_rejections: evidence.omitted_rejections + 1
          })
      end
    end
  end

  defp excluded(reasons, true, reason), do: [reason | reasons]
  defp excluded(reasons, false, _reason), do: reasons
end
