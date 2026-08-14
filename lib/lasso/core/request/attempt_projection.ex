defmodule Lasso.RPC.AttemptProjection do
  @moduledoc false

  alias Lasso.Config.ConfigStore
  alias Lasso.Core.ProjectionDispatcher

  alias Lasso.RPC.{
    AttemptTerminal,
    BoundedIdentifier,
    Channel,
    ExecutionProjector,
    RequestProjection,
    RequestTerminal
  }

  alias Lasso.RPC.ExecutionFact.Codec
  alias Lasso.RPC.RoutingEvidence.{AttemptEvent, Summary}

  @dispatcher Lasso.ExecutionProjectionDispatcher
  @schema :lasso_attempt_projection
  @version 1
  @max_bytes 4_096
  @control_retries 4
  @probation_deliveries 32
  @max_count 9_223_372_036_854_775_807
  @default_workload "default"
  @availability_dimensions [
    {:fastest, :default},
    {:latency_weighted, :default}
  ]

  @enforce_keys [:version, :fact, :provider_id, :method, :emitted_at_us]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          version: 1,
          fact: AttemptTerminal.t(),
          provider_id: binary(),
          method: binary(),
          emitted_at_us: integer()
        }

  @type scope_state :: %{
          profile: binary(),
          chain_id: pos_integer(),
          generation: non_neg_integer(),
          degraded?: boolean(),
          degraded_at_us: integer() | nil,
          recovery_floor_us: integer() | nil,
          probation_remaining: non_neg_integer(),
          publication_loss_generation: non_neg_integer() | nil,
          publication_loss_at_us: integer() | nil,
          stale_drops: non_neg_integer(),
          missing_drops: non_neg_integer(),
          contention_drops: non_neg_integer(),
          availability_degradations: map()
        }

  @spec new(AttemptTerminal.t(), binary(), binary()) :: t()
  def new(fact, provider_id, method) do
    %__MODULE__{
      version: @version,
      fact: fact,
      provider_id: bounded(provider_id),
      method: bounded(method),
      emitted_at_us: System.monotonic_time(:microsecond)
    }
    |> validate!()
  end

  @spec process(t(), atom()) :: {atom(), term()}
  def process(%__MODULE__{} = event, dispatcher \\ @dispatcher) when is_atom(dispatcher) do
    control_result = apply_control(event)
    diagnostic_result = enqueue_diagnostic(event, dispatcher)
    {control_result, diagnostic_result}
  end

  @spec apply_control(t()) :: :ok | :not_dispatched | :stale | :degraded
  def apply_control(%__MODULE__{} = event) do
    apply_control(event, nil)
  end

  @doc false
  @spec apply_control_after_barrier(t(), pid(), reference()) ::
          :ok | :not_dispatched | :stale | :degraded
  def apply_control_after_barrier(%__MODULE__{} = event, observer, release_ref)
      when is_pid(observer) and is_reference(release_ref) do
    apply_control(event, {observer, release_ref})
  end

  defp apply_control(event, barrier) do
    identity = identity(event.fact)
    generation = ConfigStore.route_generation()

    cond do
      identity.route_generation != generation ->
        record_stale(identity, generation, event.emitted_at_us)
        :stale

      match?(%AttemptTerminal.PredispatchFailure{}, event.fact) ->
        :not_dispatched

      true ->
        key = route_key(identity)

        update_route(
          key,
          generation,
          event,
          control_delta(event.fact),
          @control_retries,
          barrier
        )
    end
  rescue
    ArgumentError -> :degraded
  end

  @spec enqueue_diagnostic(t(), atom()) :: term()
  def enqueue_diagnostic(%__MODULE__{} = event, dispatcher \\ @dispatcher)
      when is_atom(dispatcher) do
    if diagnostic_attempt?(event.fact) do
      case encode(event) do
        {:ok, payload} ->
          ProjectionDispatcher.enqueue(dispatcher, :diagnostics, scope(event), payload)

        {:error, reason} ->
          {:drop, reason, :untracked}
      end
    else
      :not_required
    end
  end

  @spec enqueue_request_terminal(RequestTerminal.t(), atom()) :: term()
  def enqueue_request_terminal(fact, dispatcher \\ @dispatcher) when is_atom(dispatcher) do
    identity = request_identity(fact)

    ProjectionDispatcher.enqueue_fact(
      dispatcher,
      :diagnostics,
      {identity.profile, identity.chain_id},
      fact
    )
  end

  @spec encode(t()) :: {:ok, binary()} | {:error, :invalid_event | :event_too_large}
  def encode(%__MODULE__{} = event) do
    payload = :erlang.term_to_binary({@schema, @version, event}, [:deterministic])

    if byte_size(payload) <= @max_bytes,
      do: {:ok, payload},
      else: {:error, :event_too_large}
  rescue
    ArgumentError -> {:error, :invalid_event}
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, atom()}
  def decode(payload) when is_binary(payload) and byte_size(payload) <= @max_bytes do
    case :erlang.binary_to_term(payload, [:safe]) do
      {@schema, @version, %__MODULE__{} = event} -> {:ok, validate!(event)}
      {@schema, version, _event} when is_integer(version) -> {:error, :unsupported_version}
      _other -> {:error, :invalid_event}
    end
  rescue
    ArgumentError -> {:error, :invalid_event}
  end

  def decode(payload) when is_binary(payload), do: {:error, :event_too_large}

  @spec lane_configs() :: keyword()
  def lane_configs do
    configured = Application.get_env(:lasso, :execution_projection_lanes, [])

    [
      diagnostics:
        lane_options(
          &__MODULE__.deliver_diagnostics/2,
          [capacity: 2_048, scope_capacity: 64, max_age_ms: 2_000],
          Keyword.get(configured, :diagnostics, [])
        )
    ]
  end

  @spec scope_state(binary(), pos_integer()) :: scope_state()
  def scope_state(profile, chain_id)
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    generation = ConfigStore.route_generation()
    scope_state(profile, chain_id, generation)
  end

  @doc false
  @spec scope_state(binary(), pos_integer(), non_neg_integer()) :: scope_state()
  def scope_state(profile, chain_id, generation)
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 and
             is_integer(generation) and generation >= 0 do
    key = scope_key(profile, chain_id)

    case :ets.lookup(:lasso_instance_state, key) do
      [{^key, %{generation: ^generation} = state}] -> normalize_scope_state(state)
      _other -> unavailable_scope(profile, chain_id, generation)
    end
  rescue
    ArgumentError -> unavailable_scope(profile, chain_id, generation)
  end

  @spec learned_feedback_degraded?(binary(), pos_integer()) :: boolean()
  def learned_feedback_degraded?(profile, chain_id),
    do: scope_state(profile, chain_id).degraded?

  @spec learned_feedback_floor_us(binary(), pos_integer()) :: integer() | nil
  def learned_feedback_floor_us(profile, chain_id),
    do: scope_state(profile, chain_id).recovery_floor_us

  @spec route_state(scope_state(), binary(), :http | :ws, binary()) :: map() | nil
  def route_state(scope, instance_id, transport, workload_key \\ @default_workload)
      when is_binary(instance_id) and transport in [:http, :ws] and is_binary(workload_key) do
    key =
      {:routing_control, scope.profile, scope.chain_id, BoundedIdentifier.encode(instance_id),
       transport, BoundedIdentifier.encode(workload_key)}

    case :ets.lookup(:lasso_instance_state, key) do
      [{^key, %{generation: generation, observed_at_us: observed_at_us} = row}]
      when generation == scope.generation and is_integer(observed_at_us) ->
        if visible_after_floor?(scope, observed_at_us), do: row

      _other ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  @spec batch_summaries(binary(), [Channel.t() | map()], pos_integer(), atom()) :: map()
  def batch_summaries(profile, channels, chain_id, workload_key) do
    scope = scope_state(profile, chain_id)
    workload = workload_key |> Atom.to_string() |> BoundedIdentifier.encode()

    Map.new(channels, fn channel ->
      key = {channel.instance_id, channel.transport}
      row = route_state(scope, channel.instance_id, channel.transport, workload)
      {key, summary(row, channel.instance_id, channel.transport, chain_id, workload_key)}
    end)
  end

  @doc false
  @spec summarize_route(map() | nil, binary(), :http | :ws, pos_integer(), atom()) ::
          Summary.t() | nil
  def summarize_route(row, instance_id, transport, chain_id, workload_key)
      when is_binary(instance_id) and transport in [:http, :ws] and is_integer(chain_id) and
             chain_id > 0 and is_atom(workload_key) do
    summary(row, instance_id, transport, chain_id, workload_key)
  end

  @spec prepare_routes(non_neg_integer(), [map()]) :: :ok
  def prepare_routes(generation, routes)
      when is_integer(generation) and generation >= 0 and is_list(routes) do
    if ConfigStore.route_generation() == generation do
      {scope_keys, route_keys} = route_keys(routes)

      Enum.each(scope_keys, &publish_scope(&1, generation))
      Enum.each(route_keys, &publish_route(&1, generation))
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec commit_routes(non_neg_integer(), [map()]) :: :ok
  def commit_routes(generation, routes)
      when is_integer(generation) and generation >= 0 and is_list(routes) do
    if ConfigStore.route_generation() == generation do
      {scope_keys, route_keys} = route_keys(routes)
      delete_unpublished_control_rows(scope_keys, route_keys)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec reconcile_routes(non_neg_integer(), [map()]) :: :ok
  def reconcile_routes(generation, routes)
      when is_integer(generation) and generation >= 0 and is_list(routes) do
    prepare_routes(generation, routes)
    commit_routes(generation, routes)
  end

  @doc false
  @spec routes_ready?(non_neg_integer(), [map()]) :: boolean()
  def routes_ready?(generation, routes)
      when is_integer(generation) and generation >= 0 and is_list(routes) do
    {scope_keys, route_keys} = route_keys(routes)

    Enum.all?(MapSet.union(scope_keys, route_keys), fn key ->
      case :ets.lookup(:lasso_instance_state, key) do
        [{^key, %{generation: ^generation}}] -> true
        _other -> false
      end
    end)
  rescue
    ArgumentError -> false
  end

  @spec record_availability_degradation(binary(), pos_integer(), atom(), atom()) ::
          :ok | :stale | :not_tracked
  def record_availability_degradation(profile, chain_id, strategy, workload_key)
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 and is_atom(strategy) and
             is_atom(workload_key) do
    dimension = {strategy, workload_key}

    if dimension in @availability_dimensions do
      generation = ConfigStore.route_generation()

      update_availability_counter(
        scope_key(profile, chain_id),
        generation,
        dimension,
        @control_retries
      )
    else
      :not_tracked
    end
  rescue
    ArgumentError -> :stale
  end

  @spec availability_degradation_count(binary(), pos_integer(), atom(), atom()) ::
          non_neg_integer()
  def availability_degradation_count(profile, chain_id, strategy, workload_key) do
    scope = scope_state(profile, chain_id)
    Map.get(scope.availability_degradations, {strategy, workload_key}, 0)
  end

  @doc false
  @spec deliver_diagnostics(term(), binary()) :: :ok
  def deliver_diagnostics(_scope, payload) do
    case decode(payload) do
      {:ok, event} -> deliver_attempt_diagnostic(event)
      {:error, _reason} -> deliver_request_payload(payload)
    end

    :ok
  end

  @doc false
  @spec to_attempt_event(t()) :: {:ok, AttemptEvent.t()} | :not_dispatched
  def to_attempt_event(%__MODULE__{fact: %AttemptTerminal.PredispatchFailure{}}),
    do: :not_dispatched

  def to_attempt_event(%__MODULE__{} = event) do
    identity = identity(event.fact)
    fields = attempt_event_fields(event.fact)

    {:ok,
     struct!(AttemptEvent,
       request_id: identity.request_id,
       upstream_instance_id: identity.upstream_instance_id,
       chain_id: identity.chain_id,
       provider_id: event.provider_id,
       transport: identity.transport,
       workload_key: :default,
       observed_at_ms: div(event.emitted_at_us, 1_000),
       outcome: fields.outcome,
       elapsed_io_ms: Map.get(fields, :elapsed_io_ms),
       censoring_boundary_ms: Map.get(fields, :censoring_boundary_ms),
       error_category: Map.get(fields, :error_category)
     )}
  end

  defp update_route(key, generation, event, delta, retries, barrier) when retries > 0 do
    if ConfigStore.route_generation() == generation do
      do_update_route(key, generation, event, delta, retries, barrier)
    else
      record_stale(identity(event.fact), ConfigStore.route_generation(), event.emitted_at_us)
      :stale
    end
  end

  defp update_route(_key, _generation, event, _delta, 0, _barrier) do
    degrade_scope(identity(event.fact), event.emitted_at_us, :contention_drops)

    :degraded
  end

  defp do_update_route(key, generation, event, delta, retries, barrier) do
    case :ets.lookup(:lasso_instance_state, key) do
      [{^key, %{generation: ^generation} = current}] ->
        updated = apply_delta(current, event, delta)
        await_control_barrier(barrier)

        case replace_exact(key, current, updated) do
          1 ->
            if ConfigStore.route_generation() == generation do
              if delta.kind == :success do
                advance_scope(identity(event.fact), event.emitted_at_us, @control_retries)
              end

              :ok
            else
              record_stale(
                identity(event.fact),
                ConfigStore.route_generation(),
                event.emitted_at_us
              )

              :stale
            end

          0 ->
            update_route(key, generation, event, delta, retries - 1, nil)
        end

      _other ->
        record_missing(identity(event.fact), generation, event.emitted_at_us)
        :stale
    end
  end

  defp await_control_barrier(nil), do: :ok

  defp await_control_barrier({observer, release_ref}) do
    send(observer, {:attempt_projection_before_cas, self(), release_ref})

    receive do
      ^release_ref -> :ok
    end
  end

  defp apply_delta(current, event, delta) do
    delta = Map.put(delta, :observed_at_us, event.emitted_at_us)

    current
    |> Map.put(:revision, increment(current.revision))
    |> Map.put(:observed_at_us, max_floor(current.observed_at_us, event.emitted_at_us))
    |> Map.put(
      :oldest_observed_at_us,
      min_observation(current.oldest_observed_at_us, event.emitted_at_us)
    )
    |> Map.put(:comparable_attempts, increment(current.comparable_attempts))
    |> apply_aggregate(delta)
    |> apply_latest_state(event.emitted_at_us, delta)
  end

  defp apply_aggregate(row, %{kind: :success, latency_ms: latency_ms}) do
    successes = increment(row.usable_successes)
    old_count = max(row.usable_successes, 0)

    mean =
      if old_count == 0,
        do: latency_ms,
        else:
          row.successful_mean_latency_ms +
            (latency_ms - row.successful_mean_latency_ms) / successes

    %{
      row
      | usable_successes: successes,
        successful_mean_latency_ms: mean,
        successful_p95_latency_ms: nil
    }
  end

  defp apply_aggregate(row, %{kind: :failure}),
    do: %{row | total_failures: increment(row.total_failures)}

  defp apply_aggregate(row, %{kind: :rate_limit, retry_after_ms: retry_after_ms} = delta) do
    observed_at_us = Map.fetch!(delta, :observed_at_us)
    expiry_ms = div(observed_at_us, 1_000) + retry_after_ms
    replace_expiry? = expiry_ms >= row.rate_limit_expiry_ms

    %{
      row
      | rate_limit_expiry_ms: max(row.rate_limit_expiry_ms, expiry_ms),
        rate_limit_retry_after_ms:
          if(replace_expiry?, do: retry_after_ms, else: row.rate_limit_retry_after_ms),
        rate_limit_observed_at_us: max_floor(row.rate_limit_observed_at_us, observed_at_us),
        total_rate_limits: increment(row.total_rate_limits)
    }
  end

  defp apply_aggregate(row, %{kind: :neutral}), do: row

  defp apply_latest_state(row, emitted_at_us, delta) do
    if is_nil(row.state_observed_at_us) or emitted_at_us >= row.state_observed_at_us do
      row
      |> Map.put(:state_observed_at_us, emitted_at_us)
      |> apply_latest_outcome(delta)
    else
      row
    end
  end

  defp apply_latest_outcome(row, %{kind: :success}) do
    %{
      row
      | status: :healthy,
        consecutive_failures: 0,
        consecutive_successes: increment(row.consecutive_successes),
        last_error_category: nil
    }
  end

  defp apply_latest_outcome(row, %{kind: :failure, category: category}) do
    failures = increment(row.consecutive_failures)

    %{
      row
      | status: if(failures >= 3, do: :unhealthy, else: :degraded),
        consecutive_failures: failures,
        consecutive_successes: 0,
        last_error_category: category
    }
  end

  defp apply_latest_outcome(row, %{kind: :rate_limit}),
    do: %{row | last_error_category: :rate_limit}

  defp apply_latest_outcome(row, %{kind: :neutral}), do: row

  defp control_delta(%AttemptTerminal.Response{kind: :success, io_duration_us: us}),
    do: %{kind: :success, latency_ms: us / 1_000}

  defp control_delta(%AttemptTerminal.Response{error_category: :quota} = fact),
    do: %{kind: :rate_limit, retry_after_ms: fact.retry_after_ms || 30_000}

  defp control_delta(%AttemptTerminal.Response{error_category: :provider_failure}),
    do: %{kind: :failure, category: :server_error}

  defp control_delta(%AttemptTerminal.InvalidResponse{}),
    do: %{kind: :failure, category: :protocol_error}

  defp control_delta(%AttemptTerminal.TransportFailure{dispatch_certainty: :dispatched} = fact),
    do: %{kind: :failure, category: transport_category(fact.reason)}

  defp control_delta(%AttemptTerminal.Deadline{dispatch_certainty: :dispatched}),
    do: %{kind: :failure, category: :timeout}

  defp control_delta(_fact), do: %{kind: :neutral}

  defp advance_scope(identity, emitted_at_us, retries) when retries > 0 do
    key = scope_key(identity.profile, identity.chain_id)

    case :ets.lookup(:lasso_instance_state, key) do
      [{^key, %{generation: generation, degraded_at_us: degraded_at_us} = current}]
      when generation == identity.route_generation and is_integer(degraded_at_us) and
             emitted_at_us > degraded_at_us ->
        updated = advance_probation(current)

        case replace_exact(key, current, updated) do
          1 -> :ok
          0 -> advance_scope(identity, emitted_at_us, retries - 1)
        end

      _other ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp advance_scope(identity, emitted_at_us, 0) do
    degrade_scope(identity, emitted_at_us, :contention_drops)
  end

  defp advance_probation(%{probation_remaining: 1} = state) do
    %{
      state
      | degraded?: false,
        recovery_floor_us: max_floor(state.recovery_floor_us, state.degraded_at_us),
        degraded_at_us: nil,
        probation_remaining: 0,
        publication_loss_generation: nil,
        publication_loss_at_us: nil
    }
  end

  defp advance_probation(%{probation_remaining: remaining} = state) when remaining > 1,
    do: %{state | probation_remaining: remaining - 1}

  defp advance_probation(state), do: state

  defp degrade_scope(identity, emitted_at_us, counter) do
    key = scope_key(identity.profile, identity.chain_id)
    degrade_scope_key(key, identity.route_generation, emitted_at_us, counter, @control_retries)
  rescue
    ArgumentError -> :ok
  end

  defp record_stale(identity, current_generation, emitted_at_us) do
    degrade_scope_key(
      scope_key(identity.profile, identity.chain_id),
      current_generation,
      emitted_at_us,
      :stale_drops,
      @control_retries
    )

    update_counter(route_key(identity), current_generation, :stale_drops, @control_retries)
    :ok
  end

  defp record_missing(identity, generation, emitted_at_us) do
    if generation == identity.route_generation,
      do:
        degrade_scope_key(
          scope_key(identity.profile, identity.chain_id),
          generation,
          emitted_at_us,
          :missing_drops,
          @control_retries
        )

    :ok
  end

  defp degrade_scope_key(key, generation, emitted_at_us, counter, retries) when retries > 0 do
    case :ets.lookup(:lasso_instance_state, key) do
      [{^key, %{generation: ^generation} = current}] ->
        updated =
          current
          |> Map.merge(%{
            degraded?: true,
            degraded_at_us: max_floor(current.degraded_at_us, emitted_at_us),
            probation_remaining: @probation_deliveries,
            publication_loss_generation:
              max_floor(Map.get(current, :publication_loss_generation), generation),
            publication_loss_at_us:
              max_floor(Map.get(current, :publication_loss_at_us), emitted_at_us)
          })
          |> Map.update(counter, 1, &increment/1)

        case replace_exact(key, current, updated) do
          1 -> :ok
          0 -> degrade_scope_key(key, generation, emitted_at_us, counter, retries - 1)
        end

      [{^key, current}] ->
        updated =
          current
          |> Map.put(
            :publication_loss_generation,
            max_floor(Map.get(current, :publication_loss_generation), generation)
          )
          |> Map.put(
            :publication_loss_at_us,
            max_floor(Map.get(current, :publication_loss_at_us), emitted_at_us)
          )
          |> Map.update(counter, 1, &increment/1)

        case replace_exact(key, current, updated) do
          1 -> :ok
          0 -> degrade_scope_key(key, generation, emitted_at_us, counter, retries - 1)
        end

      [] ->
        :ok
    end
  end

  defp degrade_scope_key(_key, _generation, _emitted_at_us, _counter, 0), do: :ok

  defp update_counter(key, generation, counter, retries) when retries > 0 do
    case :ets.lookup(:lasso_instance_state, key) do
      [{^key, %{generation: ^generation} = current}] ->
        updated = Map.update!(current, counter, &increment/1)

        case replace_exact(key, current, updated) do
          1 -> :ok
          0 -> update_counter(key, generation, counter, retries - 1)
        end

      _other ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp update_counter(_key, _generation, _counter, 0), do: :ok

  defp update_availability_counter(key, generation, dimension, retries) when retries > 0 do
    case :ets.lookup(:lasso_instance_state, key) do
      [{^key, %{generation: ^generation} = current}] ->
        counts = Map.fetch!(current, :availability_degradations)
        updated_counts = Map.update!(counts, dimension, &increment/1)
        updated = %{current | availability_degradations: updated_counts}

        case replace_exact(key, current, updated) do
          1 ->
            if ConfigStore.route_generation() == generation, do: :ok, else: :stale

          0 ->
            update_availability_counter(key, generation, dimension, retries - 1)
        end

      _other ->
        :stale
    end
  end

  defp update_availability_counter(_key, _generation, _dimension, 0), do: :stale

  defp publish_scope({:routing_control_scope, profile, chain_id} = key, generation) do
    case :ets.lookup(:lasso_instance_state, key) do
      [{^key, %{generation: ^generation}}] ->
        :ok

      [{^key, current}] ->
        replacement = published_scope(profile, chain_id, generation, current)

        if replace_exact(key, current, replacement) == 0,
          do: publish_scope(key, generation)

      [] ->
        if not :ets.insert_new(
             :lasso_instance_state,
             {key, default_scope(profile, chain_id, generation)}
           ),
           do: publish_scope(key, generation)
    end
  end

  defp publish_route(key, generation) do
    case :ets.lookup(:lasso_instance_state, key) do
      [{^key, %{generation: ^generation}}] ->
        :ok

      [{^key, current}] ->
        if replace_exact(key, current, default_route(generation)) == 0,
          do: publish_route(key, generation)

      [] ->
        if not :ets.insert_new(:lasso_instance_state, {key, default_route(generation)}),
          do: publish_route(key, generation)
    end
  end

  defp published_scope(profile, chain_id, generation, current) do
    scope = default_scope(profile, chain_id, generation)

    if is_integer(Map.get(current, :publication_loss_generation)) and
         current.publication_loss_generation <= generation do
      %{
        scope
        | degraded?: true,
          degraded_at_us:
            Map.get(current, :publication_loss_at_us) || System.monotonic_time(:microsecond),
          probation_remaining: @probation_deliveries,
          publication_loss_generation: current.publication_loss_generation,
          publication_loss_at_us: Map.get(current, :publication_loss_at_us),
          stale_drops: Map.get(current, :stale_drops, 0),
          missing_drops: Map.get(current, :missing_drops, 0),
          contention_drops: Map.get(current, :contention_drops, 0)
      }
    else
      scope
    end
  end

  defp delete_unpublished_control_rows(scope_keys, route_keys) do
    scope_rows =
      :ets.match_object(:lasso_instance_state, {{:routing_control_scope, :_, :_}, :_})

    Enum.each(scope_rows, fn {key, _state} ->
      unless MapSet.member?(scope_keys, key), do: :ets.delete(:lasso_instance_state, key)
    end)

    route_rows =
      :ets.match_object(
        :lasso_instance_state,
        {{:routing_control, :_, :_, :_, :_, :_}, :_}
      )

    Enum.each(route_rows, fn {key, _state} ->
      unless MapSet.member?(route_keys, key), do: :ets.delete(:lasso_instance_state, key)
    end)
  end

  defp default_scope(profile, chain_id, generation) do
    %{
      profile: BoundedIdentifier.encode(profile),
      chain_id: chain_id,
      generation: generation,
      degraded?: false,
      degraded_at_us: nil,
      recovery_floor_us: nil,
      probation_remaining: 0,
      publication_loss_generation: nil,
      publication_loss_at_us: nil,
      stale_drops: 0,
      missing_drops: 0,
      contention_drops: 0,
      availability_degradations: Map.new(@availability_dimensions, &{&1, 0})
    }
  end

  defp unavailable_scope(profile, chain_id, generation) do
    %{
      default_scope(profile, chain_id, generation)
      | degraded?: true,
        degraded_at_us: System.monotonic_time(:microsecond),
        probation_remaining: @probation_deliveries,
        missing_drops: 1
    }
  end

  defp normalize_scope_state(state) do
    %{
      profile: state.profile,
      chain_id: state.chain_id,
      generation: state.generation,
      degraded?: state.degraded?,
      degraded_at_us: state.degraded_at_us,
      recovery_floor_us: state.recovery_floor_us,
      probation_remaining: state.probation_remaining,
      publication_loss_generation: Map.get(state, :publication_loss_generation),
      publication_loss_at_us: Map.get(state, :publication_loss_at_us),
      stale_drops: Map.get(state, :stale_drops, 0),
      missing_drops: Map.get(state, :missing_drops, 0),
      contention_drops: Map.get(state, :contention_drops, 0),
      availability_degradations:
        Map.get(
          state,
          :availability_degradations,
          Map.new(@availability_dimensions, &{&1, 0})
        )
    }
  end

  defp default_route(generation) do
    %{
      generation: generation,
      revision: 0,
      observed_at_us: nil,
      oldest_observed_at_us: nil,
      state_observed_at_us: nil,
      status: nil,
      consecutive_failures: 0,
      consecutive_successes: 0,
      last_error_category: nil,
      rate_limit_expiry_ms: 0,
      rate_limit_retry_after_ms: nil,
      rate_limit_observed_at_us: nil,
      comparable_attempts: 0,
      usable_successes: 0,
      total_failures: 0,
      total_rate_limits: 0,
      successful_mean_latency_ms: nil,
      successful_p95_latency_ms: nil,
      stale_drops: 0,
      missing_drops: 0,
      contention_drops: 0
    }
  end

  defp route_keys(routes) do
    scope_keys =
      routes
      |> Enum.map(&scope_key(&1.profile, &1.chain_id))
      |> MapSet.new()

    route_keys =
      routes
      |> Enum.map(fn route ->
        {:routing_control, BoundedIdentifier.encode(route.profile), route.chain_id,
         BoundedIdentifier.encode(route.instance_id), route.transport, @default_workload}
      end)
      |> MapSet.new()

    {scope_keys, route_keys}
  end

  defp scope_key(profile, chain_id),
    do: {:routing_control_scope, BoundedIdentifier.encode(profile), chain_id}

  defp route_key(identity) do
    {:routing_control, identity.profile, identity.chain_id, identity.upstream_instance_id,
     identity.transport, identity.workload_key}
  end

  defp replace_exact(key, current, updated) do
    :ets.select_replace(
      :lasso_instance_state,
      [{{key, current}, [], [{:const, {key, updated}}]}]
    )
  end

  defp visible_after_floor?(%{degraded?: true}, _observed_at_us), do: false
  defp visible_after_floor?(%{recovery_floor_us: nil}, _observed_at_us), do: true

  defp visible_after_floor?(%{recovery_floor_us: floor_us}, observed_at_us),
    do: observed_at_us > floor_us

  defp summary(nil, _instance_id, _transport, _chain_id, _workload_key), do: nil

  defp summary(row, instance_id, transport, chain_id, workload_key) do
    state =
      cond do
        row.usable_successes >= 3 and row.consecutive_failures < 3 -> :qualified
        row.comparable_attempts > 0 -> :provisional
        true -> :unqualified
      end

    %Summary{
      upstream_instance_id: instance_id,
      chain_id: chain_id,
      transport: transport,
      workload_key: workload_key,
      state: state,
      comparable_attempts: row.comparable_attempts,
      usable_successes: row.usable_successes,
      successful_mean_latency_ms: row.successful_mean_latency_ms,
      successful_p95_latency_ms: row.successful_p95_latency_ms,
      last_observed_at_ms: div(row.observed_at_us, 1_000),
      oldest_observed_at_ms: div(row.oldest_observed_at_us, 1_000),
      support_source: :request_terminal,
      generation: row.generation
    }
  end

  defp diagnostic_attempt?(%AttemptTerminal.Response{kind: :success}), do: false
  defp diagnostic_attempt?(_fact), do: true

  defp deliver_attempt_diagnostic(event) do
    with {:ok, attempt_event} <- to_attempt_event(event) do
      duration_ms = attempt_event.elapsed_io_ms || attempt_event.censoring_boundary_ms

      :telemetry.execute(
        [:lasso, :rpc, :attempt, :terminal],
        %{count: 1, duration_ms: duration_ms},
        %{
          request_id: attempt_event.request_id,
          upstream_instance_id: attempt_event.upstream_instance_id,
          chain_id: attempt_event.chain_id,
          provider_id: attempt_event.provider_id,
          transport: attempt_event.transport,
          outcome: attempt_event.outcome,
          error_category: attempt_event.error_category
        }
      )
    end
  end

  defp deliver_request_payload(payload) do
    case RequestProjection.decode(payload) do
      {:ok, event} ->
        RequestProjection.deliver(event)

      {:error, _reason} ->
        deliver_legacy_request_payload(payload)
    end
  end

  defp deliver_legacy_request_payload(payload) do
    with {:ok, request_terminal} <- Codec.decode(payload) do
      projection = ExecutionProjector.project(request_terminal)
      identity = request_identity(request_terminal)

      :telemetry.execute(
        [:lasso, :rpc, :request, :terminal],
        %{count: 1, elapsed_us: Map.get(request_terminal, :elapsed_us, 0)},
        %{
          request_id: request_id(request_terminal),
          profile: identity.profile,
          chain_id: identity.chain_id,
          diagnostic: projection.diagnostic,
          candidate_admission_count: Map.get(request_terminal, :candidate_admission_count, 0),
          dispatch_count: Map.get(request_terminal, :dispatch_count, 0)
        }
      )
    end
  end

  defp attempt_event_fields(%AttemptTerminal.Response{kind: :success, io_duration_us: us}),
    do: %{outcome: :usable_success, elapsed_io_ms: us / 1_000, error_category: nil}

  defp attempt_event_fields(%AttemptTerminal.Response{error_category: :quota, io_duration_us: us}),
    do: %{outcome: :capacity_rejection, elapsed_io_ms: us / 1_000, error_category: :rate_limit}

  defp attempt_event_fields(%AttemptTerminal.Response{
         error_category: category,
         io_duration_us: us
       }),
       do: %{outcome: :neutral_error, elapsed_io_ms: us / 1_000, error_category: category}

  defp attempt_event_fields(%AttemptTerminal.InvalidResponse{io_duration_us: us}),
    do: %{outcome: :service_failure, elapsed_io_ms: us / 1_000, error_category: :protocol_error}

  defp attempt_event_fields(%AttemptTerminal.TransportFailure{reason: reason, io_duration_us: us}),
    do: %{
      outcome: :service_failure,
      elapsed_io_ms: duration_ms(us),
      error_category: transport_category(reason)
    }

  defp attempt_event_fields(%AttemptTerminal.Deadline{censoring_boundary_us: us}),
    do: %{outcome: :timeout, censoring_boundary_ms: us / 1_000, error_category: :timeout}

  defp attempt_event_fields(%AttemptTerminal.Cancelled{censoring_boundary_us: us}),
    do: %{outcome: :cancelled, censoring_boundary_ms: us / 1_000, error_category: :cancelled}

  defp duration_ms(nil), do: nil
  defp duration_ms(us), do: us / 1_000

  defp transport_category(:timeout), do: :timeout

  defp transport_category(reason) when reason in [:connection, :closed, :tls, :dns],
    do: :network_error

  defp transport_category(:local_capacity), do: :local_capacity_rejection
  defp transport_category(_reason), do: :server_error

  defp lane_options(sink, defaults, configured) do
    capacity = Keyword.fetch!(defaults, :capacity)
    scope_capacity = Keyword.fetch!(defaults, :scope_capacity)

    [
      capacity: capacity,
      byte_capacity: capacity * @max_bytes,
      scope_capacity: scope_capacity,
      scope_byte_capacity: scope_capacity * @max_bytes,
      shards: 4,
      max_age_ms: Keyword.fetch!(defaults, :max_age_ms),
      audit_interval_ms: 1_000,
      sink: sink
    ]
    |> Keyword.merge(configured)
    |> Keyword.put(:sink, sink)
  end

  defp validate!(%__MODULE__{} = event) do
    valid? =
      event.version == @version and
        event.provider_id == bounded(event.provider_id) and
        event.method == bounded(event.method) and
        is_integer(event.emitted_at_us) and is_struct(event.fact)

    if valid?, do: event, else: raise(ArgumentError, "invalid attempt projection")
  end

  defp bounded(value) when is_binary(value), do: BoundedIdentifier.encode(value)
  defp bounded(_value), do: raise(ArgumentError, "projection dimensions must be strings")

  defp identity(%{identity: identity}), do: identity

  defp request_identity(%RequestTerminal.UpstreamResponse{attempt: attempt}),
    do: attempt.identity

  defp request_identity(fact), do: %{profile: fact.profile, chain_id: fact.chain_id}

  defp scope(event) do
    identity = identity(event.fact)
    {identity.profile, identity.chain_id}
  end

  defp request_id(%RequestTerminal.UpstreamResponse{attempt: attempt}),
    do: attempt.identity.request_id

  defp request_id(fact), do: fact.request_id

  defp increment(value) when value < @max_count, do: value + 1
  defp increment(value), do: value

  defp max_floor(nil, value), do: value
  defp max_floor(value, nil), do: value
  defp max_floor(left, right), do: max(left, right)

  defp min_observation(nil, value), do: value
  defp min_observation(value, nil), do: value
  defp min_observation(left, right), do: min(left, right)
end
