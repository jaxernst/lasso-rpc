defmodule LassoWeb.RPCSocket.ItemOwner do
  @moduledoc false

  alias Lasso.Core.Request.ExecutionScope
  alias Lasso.Core.Streaming.SubscriptionRouter
  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.RPC.{RequestContext, RequestOptions, RequestPipeline}

  defmodule Work do
    @moduledoc false

    @enforce_keys [
      :chain_id,
      :method,
      :params,
      :profile,
      :strategy,
      :jsonrpc_id_present?,
      :started_at_us,
      :deadline_us,
      :timeout_ms
    ]
    defstruct @enforce_keys ++ [:provider_id, :jsonrpc_id, subscription_known?: false]

    @type t :: %__MODULE__{
            chain_id: pos_integer(),
            method: String.t(),
            params: list() | map(),
            profile: String.t(),
            strategy: atom(),
            provider_id: String.t() | nil,
            jsonrpc_id: integer() | String.t() | nil,
            jsonrpc_id_present?: boolean(),
            subscription_known?: boolean(),
            started_at_us: integer(),
            deadline_us: integer(),
            timeout_ms: pos_integer()
          }
  end

  @spec start(pid(), reference(), Work.t()) :: {:ok, pid()} | {:error, term()}
  def start(socket_pid, item_ref, %Work{} = work)
      when is_pid(socket_pid) and is_reference(item_ref) do
    Task.Supervisor.start_child(Lasso.TaskSupervisor, fn ->
      context =
        RequestContext.new(work.chain_id, work.method, work.params,
          transport: :ws,
          strategy: work.strategy,
          plug_start_time: work.started_at_us
        )

      opts = %RequestOptions{
        profile: work.profile,
        strategy: work.strategy,
        timeout_ms: work.timeout_ms,
        request_context: context,
        provider_override: work.provider_id,
        jsonrpc_id: work.jsonrpc_id,
        jsonrpc_id_present?: work.jsonrpc_id_present?
      }

      scope = ExecutionScope.monitored(self(), socket_pid, work.deadline_us)

      result = execute(work, scope, socket_pid, context, opts)

      send(socket_pid, {:rpc_item_result, item_ref, self(), result})
    end)
  catch
    :exit, _reason -> {:error, :supervisor_unavailable}
  end

  defp execute(%Work{method: "eth_subscribe"} = work, scope, socket_pid, context, _opts) do
    with_subscription_scope(scope, context, fn guard ->
      with {:ok, key} <- subscription_key(work.params),
           request_id <-
             SubscriptionRouter.subscribe_request(work.profile, work.chain_id, key,
               provider_id: work.provider_id,
               client_pid: socket_pid,
               request_owner_pid: self(),
               deadline_us: work.deadline_us
             ),
           {:ok, subscription_id} <-
             await_subscription_response(request_id, guard, work.deadline_us) do
        {:ok, {:subscription_added, subscription_id},
         RequestContext.record_success(context, subscription_id)}
      else
        {:error, %JError{} = error} ->
          {:error, error, RequestContext.record_error(context, error)}

        {:error, reason} ->
          error = subscription_error("Failed to create subscription", reason)
          {:error, error, RequestContext.record_error(context, error)}
      end
    end)
  end

  defp execute(
         %Work{method: "eth_unsubscribe", params: [subscription_id], subscription_known?: true} =
           work,
         scope,
         socket_pid,
         context,
         _opts
       ) do
    with_subscription_scope(scope, context, fn guard ->
      request_id =
        SubscriptionRouter.unsubscribe_checked_request(
          work.profile,
          work.chain_id,
          subscription_id,
          client_pid: socket_pid,
          request_owner_pid: self(),
          deadline_us: work.deadline_us
        )

      case await_subscription_response(request_id, guard, work.deadline_us) do
        {:ok, removed?} ->
          result = {:subscription_removed, subscription_id, removed?}
          {:ok, result, RequestContext.record_success(context, removed?)}

        {:error, reason} ->
          error = subscription_error("Failed to remove subscription", reason)
          {:error, error, RequestContext.record_error(context, error)}
      end
    end)
  end

  defp execute(
         %Work{method: "eth_unsubscribe", params: [_subscription_id]},
         scope,
         _socket_pid,
         context,
         _opts
       ) do
    with_subscription_scope(scope, context, fn _guard ->
      {:ok, {:subscription_missing, false}, RequestContext.record_success(context, false)}
    end)
  end

  defp execute(%Work{method: method}, scope, _socket_pid, context, _opts)
       when method in ["eth_subscribe", "eth_unsubscribe"] do
    with_subscription_scope(scope, context, fn _guard ->
      error = JError.new(-32_602, "Invalid subscription parameters", category: :invalid_params)
      {:error, error, RequestContext.record_error(context, error)}
    end)
  end

  defp execute(work, scope, _socket_pid, _context, opts) do
    RequestPipeline.execute_owned(
      scope,
      work.chain_id,
      work.method,
      work.params,
      opts
    )
  end

  defp subscription_key(["newHeads" | _rest]), do: {:ok, {:newHeads}}
  defp subscription_key(["logs"]), do: {:ok, {:logs, %{}}}
  defp subscription_key(["logs", filter | _rest]) when is_map(filter), do: {:ok, {:logs, filter}}

  defp subscription_key(_params) do
    {:error, JError.new(-32_602, "Invalid subscription parameters", category: :invalid_params)}
  end

  defp subscription_error(message, reason) do
    JError.new(-32_000, message,
      category: :server_error,
      retriable?: false,
      breaker_penalty?: false,
      data: %{reason: bounded_reason(reason)}
    )
  end

  defp bounded_reason(reason) when reason in [:not_found, :timeout, :unavailable], do: reason
  defp bounded_reason(_reason), do: :subscription_failed

  defp with_subscription_scope(scope, context, operation) do
    guard = ExecutionScope.open(scope)

    try do
      if ExecutionScope.caller_alive?(guard) and
           System.monotonic_time(:microsecond) < ExecutionScope.deadline_us(scope) do
        operation.(guard)
      else
        error = subscription_error("Subscription request is no longer authorized", :unavailable)
        {:error, error, RequestContext.record_error(context, error)}
      end
    after
      ExecutionScope.close(guard)
    end
  end

  defp await_subscription_response(request_id, guard, deadline_us) do
    caller_monitor = ExecutionScope.caller_monitor(guard)

    receive do
      {:DOWN, monitor, :process, _caller_pid, _reason}
      when monitor == caller_monitor ->
        exit(:caller_down)

      message ->
        case SubscriptionRouter.check_response(message, request_id) do
          {:reply, reply} -> settle_subscription_response(reply, guard, deadline_us)
          {:error, _reason} -> exit(:subscription_owner_down)
          :no_reply -> await_subscription_response(request_id, guard, deadline_us)
        end
    after
      remaining_ms(deadline_us) -> exit(:deadline_expired)
    end
  end

  defp settle_subscription_response(reply, guard, deadline_us) do
    if ExecutionScope.caller_alive?(guard) and
         System.monotonic_time(:microsecond) < deadline_us do
      reply
    else
      exit(:deadline_expired)
    end
  end

  defp remaining_ms(deadline_us) do
    max(div(deadline_us - System.monotonic_time(:microsecond) + 999, 1_000), 0)
  end
end
