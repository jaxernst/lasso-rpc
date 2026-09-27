defmodule Lasso.RPC.Selection.Exploration do
  @moduledoc """
  Bounded real-read exploration for adaptive strategies.

  Sampling precedes candidate enumeration. Admission uses a finite, lazy ETS row
  per configured profile, chain and client workload family. A row contains one
  owner and cooldowns only for configured routes; configuration retirement fences
  both reservation and completion. Customer traffic never creates method keys.
  """

  alias Lasso.Config.ConfigStore
  alias Lasso.Providers.InstanceState

  alias Lasso.RPC.{
    AttemptProjection,
    AttemptTerminal,
    BoundedIdentifier,
    Channel,
    ExecutionEnvelope
  }

  alias Lasso.RPC.Providers.AdapterFilter
  alias Lasso.RPC.RoutingEvidence.Workload
  alias Lasso.RPC.Selection

  @table :lasso_instance_state
  @minimum_remaining_ms 500
  @maximum_attempt_ms 100
  @interval_us 1_000_000
  @success_cooldown_us 10_000_000
  @failure_cooldown_us 30_000_000
  @retries 4

  @type token :: %{
          key: tuple(),
          generation: non_neg_integer(),
          route: {binary(), :http | :ws},
          owner: pid(),
          ref: reference(),
          attempt_deadline_us: integer(),
          deadline_us: integer()
        }

  @spec select(Channel.t() | nil, map()) :: {:ok, Channel.t(), token()} | :skip
  def select(%Channel{} = fallback, ctx) do
    if enabled?() do
      cond do
        not eligible_request?(ctx) ->
          skip(fallback, ctx, :ineligible)

        not sampled?() ->
          skip(fallback, ctx, :not_sampled)

        true ->
          case select_candidate(fallback, ctx) do
            :skip -> skip(fallback, ctx, :no_candidate_or_capacity)
            selected -> selected
          end
      end
    else
      :skip
    end
  end

  def select(nil, _ctx), do: :skip

  defp enabled?,
    do: Application.get_env(:lasso, :routing_exploration, []) |> Keyword.get(:enabled, false)

  defp skip(fallback, ctx, reason) do
    :telemetry.execute(
      [:lasso, :routing, :exploration, :skipped],
      %{count: 1},
      %{
        profile: BoundedIdentifier.encode(fallback.profile),
        chain_id: fallback.chain_id,
        workload: Workload.for_request(:client, ctx.method),
        reason: reason
      }
    )

    :skip
  end

  @doc "Checks strategy, safety, origin and remaining-budget policy before sampling."
  @spec eligible_request?(map()) :: boolean()
  def eligible_request?(%{opts: opts, execution_envelope: envelope} = ctx) do
    policy = Application.get_env(:lasso, :routing_exploration, [])
    profile = opts.profile

    Keyword.get(policy, :enabled, false) == true and
      profile not in Keyword.get(policy, :disabled_profiles, []) and
      opts.strategy in [:fastest, :latency_weighted] and opts.provider_override == nil and
      opts.request_origin == :client and envelope.execution_safety == :replay_safe and
      is_nil(ctx.exploration_token) and
      envelope.dispatch_count == 0 and
      Workload.for_request(:client, ctx.method) != :client and
      ExecutionEnvelope.remaining_ms(envelope) >= @minimum_remaining_ms
  end

  defp sampled? do
    every =
      Application.get_env(:lasso, :routing_exploration, []) |> Keyword.get(:sample_every, 100)

    is_integer(every) and every > 0 and :rand.uniform(every) == 1
  end

  defp select_candidate(fallback, ctx) do
    workload = Workload.for_request(:client, ctx.method)

    scope =
      AttemptProjection.scope_state(
        fallback.profile,
        fallback.chain_id,
        fallback.route_generation
      )

    if qualified?(scope, fallback, workload) and eligible_channel?(scope, fallback, ctx) do
      now_us = System.monotonic_time(:microsecond)
      lookup_deadline_us = now_us + budget_ms(ctx.execution_envelope.deadline_us, now_us) * 1_000

      Selection.select_channels(fallback.profile, fallback.chain_id, ctx.method,
        strategy: :load_balanced,
        transport: ctx.opts.transport || :both,
        include_half_open: false,
        exclude: [fallback.provider_id],
        params: ctx.params,
        request_origin: :client,
        deadline_us: lookup_deadline_us,
        limit: 10
      )
      |> Enum.find_value(:skip, fn channel ->
        if channel.instance_id != fallback.instance_id and
             not qualified?(scope, channel, workload) and eligible_channel?(scope, channel, ctx) do
          case reserve(channel, workload, ctx.execution_envelope.deadline_us) do
            {:ok, token} ->
              emit(:selected, token, %{
                attempt_budget_ms: budget_ms(ctx.execution_envelope.deadline_us)
              })

              {:ok, channel, token}

            :skip ->
              nil
          end
        end
      end)
    else
      :skip
    end
  end

  defp qualified?(scope, channel, workload) do
    row = AttemptProjection.route_record(scope, channel.instance_id, channel.transport)

    case AttemptProjection.summarize_route(
           scope,
           row,
           channel.instance_id,
           channel.transport,
           channel.chain_id,
           workload
         ) do
      %{state: :qualified} -> true
      _other -> false
    end
  end

  defp eligible_channel?(scope, channel, ctx) do
    row = AttemptProjection.route_record(scope, channel.instance_id, channel.transport)

    channel.route_generation == scope.generation and not scope.degraded? and row != nil and
      InstanceState.read_candidate_gate(channel.instance_id, channel.transport, row, true) ==
        {:closed, false} and
      AdapterFilter.method_supported?(channel, ctx.method) and
      AdapterFilter.validate_params(channel, ctx.method, ctx.params) == :ok
  end

  @doc "Reserves a current configured route under the finite family budget."
  @spec reserve(Channel.t(), atom(), integer(), integer()) :: {:ok, token()} | :skip
  def reserve(channel, workload, deadline_us, now_us \\ System.monotonic_time(:microsecond)) do
    token = %{
      key:
        {:routing_exploration, BoundedIdentifier.encode(channel.profile), channel.chain_id,
         workload},
      generation: channel.route_generation,
      route: {BoundedIdentifier.encode(channel.instance_id), channel.transport},
      owner: self(),
      ref: make_ref(),
      attempt_deadline_us: now_us + budget_ms(deadline_us, now_us) * 1_000,
      deadline_us: deadline_us
    }

    if workload in Workload.client_partitions() and workload != :client and
         current?(token) and deadline_us - now_us >= @minimum_remaining_ms * 1_000 do
      reserve_token(token, now_us, @retries)
    else
      :skip
    end
  rescue
    ArgumentError -> :skip
  end

  defp reserve_token(_token, _now_us, 0), do: :skip

  defp reserve_token(token, now_us, retries) do
    case :ets.lookup(@table, token.key) do
      [] ->
        row = %{generation: token.generation, active: nil, next_at_us: now_us, cooldowns: %{}}
        :ets.insert_new(@table, {token.key, row})

        if current?(token) do
          reserve_token(token, now_us, retries - 1)
        else
          :ets.delete_object(@table, {token.key, row})
          :skip
        end

      [{key, %{generation: generation} = row}] when generation < token.generation ->
        :ets.delete_object(@table, {key, row})
        reserve_token(token, now_us, retries - 1)

      [{_key, %{generation: generation}}] when generation > token.generation ->
        :skip

      [{_key, row}] ->
        if current?(token) and row.next_at_us <= now_us and
             Map.get(row.cooldowns, token.route, now_us) <= now_us and
             not active?(row.active, now_us) do
          updated = %{
            row
            | active: token,
              next_at_us: now_us + @interval_us,
              cooldowns: Map.put(row.cooldowns, token.route, now_us + @failure_cooldown_us)
          }

          case replace_exact(token.key, row, updated) do
            1 ->
              if current?(token) do
                {:ok, token}
              else
                :ets.delete_object(@table, {token.key, updated})
                :skip
              end

            0 ->
              reserve_token(token, now_us, retries - 1)
          end
        else
          :skip
        end
    end
  end

  defp active?(nil, _now_us), do: false
  defp active?(token, now_us), do: token.deadline_us > now_us and Process.alive?(token.owner)

  @doc "Returns the capped attempt budget without extending the request deadline."
  @spec budget_ms(integer(), integer()) :: non_neg_integer()
  def budget_ms(deadline_us, now_us \\ System.monotonic_time(:microsecond)),
    do: max(min(@maximum_attempt_ms, div(deadline_us - now_us, 10_000)), 0)

  @spec matches?(token() | nil, Channel.t()) :: boolean()
  def matches?(nil, _channel), do: false

  def matches?(token, channel),
    do: token.route == {BoundedIdentifier.encode(channel.instance_id), channel.transport}

  @spec current?(map()) :: boolean()
  def current?(token) do
    {:routing_exploration, profile, chain, _family} = token.key
    {instance, transport} = token.route
    parent = {:routing_control, profile, chain, instance, transport, "client"}

    ConfigStore.route_generation() == token.generation and
      case :ets.lookup(@table, parent) do
        [{^parent, %{generation: generation}}] -> generation == token.generation
        _other -> false
      end
  rescue
    ArgumentError -> false
  end

  @spec complete(token(), struct(), :accepted | :policy_rejected) :: :ok
  def complete(token, fact, qualification \\ :accepted) do
    success? =
      qualification == :accepted and match?(%AttemptTerminal.Response{kind: :success}, fact)

    cooldown = if success?, do: @success_cooldown_us, else: @failure_cooldown_us
    release_token(token, cooldown, @retries)
    outcome = if qualification == :policy_rejected, do: :policy_rejected, else: outcome_kind(fact)
    emit(:completed, token, %{success: success?, outcome: outcome})
    :ok
  end

  @spec release(token() | nil) :: :ok
  def release(nil), do: :ok
  def release(token), do: release_token(token, @failure_cooldown_us, @retries)

  defp release_token(_token, _cooldown, 0), do: :ok

  defp release_token(token, cooldown, retries) do
    case :ets.lookup(@table, token.key) do
      [{_key, %{active: %{ref: ref}} = row}] when ref == token.ref ->
        updated = %{
          row
          | active: nil,
            cooldowns:
              Map.put(row.cooldowns, token.route, System.monotonic_time(:microsecond) + cooldown)
        }

        case replace_exact(token.key, row, updated) do
          0 -> release_token(token, cooldown, retries - 1)
          1 -> unless current?(token), do: :ets.delete_object(@table, {token.key, updated})
        end

      _other ->
        :ok
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Retires exploration rows and cooldowns with their configured route parents."
  @spec reconcile(non_neg_integer()) :: :ok
  def reconcile(generation) do
    for {key, row} <- :ets.match_object(@table, {{:routing_exploration, :_, :_, :_}, :_}) do
      cooldowns =
        Map.filter(row.cooldowns, fn {route, _until} ->
          current?(%{key: key, generation: generation, route: route})
        end)

      if row.generation != generation or map_size(cooldowns) == 0 do
        :ets.delete_object(@table, {key, row})
      else
        active = if row.active && current?(row.active), do: row.active
        replace_exact(key, row, %{row | cooldowns: cooldowns, active: active})
      end
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp replace_exact(key, old, updated) do
    :ets.select_replace(@table, [
      {{key, :"$1"}, [{:"=:=", :"$1", {:const, old}}], [{:const, {key, updated}}]}
    ])
  end

  defp emit(event, token, metadata) do
    {:routing_exploration, profile, chain, workload} = token.key
    {instance, transport} = token.route

    :telemetry.execute(
      [:lasso, :routing, :exploration, event],
      %{count: 1},
      Map.merge(metadata, %{
        profile: profile,
        chain_id: chain,
        workload: workload,
        upstream_instance_id: instance,
        transport: transport,
        generation: token.generation
      })
    )
  end

  defp outcome_kind(%AttemptTerminal.Response{kind: kind}), do: kind
  defp outcome_kind(%AttemptTerminal.Deadline{}), do: :deadline
  defp outcome_kind(%AttemptTerminal.Cancelled{}), do: :cancelled
  defp outcome_kind(%AttemptTerminal.PredispatchFailure{}), do: :predispatch_failure
  defp outcome_kind(%AttemptTerminal.TransportFailure{}), do: :transport_failure
  defp outcome_kind(%AttemptTerminal.InvalidResponse{}), do: :invalid_response
end
