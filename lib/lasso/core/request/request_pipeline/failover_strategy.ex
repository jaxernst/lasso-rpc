defmodule Lasso.RPC.RequestPipeline.FailoverStrategy do
  @moduledoc """
  Centralized failover decision logic and execution for the request pipeline.

  This module consolidates failover logic into a single source of truth,
  making it easier to:
  - Modify failover behavior and criteria
  - Test failover logic in isolation
  - Maintain consistent failover decisions
  - Add new error categories and handling rules

  ## Smart Failover Detection

  To minimize latency variance, the strategy detects when the same error category
  occurs repeatedly across multiple providers (e.g., "query returned more than 10000 results").
  After a threshold (default: 2 occurrences), it assumes the error is universal and fails fast.

  This prevents scenarios where:
  - Request tries Provider A → "result too large" (2s)
  - Request tries Provider B → "result too large" (2s)
  - Request tries Provider C → "result too large" (2s)
  - Total wasted: 6+ seconds

  Instead:
  - Request tries Provider A → "result too large" (2s)
  - Request tries Provider B → "result too large" (2s)
  - Strategy detects universal failure → fail fast
  - Total: 4s (2 providers max)
  """

  # After this many providers return the same capability violation,
  # assume it's a universal limitation and fail fast
  @repeated_capability_violation_threshold 2

  require Logger

  alias Lasso.RPC.{RequestContext, Channel}
  alias Lasso.RPC.RequestPipeline.Observability
  alias Lasso.JSONRPC.Error, as: JError

  @type decision :: {:failover, atom()} | {:terminal_error, atom()}
  @type execute_result ::
          {:ok, any(), Channel.t(), RequestContext.t()}
          | {:error, any(), Channel.t(), RequestContext.t()}
          | {:error, atom(), RequestContext.t()}

  @doc """
  Decides whether an error should trigger failover to the next channel.

  Takes into account:
  - Error retriability (retriable?: true/false)
  - Remaining channels available
  - Request context (repeated error tracking)

  Returns:
  - `{:failover, reason}` - Should fast-fail to next channel immediately
  - `{:terminal_error, reason}` - Should not failover (terminal error or no channels)

  ## Examples

      iex> decide(%JError{retriable?: true, category: :rate_limit}, [channel1, channel2], ctx)
      {:failover, :rate_limit_detected}

      iex> decide(%JError{retriable?: false, category: :invalid_params}, [channel1], ctx)
      {:terminal_error, :non_retriable_error}

      iex> decide(%JError{retriable?: true}, [], ctx)
      {:terminal_error, :no_channels_remaining}
  """
  @spec decide(term(), [Channel.t()], RequestContext.t()) :: decision()
  def decide(error, rest_channels, ctx) do
    case should_fast_fail_error?(error, rest_channels, ctx) do
      {true, reason} -> {:failover, reason}
      {false, reason} -> {:terminal_error, reason}
    end
  end

  @doc """
  Executes a failover to the next available channel.

  This handles the complete failover workflow:
  1. Logs the failover decision
  2. Records observability events
  3. Updates request context (retry count, latency)
  4. Recursively attempts the request on remaining channels

  ## Parameters
  - `ctx` - Current request context
  - `channel` - Channel that failed
  - `error` - The error that triggered failover
  - `failover_reason` - Categorized reason for failover (from `decide/2`)
  - `rest_channels` - Remaining channels to try
  - `rpc_request` - The RPC request to execute
  - `timeout` - Request timeout
  - `attempt_fn` - Function to recursively attempt on remaining channels

  ## Returns
  - Result from attempting request on next channel
  """
  @spec execute_failover(
          RequestContext.t(),
          Channel.t(),
          term(),
          atom(),
          [Channel.t()],
          map(),
          timeout(),
          (list(), map(), timeout(), RequestContext.t() -> execute_result())
        ) :: execute_result()
  def execute_failover(
        ctx,
        channel,
        error,
        failover_reason,
        rest_channels,
        rpc_request,
        timeout,
        attempt_fn
      ) do
    error_category = extract_error_category(error)

    # Record observability events (logged via TelemetryLogger)
    Observability.record_fast_fail(ctx, channel, failover_reason, error)

    # Update context: increment retries and track error category
    ctx =
      ctx
      |> RequestContext.increment_retries()
      |> RequestContext.track_error_category(error_category)

    attempt_fn.(rest_channels, rpc_request, timeout, ctx)
  end

  @doc """
  Handles a terminal error (non-retriable or exhausted channels).

  Logs the terminal error and returns the error tuple.
  """
  @spec handle_terminal_error(
          RequestContext.t(),
          Channel.t(),
          term(),
          atom(),
          non_neg_integer()
        ) :: {:error, term(), Channel.t(), RequestContext.t()}
  def handle_terminal_error(ctx, channel, error, reason, remaining_channels) do
    Logger.warning("Channel request failed - no failover",
      request_id: ctx.request_id,
      channel: Channel.to_string(channel),
      provider_id: channel.provider_id,
      method: ctx.method,
      error: inspect(error),
      reason: reason,
      remaining_channels: remaining_channels,
      chain: ctx.chain
    )

    {:error, error, channel, ctx}
  end

  # Private helpers

  # Determines if this error should trigger fast-fail (immediate failover)
  # or if we've exhausted all channels.
  #
  # Smart detection: If the same capability violation occurs multiple times,
  # assume it's a universal limitation and stop retrying.
  #
  # Returns:
  # - {true, reason} - Should fast-fail with reason
  # - {false, reason} - Should not failover (no channels or non-retriable)
  @spec should_fast_fail_error?(any(), list(), RequestContext.t()) :: {boolean(), atom()}
  defp should_fast_fail_error?(_reason, [], _ctx), do: {false, :no_channels_remaining}

  defp should_fast_fail_error?(%JError{retriable?: false}, _rest, _ctx),
    do: {false, :non_retriable_error}

  # Smart detection for capability violations (result size, block range, etc.)
  # If we've seen this error N times already, assume it's universal and stop
  defp should_fast_fail_error?(%JError{category: :capability_violation} = error, _rest, ctx) do
    repeated_count = RequestContext.get_error_category_count(ctx, :capability_violation)

    if repeated_count >= @repeated_capability_violation_threshold do
      Logger.warning("Repeated capability violation detected - assuming universal limitation",
        request_id: ctx.request_id,
        error_message: error.message,
        method: ctx.method,
        repeated_count: repeated_count,
        threshold: @repeated_capability_violation_threshold,
        chain: ctx.chain
      )

      {false, :universal_capability_violation}
    else
      {true, :capability_violation_detected}
    end
  end

  defp should_fast_fail_error?(%JError{category: :rate_limit}, _rest, _ctx),
    do: {true, :rate_limit_detected}

  defp should_fast_fail_error?(%JError{category: :server_error}, _rest, _ctx),
    do: {true, :server_error_detected}

  defp should_fast_fail_error?(%JError{category: :network_error}, _rest, _ctx),
    do: {true, :network_error_detected}

  defp should_fast_fail_error?(%JError{category: :auth_error}, _rest, _ctx),
    do: {true, :auth_error_detected}

  defp should_fast_fail_error?(%JError{retriable?: true}, _rest, _ctx),
    do: {true, :retriable_error}

  defp should_fast_fail_error?(:circuit_open, _rest, _ctx), do: {true, :circuit_open}

  defp should_fast_fail_error?(_reason, _rest, _ctx), do: {false, :unknown_error_format}

  # Extracts error category for telemetry and logging.
  @spec extract_error_category(any()) :: atom()
  defp extract_error_category(%JError{category: category}), do: category || :unknown
  defp extract_error_category(:circuit_open), do: :circuit_open
  defp extract_error_category(_), do: :unknown
end
