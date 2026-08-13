defmodule Lasso.RPC.RequestPipeline do
  @moduledoc """
  Orchestrates RPC request execution with provider selection, retries, and failover.

  This module provides a unified pipeline for executing JSON-RPC requests across
  multiple providers and transports (HTTP/WebSocket). Key features:

  - Single execution path for both normal routing and provider overrides
  - Automatic failover on retriable errors
  - Circuit breaker integration per provider/transport
  - Full observability via RequestContext

  ## Return Type Contract

  All functions return 3-tuples:
  - `{:ok, result, ctx}` - Success with result and updated context
  - `{:error, %JError{}, ctx}` - Failure with typed error and updated context

  The executed channel is stored in `ctx.executed_channel` for observability,
  """

  require Logger

  alias Lasso.Config.{ConfigStore, ProfileValidator}
  alias Lasso.Core.Support.CircuitBreaker
  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.Providers.{CandidateListing, InstanceState}

  alias Lasso.RPC.{
    Channel,
    ExecutionEnvelope,
    RequestContext,
    Selection,
    TransportRegistry
  }

  alias Lasso.RPC.Providers.AdapterFilter
  alias Lasso.RPC.RequestOptions
  alias Lasso.RPC.RequestPipeline.{FailoverStrategy, Observability}

  # Type definitions
  @type chain_id :: pos_integer()
  @type method :: String.t()
  @type params :: list()
  @type result :: {:ok, any(), RequestContext.t()} | {:error, JError.t(), RequestContext.t()}

  # A channel source is a function that returns channels to try
  @type channel_source :: (RequestContext.t() -> [Channel.t()])

  # Configuration
  @max_channel_candidates 10

  @doc """
  Execute an RPC request using transport-agnostic channels.

  This is the main entry point for request execution. It handles:
  - Provider selection (or override)
  - Automatic failover on retriable errors
  - Circuit breaker integration
  - Full observability tracking

  ## Options

  Takes a `RequestOptions` struct with:
  - `strategy` - Routing strategy (:fastest, :load_balanced, :latency_weighted, :priority)
  - `provider_override` - Force specific provider (optional)
  - `transport` - Transport preference (:http, :ws, :both)
  - `failover_on_override` - Retry on other providers if override fails
  - `timeout_ms` - Per-attempt timeout in milliseconds
  - `request_id` - Request tracing ID (optional)
  - `request_context` - Pre-created RequestContext (optional)

  ## Examples

      {:ok, result, ctx} = execute_via_channels(
        1,
        "eth_blockNumber",
        [],
        %RequestOptions{strategy: :fastest}
      )
      # ctx.executed_channel contains the channel that succeeded

      {:error, %JError{}, ctx} = execute_via_channels(
        1,
        "eth_call",
        [],
        %RequestOptions{provider_override: "failing_provider"}
      )
  """
  @spec execute_via_channels(chain_id(), method(), params(), RequestOptions.t()) :: result()
  def execute_via_channels(chain_id, method, params, %RequestOptions{} = opts)
      when is_integer(chain_id) and chain_id > 0 do
    ctx = initialize_context(chain_id, method, params, opts)
    rpc_request = build_rpc_request(method, params, ctx, opts)
    ctx = RequestContext.set_execution_params(ctx, rpc_request, opts.timeout_ms, opts)

    case validate_provider_override(chain_id, opts) do
      :ok ->
        channel_source = build_channel_source(opts)
        execute_pipeline(channel_source, ctx)

      {:error, jerr} ->
        finalize_error(jerr, ctx)
    end
  end

  @spec validate_provider_override(chain_id(), RequestOptions.t()) :: :ok | {:error, JError.t()}
  defp validate_provider_override(_chain_id, %RequestOptions{provider_override: nil}), do: :ok

  defp validate_provider_override(chain_id, %RequestOptions{
         provider_override: provider_id,
         profile: profile
       }) do
    case ConfigStore.get_provider(profile, chain_id, provider_id) do
      {:ok, _provider} ->
        :ok

      {:error, _} ->
        {:error,
         JError.new(-32_602, "Provider '#{provider_id}' not found",
           category: :invalid_params,
           retriable?: false,
           data: %{provider_id: provider_id, chain_id: chain_id, profile: profile}
         )}
    end
  end

  @spec execute_pipeline(channel_source(), RequestContext.t()) :: result()
  defp execute_pipeline(channel_source, ctx) do
    ctx = RequestContext.mark_request_start(ctx)

    Observability.record_request_start(
      ctx.chain_id,
      ctx.method,
      ctx.opts.strategy,
      ctx.opts.provider_override
    )

    # Get channels from the source
    ctx = RequestContext.mark_selection_start(ctx)

    channels = get_channels_from_source(channel_source, ctx)

    ctx =
      RequestContext.mark_selection_end(ctx,
        candidates: Enum.map(channels, &"#{&1.provider_id}:#{&1.transport}"),
        selected: List.first(channels)
      )

    case channels do
      [] ->
        handle_no_channels(ctx)

      _ ->
        ctx = RequestContext.mark_upstream_start(ctx)
        attempt_channels(channels, ctx)
    end
  end

  @spec get_channels_from_source(channel_source(), RequestContext.t()) :: [Channel.t()]
  defp get_channels_from_source(channel_source, ctx), do: channel_source.(ctx)

  # Builds a function that returns channels to try, unifying override vs normal selection
  # Params are extracted from RequestContext - no need to pass separately (prevents closure footgun)
  @spec build_channel_source(RequestOptions.t()) :: channel_source()
  defp build_channel_source(%RequestOptions{provider_override: nil, profile: profile} = opts) do
    fn %RequestContext{chain_id: chain_id, method: method, params: params} = _ctx ->
      Selection.select_channels(profile, chain_id, method,
        strategy: opts.strategy,
        transport: opts.transport || :both,
        limit: @max_channel_candidates,
        params: params
      )
    end
  end

  defp build_channel_source(
         %RequestOptions{provider_override: provider_id, profile: profile} = opts
       ) do
    fn %RequestContext{chain_id: chain_id, method: method, params: params} = _ctx ->
      primary_channels = get_provider_channels(profile, chain_id, provider_id, opts.transport)

      if opts.failover_on_override do
        failover_channels =
          Selection.select_channels(profile, chain_id, method,
            strategy: opts.strategy,
            transport: :both,
            exclude: [provider_id],
            limit: @max_channel_candidates,
            params: params
          )

        primary_channels ++ failover_channels
      else
        primary_channels
      end
    end
  end

  @spec attempt_channels([Channel.t()], RequestContext.t()) :: result()
  defp attempt_channels(channels, ctx), do: attempt_channels(channels, ctx, [])

  @spec attempt_channels([Channel.t()], RequestContext.t(), [Channel.t()]) :: result()
  defp attempt_channels([], ctx, [_ | _] = param_rejected) do
    if ctx.attempted_channels == [] do
      retry_param_rejected(param_rejected, ctx)
    else
      exhausted(ctx)
    end
  end

  defp attempt_channels([], ctx, _param_rejected), do: exhausted(ctx)

  defp attempt_channels([%Channel{} = channel | rest], %{bypass_param_limits: true} = ctx, _acc) do
    case ExecutionEnvelope.admit_candidate(ctx.execution_envelope) do
      {:ok, envelope} -> execute_on_channel(channel, rest, %{ctx | execution_envelope: envelope})
      {:error, reason} -> finalize_bounded_error(ctx, reason)
    end
  end

  defp attempt_channels([%Channel{} = channel | rest], ctx, param_rejected)
       when is_list(rest) do
    case ExecutionEnvelope.admit_candidate(ctx.execution_envelope) do
      {:ok, envelope} ->
        ctx = %{ctx | execution_envelope: envelope}
        %{"method" => method, "params" => params} = ctx.rpc_request

        case AdapterFilter.validate_params(channel, method, params) do
          :ok ->
            execute_on_channel(channel, rest, ctx)

          {:error, reason} ->
            Logger.debug("Parameters invalid for channel, skipping",
              channel: Channel.to_string(channel),
              method: method,
              reason: inspect(reason)
            )

            Observability.record_admission_rejection(ctx, channel, :parameter_constraint)
            ctx = RequestContext.increment_retries(ctx)
            attempt_channels(rest, ctx, param_rejected ++ [channel])
        end

      {:error, reason} ->
        Observability.record_admission_rejection(ctx, channel, reason)
        finalize_bounded_error(ctx, reason)
    end
  end

  defp retry_param_rejected(channels, ctx) do
    Logger.warning("All channels rejected by parameter limits, attempting anyway",
      chain_id: ctx.chain_id,
      method: ctx.method,
      request_id: ctx.request_id,
      candidates: length(channels)
    )

    :telemetry.execute([:lasso, :capabilities, :safety_override], %{count: 1}, %{
      reason: :all_param_rejected,
      method: ctx.method,
      chain_id: ctx.chain_id
    })

    attempt_channels(channels, %{ctx | bypass_param_limits: true}, [])
  end

  defp exhausted(ctx) do
    Logger.warning("All channels exhausted",
      chain_id: ctx.chain_id,
      method: ctx.method,
      request_id: ctx.request_id,
      attempts: length(ctx.attempted_channels)
    )

    jerr =
      JError.new(-32_000, "No channels available",
        category: :provider_error,
        retriable?: true
      )

    finalize_error(jerr, ctx)
  end

  @spec execute_on_channel(Channel.t(), [Channel.t()], RequestContext.t()) :: result()
  defp execute_on_channel(%Channel{instance_id: instance_id} = channel, rest_channels, ctx)
       when is_binary(instance_id) do
    case ExecutionEnvelope.reserve_dispatch(
           ctx.execution_envelope,
           instance_id,
           channel.transport
         ) do
      {:ok, envelope, attempt_timeout_ms} ->
        execute_reserved_channel(
          channel,
          instance_id,
          rest_channels,
          %{ctx | execution_envelope: envelope},
          attempt_timeout_ms
        )

      {:error, reason} ->
        Observability.record_admission_rejection(ctx, channel, reason)

        case reason do
          :duplicate_dispatch -> attempt_channels(rest_channels, ctx)
          :dispatch_budget_exhausted -> finalize_dispatch_exhaustion(ctx)
          _ -> finalize_bounded_error(ctx, reason)
        end
    end
  end

  defp execute_on_channel(channel, rest_channels, ctx) do
    Observability.record_admission_rejection(ctx, channel, :missing_instance_identity)

    Logger.error("Channel has no stable upstream instance identity",
      channel: Channel.to_string(channel),
      request_id: ctx.request_id
    )

    ctx = RequestContext.increment_retries(ctx)
    attempt_channels(rest_channels, ctx)
  end

  defp execute_reserved_channel(channel, instance_id, rest_channels, ctx, attempt_timeout_ms) do
    cb_state =
      instance_id
      |> InstanceState.read_circuit(channel.transport)
      |> Map.get(:state, :unknown)

    ctx = %{
      ctx
      | selected_provider: %{id: channel.provider_id, protocol: channel.transport},
        circuit_breaker_state: cb_state
    }

    dispatch_ref = make_ref()
    caller = self()

    on_terminal = fn result, attempt_elapsed_ms ->
      Observability.record_attempt(ctx, channel, instance_id, result,
        attempt_elapsed_ms: attempt_elapsed_ms
      )
    end

    on_dispatch = fn dispatched_at_us ->
      send(caller, {:bounded_dispatch_confirmed, dispatch_ref, dispatched_at_us})
    end

    execution_result =
      execute_with_circuit_breaker(
        channel,
        instance_id,
        ctx.rpc_request,
        attempt_timeout_ms,
        on_terminal,
        on_dispatch
      )

    dispatched? =
      receive do
        {:bounded_dispatch_confirmed, ^dispatch_ref, _dispatched_at_us} -> true
      after
        0 -> false
      end

    ctx =
      if dispatched? do
        ctx
      else
        envelope =
          ExecutionEnvelope.release_dispatch(
            ctx.execution_envelope,
            instance_id,
            channel.transport
          )

        %{ctx | execution_envelope: envelope}
      end

    case execution_result do
      # Function executed - examine what it returned
      {:executed, {:ok, result, io_ms}} ->
        handle_success(result, io_ms, channel, ctx)

      {:executed, {:error, :unsupported_method, _io_ms}} ->
        Observability.record_admission_rejection(ctx, channel, :unsupported_method)

        Logger.debug("Method not supported on channel, skipping",
          channel: Channel.to_string(channel),
          method: ctx.rpc_request["method"]
        )

        attempt_channels(rest_channels, ctx)

      {:executed, {:error, %JError{category: :local_capacity_rejection} = reason, io_ms}} ->
        Observability.record_admission_rejection(ctx, channel, :local_capacity_rejection)
        handle_channel_error(reason, io_ms, channel, rest_channels, ctx)

      {:executed, {:error, reason, io_ms}} ->
        handle_channel_error(reason, io_ms, channel, rest_channels, ctx)

      {:executed, {:exception, {kind, error, _stacktrace}}} ->
        Logger.error("Exception during request execution",
          channel: Channel.to_string(channel),
          kind: kind,
          error: inspect(error)
        )

        exception_error =
          JError.new(-32_000, "Internal error: #{kind}",
            category: :server_error,
            retriable?: true
          )

        handle_channel_error(exception_error, nil, channel, rest_channels, ctx)

      # Circuit breaker rejected execution
      {:rejected, :circuit_open} ->
        Observability.record_admission_rejection(ctx, channel, :circuit_open)
        handle_circuit_open(channel, rest_channels, ctx)

      {:rejected, :half_open_busy} ->
        Observability.record_admission_rejection(ctx, channel, :half_open_busy)
        handle_circuit_open(channel, rest_channels, ctx)

      {:rejected, :admission_timeout} ->
        Observability.record_admission_rejection(ctx, channel, :admission_timeout)

        Logger.warning("Circuit breaker admission timeout",
          channel: Channel.to_string(channel),
          request_id: ctx.request_id
        )

        # Treat as retriable - try next channel
        ctx = RequestContext.increment_retries(ctx)
        attempt_channels(rest_channels, ctx)

      {:rejected, :not_found} ->
        Observability.record_admission_rejection(ctx, channel, :circuit_breaker_not_found)

        Logger.error("Circuit breaker not found",
          channel: Channel.to_string(channel),
          request_id: ctx.request_id
        )

        # Treat as retriable - try next channel
        ctx = RequestContext.increment_retries(ctx)
        attempt_channels(rest_channels, ctx)
    end
  end

  @spec handle_success(any(), number(), Channel.t(), RequestContext.t()) :: result()
  defp handle_success(result, io_ms, channel, ctx) do
    Logger.debug("Request succeeded",
      channel: Channel.to_string(channel),
      request_id: ctx.request_id,
      io_latency_ms: io_ms
    )

    log_slow_request_if_needed(io_ms, ctx.method, channel, ctx)

    # Update context with success info
    ctx =
      ctx
      |> RequestContext.add_upstream_latency(io_ms)
      |> RequestContext.record_channel_success(channel)
      |> RequestContext.set_executed_channel(channel)
      |> RequestContext.mark_upstream_end()
      |> RequestContext.record_success(result)

    duration_ms = RequestContext.get_duration(ctx)
    Observability.record_success(ctx, channel, ctx.method, ctx.opts.strategy, duration_ms)

    {:ok, result, ctx}
  end

  @spec handle_channel_error(
          any(),
          number() | nil,
          Channel.t(),
          [Channel.t()],
          RequestContext.t()
        ) ::
          result()
  defp handle_channel_error(reason, io_ms, channel, rest_channels, ctx) do
    # Normalize io_ms: exceptions don't have latency measurements (nil -> 0)
    latency_ms = if is_nil(io_ms), do: 0, else: io_ms

    # Record the failed attempt
    ctx =
      ctx
      |> RequestContext.add_upstream_latency(latency_ms)
      |> RequestContext.record_channel_attempt(channel, reason)

    # Use FailoverStrategy to decide next action
    case FailoverStrategy.decide(reason, rest_channels, ctx) do
      {:failover, failover_reason} ->
        Logger.debug("Failing over to next channel",
          channel: Channel.to_string(channel),
          reason: failover_reason,
          remaining: length(rest_channels)
        )

        error_category = extract_error_category(reason)

        ctx =
          ctx
          |> RequestContext.increment_retries()
          |> RequestContext.track_error_category(error_category)

        Observability.record_fast_fail(ctx, channel, failover_reason, reason, latency_ms)

        next_channels =
          maybe_exclude_provider_for_method_not_found(rest_channels, channel, reason)

        attempt_channels(next_channels, ctx)

      {:terminal_error, terminal_reason} ->
        Logger.warning("Terminal error, not retrying",
          channel: Channel.to_string(channel),
          reason: terminal_reason,
          error: inspect(reason)
        )

        jerr = JError.from(reason, provider_id: channel.provider_id)

        ctx = RequestContext.set_executed_channel(ctx, channel)

        finalize_error(jerr, ctx)
    end
  end

  @spec handle_circuit_open(Channel.t(), [Channel.t()], RequestContext.t()) :: result()
  defp handle_circuit_open(channel, rest_channels, ctx) do
    Logger.info("Circuit breaker open, skipping",
      channel: Channel.to_string(channel),
      request_id: ctx.request_id
    )

    ctx = RequestContext.increment_retries(ctx)

    Observability.record_circuit_open(ctx, channel)

    attempt_channels(rest_channels, ctx)
  end

  @spec handle_no_channels(RequestContext.t()) :: result()
  defp handle_no_channels(ctx) do
    profile = if ctx.opts, do: ctx.opts.profile, else: ProfileValidator.default_profile()

    retry_after_ms =
      calculate_min_recovery_time(profile, ctx.chain_id, ctx.opts && ctx.opts.transport)

    {message, data} = build_exhaustion_error_message(ctx.method, retry_after_ms, ctx.chain_id)

    jerr =
      JError.new(-32_000, message,
        category: :provider_error,
        retriable?: true,
        data: data
      )

    Logger.warning("No channels available",
      chain_id: ctx.chain_id,
      method: ctx.method,
      retry_after_ms: retry_after_ms
    )

    Observability.record_exhaustion(ctx.chain_id, ctx.method, ctx.opts.transport, retry_after_ms)

    finalize_error(jerr, ctx)
  end

  @spec finalize_error(JError.t(), RequestContext.t()) :: result()
  defp finalize_error(jerr, ctx) do
    ctx =
      ctx
      |> RequestContext.mark_upstream_end()
      |> RequestContext.record_error(jerr)

    if ctx.executed_channel do
      duration_ms = RequestContext.get_duration(ctx)

      Observability.record_failure(
        ctx,
        ctx.executed_channel,
        ctx.method,
        ctx.opts.strategy,
        jerr,
        duration_ms
      )
    end

    {:error, jerr, ctx}
  end

  defp finalize_bounded_error(ctx, reason) do
    {message, category} =
      case reason do
        :deadline_exhausted ->
          {"Request deadline exhausted", :timeout}

        :dispatch_budget_exhausted ->
          {"Request dispatch budget exhausted", :provider_error}

        :candidate_budget_exhausted ->
          {"Candidate admission budget exhausted", :local_capacity_rejection}
      end

    code = if category == :local_capacity_rejection, do: -32_005, else: -32_000

    jerr =
      JError.new(code, message,
        category: category,
        retriable?: false,
        data: %{reason: reason}
      )

    finalize_error(jerr, ctx)
  end

  defp finalize_dispatch_exhaustion(
         %RequestContext{attempted_channels: [_ | _] = attempted_channels} = ctx
       ) do
    {channel, {:error, reason}} = List.last(attempted_channels)
    ctx = RequestContext.set_executed_channel(ctx, channel)
    finalize_error(JError.from(reason, provider_id: channel.provider_id), ctx)
  end

  defp finalize_dispatch_exhaustion(ctx),
    do: finalize_bounded_error(ctx, :dispatch_budget_exhausted)

  # CircuitBreaker.call returns:
  # - {:executed, fun_result} - Function executed, fun_result is what Channel.request returned
  # - {:executed, {:exception, {kind, error, stacktrace}}} - Function raised an exception
  # - {:rejected, reason} - Circuit breaker prevented execution
  #
  # Channel.request returns: {:ok, result, io_ms} | {:error, reason, io_ms}
  #
  # The CB handles all exit cases internally (timeout, noproc, etc.) and returns
  # {:rejected, :admission_timeout} or {:rejected, :not_found} instead.
  @type circuit_breaker_result ::
          {:ok, any(), number()}
          | {:error, any(), number()}
          | {:exception, {atom(), any(), list()}}

  @spec execute_with_circuit_breaker(
          Channel.t(),
          String.t(),
          map(),
          timeout(),
          CircuitBreaker.terminal_callback(),
          (integer() -> term())
        ) ::
          CircuitBreaker.call_result(circuit_breaker_result())
  defp execute_with_circuit_breaker(
         channel,
         instance_id,
         rpc_request,
         timeout,
         on_terminal,
         on_dispatch
       ) do
    attempt_fun = fn -> Channel.request(channel, rpc_request, timeout) end
    cb_id = {instance_id, channel.transport}

    CircuitBreaker.call(cb_id, attempt_fun, timeout,
      on_terminal: on_terminal,
      on_dispatch: on_dispatch,
      dispatch: dispatch_mode(channel.transport_module)
    )
  end

  defp dispatch_mode(transport_module) do
    if function_exported?(transport_module, :deferred_dispatch?, 0) and
         transport_module.deferred_dispatch?(),
       do: :deferred,
       else: :immediate
  end

  @spec initialize_context(chain_id(), method(), params(), RequestOptions.t()) ::
          RequestContext.t()
  defp initialize_context(chain_id, method, params, opts) do
    opts.request_context ||
      RequestContext.new(chain_id, method, params,
        transport: opts.transport || :http,
        strategy: opts.strategy,
        request_id: opts.request_id,
        plug_start_time: opts.plug_start_time
      )
  end

  @spec build_rpc_request(method(), params(), RequestContext.t(), RequestOptions.t()) :: map()
  defp build_rpc_request(method, params, ctx, opts) do
    %{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => params,
      "id" => opts.jsonrpc_id || ctx.request_id
    }
  end

  @spec get_provider_channels(String.t(), chain_id(), String.t(), atom() | nil) :: [Channel.t()]
  defp get_provider_channels(profile, chain_id, provider_id, transport_override) do
    transports = if transport_override, do: [transport_override], else: [:http, :ws]

    for transport <- transports,
        channel = fetch_channel_safe(profile, chain_id, provider_id, transport),
        not is_nil(channel),
        do: channel
  end

  @spec fetch_channel_safe(String.t(), chain_id(), String.t(), atom()) :: Channel.t() | nil
  defp fetch_channel_safe(profile, chain_id, provider_id, transport) do
    case TransportRegistry.get_channel(profile, chain_id, provider_id, transport) do
      {:ok, channel} -> channel
      {:error, _} -> nil
    end
  catch
    :exit, _ -> nil
  end

  @spec build_exhaustion_error_message(method(), non_neg_integer() | nil, chain_id()) ::
          {String.t(), map()}
  defp build_exhaustion_error_message(method, nil, _chain_id) do
    {"No available channels for method: #{method}. All circuit breakers are open.", %{}}
  end

  defp build_exhaustion_error_message(method, ms, _chain_id) when is_integer(ms) and ms > 0 do
    seconds = div(ms, 1000)

    message =
      "No available channels for method: #{method}. All circuits open, retry after #{seconds}s"

    {message, %{retry_after_ms: ms}}
  end

  defp build_exhaustion_error_message(method, retry_after_ms, chain_id) do
    Logger.warning("Invalid recovery time: #{inspect(retry_after_ms)}", chain_id: chain_id)
    {"No available channels for method: #{method}. All circuit breakers are open.", %{}}
  end

  @spec calculate_min_recovery_time(String.t(), chain_id(), atom() | nil) ::
          non_neg_integer() | nil
  defp calculate_min_recovery_time(profile, chain_id, transport_filter) do
    transport = transport_filter || :both

    {:ok, min_time} =
      CandidateListing.get_min_recovery_time(profile, chain_id, transport: transport)

    min_time
  end

  @spec extract_error_category(any()) :: atom()
  defp extract_error_category(%JError{category: category}), do: category || :unknown
  defp extract_error_category(:circuit_open), do: :circuit_open
  defp extract_error_category(_), do: :unknown

  @spec maybe_exclude_provider_for_method_not_found([Channel.t()], Channel.t(), any()) :: [
          Channel.t()
        ]
  defp maybe_exclude_provider_for_method_not_found(rest_channels, channel, %JError{
         category: :method_not_found
       }) do
    Enum.reject(rest_channels, &(&1.provider_id == channel.provider_id))
  end

  defp maybe_exclude_provider_for_method_not_found(rest_channels, _channel, _reason),
    do: rest_channels

  @spec log_slow_request_if_needed(number(), method(), Channel.t(), RequestContext.t()) :: :ok
  defp log_slow_request_if_needed(latency_ms, method, channel, ctx) when latency_ms > 4000 do
    Logger.warning("VERY SLOW request (may timeout clients)",
      request_id: ctx.request_id,
      method: method,
      provider: channel.provider_id,
      latency_ms: latency_ms
    )

    Observability.record_very_slow_request(
      ctx.chain_id,
      method,
      channel.provider_id,
      channel.transport,
      latency_ms
    )
  end

  defp log_slow_request_if_needed(latency_ms, method, channel, ctx) when latency_ms > 2000 do
    Logger.warning("Slow request",
      request_id: ctx.request_id,
      method: method,
      provider: channel.provider_id,
      latency_ms: latency_ms
    )

    Observability.record_slow_request(
      ctx.chain_id,
      method,
      channel.provider_id,
      channel.transport,
      latency_ms
    )
  end

  defp log_slow_request_if_needed(latency_ms, method, channel, ctx) when latency_ms > 1000 do
    Logger.info("Elevated latency",
      request_id: ctx.request_id,
      method: method,
      provider: channel.provider_id,
      latency_ms: latency_ms
    )
  end

  defp log_slow_request_if_needed(_latency_ms, _method, _channel, _ctx), do: :ok
end
