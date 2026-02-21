defmodule Lasso.RPC.RequestPipeline.FailoverStrategy do
  @moduledoc """
  Centralized failover decision logic for the request pipeline.

  This module owns the decision of whether to failover to another channel
  or treat an error as terminal. The actual failover execution is handled
  by the RequestPipeline.

  ## Decision Priority (clause ordering)

  Category-specific handlers run first, then generic retriability as fallback:

  1. No channels remaining → terminal
  2. `:client_error` → conditional failover (threshold 1)
  3. `:capability_violation` → conditional failover (threshold 2)
  4. `:method_not_found` → conditional failover (threshold 2)
  5. `:rate_limit` → failover
  6. `:server_error` → failover
  7. `:network_error` → failover
  8. `:auth_error` → failover
  9. `:timeout` → failover
  10. `retriable? = true` (generic) → failover
  11. `:circuit_open` → failover
  12. `retriable? = false` (generic fallback) → terminal
  13. Unknown format → terminal

  ## Smart Failover Detection

  To minimize latency variance, the strategy detects when the same error category
  occurs repeatedly across multiple providers (e.g., "query returned more than 10000 results").
  After a threshold, it assumes the error is universal and fails fast.

  ## Client Error Safety Net

  HTTP 4xx errors classified as `:client_error` are non-retriable by default, but the
  category is ambiguous — it's the catch-all for any 4xx that isn't a specific JSON-RPC
  standard code. A dead provider returning 400 for all requests looks like a client error.

  To handle this, `:client_error` gets one failover attempt (threshold 1). If two providers
  return the same class of error, it's almost certainly a real client error.

  Note: `track_error_category` is called in `handle_channel_error` (request_pipeline.ex)
  AFTER `FailoverStrategy.decide`, so the count seen by `decide` reflects errors from
  previous attempts, not the current one. This is what makes threshold=1 give exactly
  one failover attempt.
  """

  @client_error_failover_threshold 1
  @repeated_capability_violation_threshold 2

  require Logger

  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.RPC.{Channel, RequestContext}

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

  defp should_failover?(%JError{category: :client_error} = error, _rest, ctx) do
    # Count reflects errors from PREVIOUS attempts only — track_error_category
    # is called after decide() in request_pipeline.ex handle_channel_error.
    repeated_count = RequestContext.get_error_category_count(ctx, :client_error)

    if repeated_count >= @client_error_failover_threshold do
      Logger.warning("Repeated client error across providers - treating as terminal",
        request_id: ctx.request_id,
        error_message: error.message,
        method: ctx.method,
        repeated_count: repeated_count,
        chain: ctx.chain
      )

      {false, :repeated_client_error}
    else
      {true, :client_error_failover}
    end
  end

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

  defp should_failover?(%JError{category: :method_not_found} = error, _rest, ctx) do
    repeated_count = RequestContext.get_error_category_count(ctx, :method_not_found)

    if repeated_count >= @repeated_capability_violation_threshold do
      Logger.warning("Repeated method_not_found - assuming universal unsupported method",
        request_id: ctx.request_id,
        error_message: error.message,
        method: ctx.method,
        repeated_count: repeated_count,
        threshold: @repeated_capability_violation_threshold,
        chain: ctx.chain
      )

      {false, :universal_method_not_found}
    else
      {true, :method_not_found_detected}
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

  defp should_failover?(%JError{retriable?: false}, _rest, _ctx),
    do: {false, :non_retriable_error}

  defp should_failover?(_reason, _rest, _ctx), do: {false, :unknown_error_format}
end
