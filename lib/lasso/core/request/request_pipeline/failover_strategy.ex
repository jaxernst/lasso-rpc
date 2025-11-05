defmodule Lasso.RPC.RequestPipeline.FailoverStrategy do
  @moduledoc """
  Centralized failover decision logic and execution for the request pipeline.

  This module consolidates the scattered failover logic into a single source of truth,
  making it easier to:
  - Modify failover behavior and criteria
  - Test failover logic in isolation
  - Maintain consistent failover decisions
  - Add new error categories and handling rules
  """

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

  Returns:
  - `{:failover, reason}` - Should fast-fail to next channel immediately
  - `{:terminal_error, reason}` - Should not failover (terminal error or no channels)

  ## Examples

      iex> decide(%JError{retriable?: true, category: :rate_limit}, [channel1, channel2])
      {:failover, :rate_limit_detected}

      iex> decide(%JError{retriable?: false, category: :invalid_params}, [channel1])
      {:terminal_error, :non_retriable_error}

      iex> decide(%JError{retriable?: true}, [])
      {:terminal_error, :no_channels_remaining}
  """
  @spec decide(term(), [Channel.t()]) :: decision()
  def decide(error, rest_channels) do
    case should_fast_fail_error?(error, rest_channels) do
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
    # Log fast-fail event
    Logger.info("Fast-failing to next channel",
      channel: Channel.to_string(channel),
      error_category: extract_error_category(error),
      reason: failover_reason,
      remaining_channels: length(rest_channels),
      chain: ctx.chain
    )

    # Record observability events
    Observability.record_fast_fail(ctx, channel, failover_reason, error)

    # Update context and try next channel
    ctx = RequestContext.increment_retries(ctx)
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
      channel: Channel.to_string(channel),
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
  # Returns:
  # - {true, reason} - Should fast-fail with reason
  # - {false, reason} - Should not failover (no channels or non-retriable)
  @spec should_fast_fail_error?(any(), list()) :: {boolean(), atom()}
  defp should_fast_fail_error?(_reason, []), do: {false, :no_channels_remaining}

  defp should_fast_fail_error?(%JError{retriable?: false}, _rest), do: {false, :non_retriable_error}

  defp should_fast_fail_error?(%JError{category: :rate_limit}, _rest), do: {true, :rate_limit_detected}
  defp should_fast_fail_error?(%JError{category: :server_error}, _rest), do: {true, :server_error_detected}
  defp should_fast_fail_error?(%JError{category: :network_error}, _rest), do: {true, :network_error_detected}
  defp should_fast_fail_error?(%JError{category: :auth_error}, _rest), do: {true, :auth_error_detected}
  defp should_fast_fail_error?(%JError{category: :capability_violation}, _rest), do: {true, :capability_violation_detected}
  defp should_fast_fail_error?(%JError{retriable?: true}, _rest), do: {true, :retriable_error}

  defp should_fast_fail_error?(:circuit_open, _rest), do: {true, :circuit_open}

  defp should_fast_fail_error?(_reason, _rest), do: {false, :unknown_error_format}

  # Extracts error category for telemetry and logging.
  @spec extract_error_category(any()) :: atom()
  defp extract_error_category(%JError{category: category}), do: category || :unknown
  defp extract_error_category(:circuit_open), do: :circuit_open
  defp extract_error_category(_), do: :unknown
end
