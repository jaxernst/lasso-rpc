defmodule Lasso.Core.Request.TransactionConfirmation do
  @moduledoc """
  Confirms rejected raw transactions with a single lookup and decorates transaction send errors.
  """

  alias Lasso.Core.Request.ExecutionScope
  alias Lasso.Core.Support.TransactionOutcome
  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.RPC.{AttemptTerminal, ExecutionEnvelope, RequestContext, Selection}
  alias Lasso.RPC.Response.{Capacity, Success}

  @doc "Confirms the send outcome and attaches transaction policy metadata to errors."
  @spec confirm(
          Lasso.RPC.RequestPipeline.result(),
          ExecutionScope.t(),
          ExecutionScope.CallerGuard.t() | nil,
          (ExecutionScope.t(), pos_integer(), String.t(), list(), Lasso.RPC.RequestOptions.t() ->
             Lasso.RPC.RequestPipeline.result()),
          (RequestContext.t() -> Lasso.RPC.Channel.t() | nil)
        ) :: Lasso.RPC.RequestPipeline.result()
  def confirm(result, scope, guard, execute, response_channel) do
    result
    |> confirm_raw_transaction(scope, guard, execute, response_channel)
    |> decorate_send_error()
  end

  defp confirm_raw_transaction(
         {:error, %JError{category: :provider_error} = error,
          %{
            execution_envelope: %{execution_safety: :raw_transaction_broadcast, dispatch_count: 0},
            routing_capture: {:ok, _, %{transactions: policy}}
          } = ctx},
         _scope,
         _guard,
         _execute,
         _response_channel
       )
       when not is_nil(policy),
       do: {:error, transaction_error_hint(error, ctx), ctx}

  defp confirm_raw_transaction(
         {:error, %JError{category: :invalid_params} = error,
          %{method: "eth_sendRawTransaction", execution_envelope: %{dispatch_count: 0}} = ctx},
         _scope,
         _guard,
         _execute,
         _response_channel
       ),
       do: {:error, transaction_error_hint(error, ctx), ctx}

  defp confirm_raw_transaction(
         {:error, error,
          %{
            method: "eth_sendRawTransaction",
            routing_capture: {:ok, _, %{transactions: policy}},
            execution_envelope: %{dispatch_count: 0}
          } = ctx},
         _scope,
         _guard,
         _execute,
         _response_channel
       )
       when not is_nil(policy),
       do: {:error, transaction_error_hint(error, ctx), ctx}

  # A single lookup is shared by every terminal sendRaw rejection. Pinning the
  # selected transport prevents read failover from turning it into peer checks.
  defp confirm_raw_transaction(
         {:error, error, %{method: "eth_sendRawTransaction"} = ctx},
         scope,
         guard,
         execute,
         response_channel
       ) do
    hash = TransactionOutcome.hash(ctx.params)
    channel = transaction_lookup_channel(ctx, hash, response_channel)
    remaining = ExecutionEnvelope.remaining_ms(ctx.execution_envelope)

    found? =
      if hash && channel && remaining > 0 && ExecutionScope.caller_alive?(guard) do
        opts = %{
          ctx.opts
          | profile: channel.profile,
            captured_channel: channel,
            provider_override: nil,
            transport: channel.transport,
            request_origin: :system,
            timeout_ms: remaining,
            request_context: nil,
            plug_start_time: nil
        }

        case execute.(scope, ctx.chain_id, "eth_getTransactionByHash", [hash], opts) do
          {:ok, %Success{} = response, _lookup_ctx} ->
            found =
              case Jason.decode(response.raw_bytes) do
                {:ok, %{"result" => %{"hash" => returned_hash}}} when is_binary(returned_hash) ->
                  String.downcase(returned_hash) == hash

                _ ->
                  false
              end

            Success.release_capacity(response, :transaction_lookup)
            found

          {:error, lookup_error, _lookup_ctx} ->
            Capacity.release(lookup_error, :transaction_lookup)
            false

          _ ->
            false
        end
      else
        false
      end

    :telemetry.execute([:lasso, :rpc, :transaction_lookup], %{count: 1}, %{
      chain_id: ctx.chain_id,
      profile: ctx.routing_profile,
      result: if(found?, do: :found, else: :not_found)
    })

    if found? do
      Capacity.release(error, :transaction_found)

      response = %Success{
        id: ctx.opts.jsonrpc_id,
        jsonrpc: "2.0",
        raw_bytes: Jason.encode!(%{jsonrpc: "2.0", id: ctx.opts.jsonrpc_id, result: hash})
      }

      ctx = ctx |> RequestContext.record_success(response) |> Map.put(:error, nil)
      {:ok, response, %{ctx | terminal_reason: :transaction_found, public_response_attempt: nil}}
    else
      {:error, transaction_error_hint(error, ctx), ctx}
    end
  end

  defp confirm_raw_transaction(result, _scope, _guard, _execute, _response_channel), do: result

  defp decorate_send_error({:error, %JError{} = error, ctx} = result) do
    case RequestContext.send_policy_metadata(ctx) do
      nil ->
        result

      policy ->
        data = Map.put(TransactionOutcome.data_map(error.data), :send_policy, policy)
        {:error, %{error | data: data, raw_response: nil}, ctx}
    end
  end

  defp decorate_send_error(result), do: result

  defp transaction_lookup_channel(
         %{terminal_attempt_fact: %AttemptTerminal.Response{}} = ctx,
         _hash,
         response_channel
       ) do
    response_channel.(ctx)
  end

  defp transaction_lookup_channel(ctx, hash, _response_channel) do
    Selection.select_channels(ctx.routing_profile, ctx.chain_id, "eth_getTransactionByHash",
      captured_selection: ctx.routing_capture,
      execution_safety: ctx.execution_envelope.execution_safety,
      send_phase: ctx.send_phase,
      strategy: ctx.opts.strategy,
      transport: ctx.opts.transport || :both,
      limit: 1,
      request_origin: :system,
      params: [hash],
      deadline_us: ctx.execution_envelope.deadline_us
    )
    |> List.first()
  end

  defp transaction_error_hint(error, ctx) do
    transaction_provider_unavailable? =
      not is_nil(RequestContext.transaction_policy(ctx)) and
        ctx.execution_envelope.dispatch_count == 0 and
        error.category == :provider_error

    error =
      if transaction_provider_unavailable? do
        %{
          error
          | retriable?: true,
            data:
              Map.merge(TransactionOutcome.data_map(error.data), %{
                reason: :transaction_providers_unavailable
              })
        }
      else
        error
      end

    retryable? = error.retriable? == true

    next_action =
      if retryable? do
        "It is safe to resend the same signed transaction."
      else
        "Check this transaction's hash for a receipt before signing a new one, then address the cause in the error message before retrying."
      end

    data =
      TransactionOutcome.data_map(error.data)
      |> Map.drop(["retryable", "next_action", "code", "error_type", "request_id"])

    data =
      Map.merge(data, %{
        code: "provider_error",
        error_type:
          if(transaction_provider_unavailable?,
            do: "transaction_provider_unavailable",
            else: "transaction_rejection"
          ),
        request_id: ctx.request_id,
        retryable: retryable?,
        next_action: next_action
      })

    # Rebuild both HTTP and WS documents so raw passthrough cannot drop hints.
    message =
      if transaction_provider_unavailable?,
        do: transaction_provider_unavailable_message(ctx, data),
        else: error.message

    %{error | raw_response: nil, data: data, retriable?: retryable?, message: message}
  end

  defp transaction_provider_unavailable_message(ctx, data) do
    retry_ms = data[:retry_after_ms] || data["retry_after_ms"]
    retry = if retry_ms, do: " Retry after #{div(retry_ms + 999, 1000)}s.", else: ""

    fallback =
      if RequestContext.transaction_policy(ctx).fallback == "read_providers",
        do: "enabled",
        else: "disabled"

    "No transaction provider available on chain #{ctx.chain_id}: all #{length(RequestContext.transaction_policy(ctx).providers)} configured transaction providers are unavailable and read-provider fallback is #{fallback}." <>
      retry
  end
end
