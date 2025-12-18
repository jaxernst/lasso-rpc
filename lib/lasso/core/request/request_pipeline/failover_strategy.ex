defmodule Lasso.RPC.RequestPipeline.FailoverStrategy do
  @moduledoc """
  Centralized failover decision logic for the request pipeline.

  This module owns the decision of whether to failover to another channel
  or treat an error as terminal. The actual failover execution is handled
  by the RequestPipeline.

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

  alias Lasso.RPC.{Channel, RequestContext}
  alias Lasso.JSONRPC.Error, as: JError

  @type decision :: {:failover, atom()} | {:terminal_error, atom()}

  @doc """
  Decides whether an error should trigger failover to the next channel.

  Takes into account:
  - Error retriability (retriable?: true/false)
  - Remaining channels available
  - Request context (repeated error tracking)

  Returns:
  - `{:failover, reason}` - Should fail over to next channel
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
    case should_failover?(error, rest_channels, ctx) do
      {true, reason} -> {:failover, reason}
      {false, reason} -> {:terminal_error, reason}
    end
  end

  # ============================================================================
  # Decision Logic
  # ============================================================================

  @spec should_failover?(any(), [Channel.t()], RequestContext.t()) :: {boolean(), atom()}
  defp should_failover?(_reason, [], _ctx), do: {false, :no_channels_remaining}

  defp should_failover?(%JError{retriable?: false}, _rest, _ctx),
    do: {false, :non_retriable_error}

  # Smart detection for capability violations (result size, block range, etc.)
  # If we've seen this error N times already, assume it's universal and stop
  defp should_failover?(%JError{category: :capability_violation} = error, _rest, ctx) do
    repeated_count = RequestContext.get_error_category_count(ctx, :capability_violation)

    if repeated_count >= @repeated_capability_violation_threshold do
      Logger.warning("Repeated capability violation - assuming universal limitation",
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

  defp should_failover?(%JError{category: :rate_limit}, _rest, _ctx),
    do: {true, :rate_limit_detected}

  defp should_failover?(%JError{category: :server_error}, _rest, _ctx),
    do: {true, :server_error_detected}

  defp should_failover?(%JError{category: :network_error}, _rest, _ctx),
    do: {true, :network_error_detected}

  defp should_failover?(%JError{category: :auth_error}, _rest, _ctx),
    do: {true, :auth_error_detected}

  defp should_failover?(%JError{category: :timeout}, _rest, _ctx),
    do: {true, :timeout_detected}

  defp should_failover?(%JError{retriable?: true}, _rest, _ctx),
    do: {true, :retriable_error}

  defp should_failover?(:circuit_open, _rest, _ctx), do: {true, :circuit_open}

  defp should_failover?(_reason, _rest, _ctx), do: {false, :unknown_error_format}
end
