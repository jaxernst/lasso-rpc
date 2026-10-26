defmodule Lasso.RPC.RequestContext do
  @moduledoc """
  Tracks request lifecycle data for rpc request pipeline observability and client-visible metadata.

  This struct threads through the request pipeline to collect:
  - Request identification and timing
  - Provider selection details
  - Routing decisions and circuit breaker states
  - Channel execution history
  - Result or error shapes
  """

  alias Lasso.JSONRPC.Error, as: JError

  alias Lasso.RPC.{
    AttemptTerminal,
    BoundedIdentifier,
    Channel,
    ExecutionEnvelope,
    PreparedRequest,
    RequestOptions,
    Response
  }

  @type channel_identity :: %{
          profile: binary(),
          provider_id: binary(),
          instance_id: binary() | nil,
          transport: :http | :ws,
          route_generation: non_neg_integer()
        }
  @type channel_attempt :: %{
          optional(:exhaustion_category) => atom(),
          channel: channel_identity(),
          outcome: :success | :error,
          category: atom() | nil,
          code: integer() | nil
        }

  @type t :: %__MODULE__{
          # Request identification
          request_id: String.t(),
          account_id: String.t() | nil,
          chain_id: pos_integer(),
          method: String.t(),
          params: list() | map(),
          transport: :http | :ws,
          strategy: atom(),
          path: String.t() | nil,
          client_ip: String.t() | nil,
          user_agent: String.t() | nil,

          # Routing
          requested_profile: String.t() | nil,
          service_profile: String.t() | nil,
          effective_profile: String.t() | nil,
          routing_profile: String.t() | nil,
          fallback_depth: non_neg_integer(),
          fallback_reason: atom() | nil,
          visited_profiles: %{optional(String.t()) => true},
          attempted_instance_transports: %{
            optional({String.t(), :http | :ws}) => true
          },
          phase_attempt_count: non_neg_integer(),
          candidate_providers: [String.t()],
          selected_provider: %{id: String.t(), protocol: :http | :ws} | nil,
          selection_reason: String.t() | nil,
          selection_latency_ms: float() | nil,
          retries: non_neg_integer(),
          circuit_breaker_state: :open | :half_open | :closed | nil,
          routing_capacity: :customer_owned | :lasso_public_shared | nil,
          shared_capacity_denials: non_neg_integer(),
          # Track repeated error categories to detect universal failures
          repeated_error_categories: %{atom() => non_neg_integer()},

          # Channel execution tracking (for observability without polluting return types)
          executed_channel: channel_identity() | nil,
          attempted_channels: [channel_attempt()],
          # Full error retained for a terminal upstream answer.
          last_attempt_error: JError.t() | nil,
          # An upstream's eth_getLogs range or result limit. Other upstreams may
          # accept the range, so it is returned only once none of them did.
          log_range_error: JError.t() | nil,
          claim_audit: Lasso.Core.Support.ClaimAudit.State.t() | nil,
          template_attempts: [map()],
          shadow_predictions: map(),
          learning_decision: map() | nil,
          block_facts: Lasso.RPC.RequestAnalysis.block_facts(),
          request_facts: Lasso.RPC.RequestFacts.t() | nil,
          null_recovery: Lasso.RPC.NullRecovery.State.t() | nil,
          missing_block: %{original?: boolean(), missing: map() | nil},
          attempt_observation: map() | nil,

          # Timing
          # Plug-level start time for true E2E measurement (from RequestTimingPlug)
          plug_start_time: integer() | nil,

          # Pipeline-level start time (fallback if plug timing not available)
          start_time: integer(),
          request_start_ms: integer() | nil,
          selection_start: integer() | nil,
          selection_end: integer() | nil,
          upstream_start: integer() | nil,
          upstream_end: integer() | nil,

          # TRUE upstream provider I/O time (HTTP/WS send→receive at transport boundary)
          upstream_latency_ms: float() | nil,
          end_to_end_latency_ms: float() | nil,

          # Computed: end_to_end - upstream = Lasso internal overhead
          lasso_overhead_ms: float() | nil,

          # Response
          status: :success | :error | nil,
          result_type: String.t() | nil,
          result_size_bytes: non_neg_integer() | nil,
          error: map() | nil,

          # Execution parameters (immutable throughout pipeline)
          rpc_request: map() | nil,
          prepared_request: PreparedRequest.t() | nil,
          head_policy: map() | nil,
          timeout_ms: timeout() | nil,
          execution_envelope: ExecutionEnvelope.t() | nil,
          opts: RequestOptions.t() | nil,
          terminal_attempt_fact: struct() | nil,
          terminal_attempt_channel: channel_identity() | nil,
          terminal_attempt_projection: struct() | nil,
          public_response_attempt: struct() | nil,
          request_dispatch_certainty: :not_dispatched | :indeterminate | :dispatched,
          terminal_reason: atom() | nil,

          # Set when declared parameter limits eliminate every candidate so the
          # safety retry dispatches instead of failing the request outright.
          bypass_param_limits: boolean()
        }

  defstruct request_id: nil,
            exploration_token: nil,
            account_id: nil,
            chain_id: nil,
            method: nil,
            params: [],
            transport: :http,
            strategy: nil,
            path: nil,
            client_ip: nil,
            user_agent: nil,
            requested_profile: nil,
            service_profile: nil,
            effective_profile: nil,
            routing_profile: nil,
            fallback_depth: 0,
            fallback_reason: nil,
            visited_profiles: %{},
            attempted_instance_transports: %{},
            phase_attempt_count: 0,
            candidate_providers: [],
            selected_provider: nil,
            selection_reason: nil,
            selection_latency_ms: nil,
            retries: 0,
            circuit_breaker_state: nil,
            routing_capacity: nil,
            shared_capacity_denials: 0,
            repeated_error_categories: %{},
            executed_channel: nil,
            attempted_channels: [],
            last_attempt_error: nil,
            log_range_error: nil,
            claim_audit: nil,
            template_attempts: [],
            shadow_predictions: %{},
            learning_decision: nil,
            request_facts: nil,
            block_facts: nil,
            null_recovery: nil,
            missing_block: %{original?: false, missing: nil},
            attempt_observation: nil,
            plug_start_time: nil,
            start_time: nil,
            request_start_ms: nil,
            selection_start: nil,
            selection_end: nil,
            upstream_start: nil,
            upstream_end: nil,
            upstream_latency_ms: nil,
            end_to_end_latency_ms: nil,
            lasso_overhead_ms: nil,
            status: nil,
            result_type: nil,
            result_size_bytes: nil,
            error: nil,
            rpc_request: nil,
            prepared_request: nil,
            head_policy: nil,
            timeout_ms: nil,
            execution_envelope: nil,
            opts: nil,
            terminal_attempt_fact: nil,
            terminal_attempt_channel: nil,
            terminal_attempt_projection: nil,
            public_response_attempt: nil,
            request_dispatch_certainty: :not_dispatched,
            terminal_reason: nil,
            bypass_param_limits: false

  @doc """
  Creates a new request context with request_id and start_time.

  If :request_id is provided in opts, it will be used (typically from Phoenix's Plug.RequestId).
  Otherwise, a new request_id will be generated.
  """
  @spec new(pos_integer(), String.t(), list() | map(), keyword() | RequestOptions.t()) :: t()
  def new(chain_id, method, params, opts \\ [])

  def new(chain_id, method, params, opts) when is_list(opts) do
    request_id =
      bounded_request_id(Keyword.get(opts, :request_id) || Logger.metadata()[:request_id])

    plug_start = Keyword.get(opts, :plug_start_time)
    start_time = plug_start || System.monotonic_time(:microsecond)

    %__MODULE__{
      request_id: request_id,
      account_id: Keyword.get(opts, :account_id),
      chain_id: chain_id,
      method: method,
      params: params,
      transport: Keyword.get(opts, :transport, :http),
      strategy: Keyword.get(opts, :strategy),
      requested_profile: Keyword.get(opts, :requested_profile),
      path: Keyword.get(opts, :path),
      client_ip: Keyword.get(opts, :client_ip),
      user_agent: Keyword.get(opts, :user_agent),
      plug_start_time: plug_start,
      start_time: start_time
    }
  end

  def new(chain_id, method, params, %RequestOptions{} = opts) do
    plug_start = opts.plug_start_time

    %__MODULE__{
      request_id: bounded_request_id(opts.request_id),
      account_id: opts.account_id,
      chain_id: chain_id,
      method: method,
      params: params,
      transport: opts.transport || :http,
      strategy: opts.strategy,
      requested_profile: opts.requested_profile,
      plug_start_time: plug_start,
      start_time: plug_start || System.monotonic_time(:microsecond)
    }
  end

  @doc "Moves request execution into a bounded fallback profile phase."
  @spec enter_fallback(t(), String.t(), atom()) :: t()
  def enter_fallback(%__MODULE__{} = ctx, profile, reason) when is_binary(profile) do
    %{
      ctx
      | routing_profile: profile,
        effective_profile: profile,
        fallback_depth: ctx.fallback_depth + 1,
        fallback_reason: reason,
        visited_profiles: Map.put(ctx.visited_profiles, profile, true),
        phase_attempt_count: 0,
        bypass_param_limits: false,
        execution_envelope: ExecutionEnvelope.enter_fallback_phase(ctx.execution_envelope)
    }
  end

  @doc "Stores the prepared request while keeping it eligible for explicit release at closure."
  @spec set_prepared_request(t(), PreparedRequest.t()) :: t()
  def set_prepared_request(%__MODULE__{} = ctx, %PreparedRequest{} = prepared_request) do
    %{ctx | prepared_request: prepared_request}
  end

  @doc "Normalizes the request identifier to the bounded execution identity contract."
  @spec bound_request_id(t()) :: t()
  def bound_request_id(%__MODULE__{} = ctx),
    do: %{ctx | request_id: bounded_request_id(ctx.request_id)}

  @doc """
  Sets the execution parameters for pipeline processing.

  These are immutable throughout the pipeline execution:
  - rpc_request: The JSON-RPC request map being executed
  - timeout_ms: Total request-envelope timeout in milliseconds
  - opts: The RequestOptions struct with routing configuration
  """
  @spec set_execution_params(t(), map(), integer(), RequestOptions.t()) :: t()
  def set_execution_params(%__MODULE__{} = ctx, rpc_request, timeout_ms, %RequestOptions{} = opts)
      when is_map(rpc_request) and is_integer(timeout_ms) do
    set_execution_params(ctx, rpc_request, timeout_ms, opts, nil)
  end

  @doc "Installs the immutable inputs and deadline used by request-owned execution."
  @spec set_execution_params(t(), map(), integer(), RequestOptions.t(), integer() | nil) :: t()
  def set_execution_params(
        %__MODULE__{} = ctx,
        rpc_request,
        timeout_ms,
        %RequestOptions{} = opts,
        deadline_us
      )
      when is_map(rpc_request) and is_integer(timeout_ms) do
    ctx
    |> bound_request_id()
    |> put_execution_params(rpc_request, timeout_ms, opts, deadline_us)
  end

  @doc false
  @spec initialize_execution(t(), map(), integer(), RequestOptions.t(), integer() | nil) :: t()
  def initialize_execution(
        %__MODULE__{} = ctx,
        rpc_request,
        timeout_ms,
        %RequestOptions{} = opts,
        deadline_us
      )
      when is_map(rpc_request) and is_integer(timeout_ms) do
    put_execution_params(ctx, rpc_request, timeout_ms, opts, deadline_us)
  end

  defp put_execution_params(ctx, rpc_request, timeout_ms, opts, deadline_us) do
    requested_profile = opts.requested_profile || opts.profile
    routing_profile = ctx.routing_profile || opts.profile

    envelope =
      case ctx.execution_envelope do
        %ExecutionEnvelope{} = envelope ->
          ExecutionEnvelope.cap_deadline(envelope, deadline_us)

        nil ->
          ExecutionEnvelope.new(ctx.request_id, ctx.method, timeout_ms,
            started_at_us: ctx.start_time || System.monotonic_time(:microsecond),
            deadline_us: deadline_us
          )
      end

    %{
      ctx
      | rpc_request: rpc_request,
        timeout_ms: timeout_ms,
        opts: opts,
        requested_profile: ctx.requested_profile || requested_profile,
        service_profile: opts.profile,
        effective_profile: ctx.effective_profile || routing_profile,
        routing_profile: routing_profile,
        visited_profiles: Map.put(ctx.visited_profiles, routing_profile, true),
        execution_envelope: envelope
    }
  end

  @doc """
  Records the start of provider selection phase.
  """
  @spec mark_selection_start(t()) :: t()
  def mark_selection_start(%__MODULE__{} = ctx) do
    %{ctx | selection_start: System.monotonic_time(:microsecond)}
  end

  @doc """
  Records provider selection completion with metadata.
  """
  @spec mark_selection_end(t(), keyword()) :: t()
  def mark_selection_end(%__MODULE__{} = ctx, opts \\ []) do
    now = System.monotonic_time(:microsecond)

    selection_latency_ms =
      if ctx.selection_start do
        (now - ctx.selection_start) / 1000.0
      else
        nil
      end

    %{
      ctx
      | selection_end: now,
        selection_latency_ms: selection_latency_ms,
        candidate_providers: Keyword.get(opts, :candidates, ctx.candidate_providers),
        selected_provider:
          normalize_selected_provider(Keyword.get(opts, :selected, ctx.selected_provider)),
        selection_reason: Keyword.get(opts, :reason, ctx.selection_reason),
        circuit_breaker_state: Keyword.get(opts, :cb_state, ctx.circuit_breaker_state)
    }
  end

  @doc """
  Records the start of upstream request.
  """
  @spec mark_upstream_start(t()) :: t()
  def mark_upstream_start(%__MODULE__{} = ctx) do
    %{ctx | upstream_start: System.monotonic_time(:microsecond)}
  end

  @doc """
  Records upstream request completion.

  Note: This calculates timing from mark_upstream_start to now, but the actual
  upstream_latency_ms should be set via set_upstream_latency/2 with the measured
  I/O time from the transport layer for accuracy.
  """
  @spec mark_upstream_end(t()) :: t()
  def mark_upstream_end(%__MODULE__{} = ctx) do
    now = System.monotonic_time(:microsecond)
    %{ctx | upstream_end: now}
  end

  @doc """
  Adds upstream I/O latency measured at the transport boundary (HTTP/WS send→receive).

  On failover, this sums the I/O time from all attempts so that:
  - `upstream_latency_ms` = total time waiting on providers
  - `lasso_overhead_ms` = e2e - upstream = actual Lasso processing time

  Without accumulation, failover would inflate apparent Lasso overhead since
  failed provider I/O time would be attributed to Lasso instead of upstream.
  """
  @spec add_upstream_latency(t(), number()) :: t()
  def add_upstream_latency(%__MODULE__{} = ctx, io_ms) when is_number(io_ms) do
    current = ctx.upstream_latency_ms || 0
    %{ctx | upstream_latency_ms: current + io_ms}
  end

  @doc """
  Marks the start of request execution for duration tracking.
  Stores current monotonic time in milliseconds for later duration calculation.
  """
  @spec mark_request_start(t()) :: t()
  def mark_request_start(%__MODULE__{} = ctx) do
    %{ctx | request_start_ms: System.monotonic_time(:millisecond)}
  end

  @doc """
  Calculates request duration from marked start time.
  Returns duration in milliseconds, or 0 if start was never marked.
  """
  @spec get_duration(t()) :: non_neg_integer()
  def get_duration(%__MODULE__{request_start_ms: nil}), do: 0

  @spec get_duration(t()) :: non_neg_integer()
  def get_duration(%__MODULE__{request_start_ms: start_ms}) do
    System.monotonic_time(:millisecond) - start_ms
  end

  @doc """
  Records successful result shape and calculates Lasso overhead.
  """
  @spec record_success(t(), term()) :: t()
  def record_success(%__MODULE__{} = ctx, result) do
    now = System.monotonic_time(:microsecond)
    end_to_end_ms = (now - ctx.start_time) / 1000.0

    {result_type, result_size} = analyze_result(result)

    # Calculate Lasso internal overhead (everything except upstream I/O)
    lasso_overhead_ms =
      if ctx.upstream_latency_ms do
        end_to_end_ms - ctx.upstream_latency_ms
      else
        nil
      end

    %{
      ctx
      | status: :success,
        result_type: result_type,
        result_size_bytes: result_size,
        end_to_end_latency_ms: end_to_end_ms,
        lasso_overhead_ms: lasso_overhead_ms
    }
  end

  @doc """
  Records error shape and calculates Lasso overhead.
  """
  @spec record_error(t(), term()) :: t()
  def record_error(%__MODULE__{} = ctx, error) do
    now = System.monotonic_time(:microsecond)
    end_to_end_ms = (now - ctx.start_time) / 1000.0

    error_map =
      case error do
        %{code: code} = e ->
          %{
            code: code,
            category: bounded_category(Map.get(e, :category))
          }

        _ ->
          %{
            code: -32_000,
            category: :unknown
          }
      end

    # Calculate Lasso internal overhead (everything except upstream I/O)
    lasso_overhead_ms =
      if ctx.upstream_latency_ms do
        end_to_end_ms - ctx.upstream_latency_ms
      else
        nil
      end

    %{
      ctx
      | status: :error,
        error: error_map,
        end_to_end_latency_ms: end_to_end_ms,
        lasso_overhead_ms: lasso_overhead_ms
    }
  end

  @doc """
  Increment retry counter.
  """
  @spec increment_retries(t()) :: t()
  def increment_retries(%__MODULE__{} = ctx) do
    %{ctx | retries: ctx.retries + 1}
  end

  @doc "Records one candidate rejected by the shared upstream capacity boundary."
  @spec record_shared_capacity_denial(t()) :: t()
  def record_shared_capacity_denial(%__MODULE__{} = ctx) do
    %{ctx | shared_capacity_denials: ctx.shared_capacity_denials + 1}
  end

  @doc """
  Track an error category to detect repeated failures across providers.

  Used for detecting when the same error (e.g., result size violation) occurs
  across multiple providers, indicating a universal limitation rather than
  provider-specific issue.
  """
  @spec track_error_category(t(), atom()) :: t()
  def track_error_category(%__MODULE__{} = ctx, category) when is_atom(category) do
    count = Map.get(ctx.repeated_error_categories, category, 0) + 1
    %{ctx | repeated_error_categories: Map.put(ctx.repeated_error_categories, category, count)}
  end

  @doc """
  Get the count for a specific error category.
  """
  @spec get_error_category_count(t(), atom()) :: non_neg_integer()
  def get_error_category_count(%__MODULE__{} = ctx, category) when is_atom(category) do
    Map.get(ctx.repeated_error_categories, category, 0)
  end

  @doc """
  Records the channel that successfully executed the request.
  Also updates selected_provider for backwards compatibility.
  """
  @spec set_executed_channel(t(), Channel.t()) :: t()
  def set_executed_channel(%__MODULE__{} = ctx, %Channel{} = channel) do
    %{
      ctx
      | executed_channel: channel_identity(channel),
        selected_provider: %{
          id: BoundedIdentifier.encode(channel.provider_id),
          protocol: channel.transport
        }
    }
  end

  @doc """
  The last attempt that was actually sent to a provider, or nil. Attempts that failed
  before dispatch are not recorded, so this names who the request last reached, which
  can differ from `selected_provider` when a later choice was never sent.
  """
  @spec last_dispatched_attempt(t()) :: channel_attempt() | nil
  def last_dispatched_attempt(%__MODULE__{attempted_channels: attempts}), do: List.last(attempts)

  @doc "Keeps the terminal fact and its channel together across later selection phases."
  @spec record_terminal_attempt(t(), Channel.t(), struct()) :: t()
  def record_terminal_attempt(%__MODULE__{} = ctx, %Channel{} = channel, fact) do
    %{ctx | terminal_attempt_fact: fact, terminal_attempt_channel: channel_identity(channel)}
  end

  @doc """
  Names the latest upstream response and its profile as the public answer, leaving the request's own
  counters untouched. A response whose dispatch count disagrees with the request cannot be a
  request terminal, so the context is then unchanged.
  """
  @spec adopt_terminal_response(t()) :: t()
  def adopt_terminal_response(
        %__MODULE__{
          terminal_attempt_fact: %AttemptTerminal.Response{identity: identity} = fact,
          terminal_attempt_channel: %{provider_id: provider_id, transport: transport} = channel,
          execution_envelope: envelope
        } = ctx
      ) do
    if identity.candidate_admission_count <= envelope.candidate_admission_count and
         identity.dispatch_count == envelope.dispatch_count do
      %{
        ctx
        | public_response_attempt: fact,
          executed_channel: channel,
          routing_profile: identity.profile,
          effective_profile: identity.profile,
          selected_provider: %{id: provider_id, protocol: transport}
      }
    else
      ctx
    end
  end

  @doc """
  Records a failed channel attempt for observability/debugging.
  Appends to the attempted_channels list to maintain audit trail.
  """
  @spec record_channel_attempt(t(), Channel.t(), term(), atom() | nil) :: t()
  def record_channel_attempt(
        %__MODULE__{} = ctx,
        %Channel{} = channel,
        error,
        exhaustion_category \\ nil
      ) do
    {category, code} = normalized_error(error)

    attempt = %{
      channel: channel_identity(channel),
      outcome: :error,
      category: category,
      code: code,
      exhaustion_category: exhaustion_category || exhaustion_category(ctx.method, error, category)
    }

    ctx
    |> mark_channel_attempted(channel)
    |> Map.update!(:attempted_channels, &(&1 ++ [attempt]))
    |> Map.put(
      :last_attempt_error,
      JError.from(error, provider_id: channel.provider_id, transport: channel.transport)
    )
  end

  @doc """
  Records a successful channel attempt. Called before set_executed_channel
  to capture the full attempt history.
  """
  @spec record_channel_success(t(), Channel.t()) :: t()
  def record_channel_success(%__MODULE__{} = ctx, %Channel{} = channel) do
    attempt = %{
      channel: channel_identity(channel),
      outcome: :success,
      category: nil,
      code: nil
    }

    ctx
    |> mark_channel_attempted(channel)
    |> Map.update!(:attempted_channels, &(&1 ++ [attempt]))
  end

  @doc "Records a physical instance and transport in the bounded request history."
  @spec mark_channel_attempted(t(), Channel.t()) :: t()
  def mark_channel_attempted(%__MODULE__{} = ctx, %Channel{} = channel) do
    attempted =
      case channel.instance_id do
        instance_id when is_binary(instance_id) ->
          Map.put(ctx.attempted_instance_transports, {instance_id, channel.transport}, true)

        _other ->
          ctx.attempted_instance_transports
      end

    %{
      ctx
      | attempted_instance_transports: attempted,
        phase_attempt_count: ctx.phase_attempt_count + 1
    }
  end

  @doc "Reports whether a physical instance and transport were already attempted."
  @spec attempted_instance?(t(), String.t() | nil, :http | :ws) :: boolean()
  def attempted_instance?(%__MODULE__{}, nil, _transport), do: false

  def attempted_instance?(%__MODULE__{} = ctx, instance_id, transport) do
    Map.has_key?(ctx.attempted_instance_transports, {instance_id, transport})
  end

  # Private helpers

  defp bounded_request_id(nil), do: generate_request_id()

  defp bounded_request_id(request_id) when is_binary(request_id),
    do: BoundedIdentifier.encode(request_id)

  defp bounded_request_id(_request_id), do: generate_request_id()

  defp generate_request_id do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
  end

  defp analyze_result(%Response.Success{raw_bytes: raw_bytes}) do
    # For passthrough responses, use raw bytes size directly (no re-encoding)
    {"passthrough", byte_size(raw_bytes)}
  end

  defp analyze_result(result) do
    result_type =
      cond do
        is_nil(result) -> "null"
        is_boolean(result) -> "boolean"
        is_number(result) -> "number"
        is_binary(result) -> "string"
        is_list(result) -> "array"
        is_map(result) -> "object"
        true -> "unknown"
      end

    # Estimate serialized size
    result_size =
      try do
        result |> Jason.encode!() |> byte_size()
      rescue
        _ -> 0
      end

    {result_type, result_size}
  end

  defp channel_identity(channel) do
    %{
      profile: BoundedIdentifier.encode(channel.profile),
      provider_id: BoundedIdentifier.encode(channel.provider_id),
      instance_id: BoundedIdentifier.encode_optional(channel.instance_id),
      transport: channel.transport,
      route_generation: channel.route_generation
    }
  end

  defp normalize_selected_provider(%Channel{} = channel) do
    %{id: BoundedIdentifier.encode(channel.provider_id), protocol: channel.transport}
  end

  defp normalize_selected_provider(%{id: id, protocol: protocol})
       when is_binary(id) and protocol in [:http, :ws] do
    %{id: BoundedIdentifier.encode(id), protocol: protocol}
  end

  defp normalize_selected_provider(_other), do: nil

  defp exhaustion_category(
         "eth_getLogs",
         %JError{resolution: %{constraint_claim: claim}},
         _category
       )
       when claim in [:block_span, :result_volume],
       do: :log_range_limit

  defp exhaustion_category(_method, _error, category), do: category

  defp normalized_error(%{category: category, code: code}) when is_integer(code),
    do: {bounded_category(category), code}

  defp normalized_error(error) when is_atom(error), do: {bounded_category(error), nil}
  defp normalized_error(_error), do: {:unknown, nil}

  defp bounded_category(category) when is_atom(category), do: category
  defp bounded_category(_category), do: :unknown
end
