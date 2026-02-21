defmodule Lasso.Core.Streaming.InstanceSubscriptionRegistry do
  @moduledoc """
  Registry for tracking consumers of instance-scoped upstream WebSocket subscriptions.

  Uses Elixir's Registry with `:duplicate` keys to allow multiple consumers
  (e.g., multiple UpstreamSubscriptionPools) per subscription.

  Keys are `{instance_id, sub_key}` tuples. Consumer processes are automatically
  unregistered when they exit.
  """

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    Registry.child_spec(
      keys: :duplicate,
      name: __MODULE__,
      partitions: System.schedulers_online()
    )
  end

  @spec register_consumer(String.t(), term()) :: :ok | {:error, term()}
  def register_consumer(instance_id, sub_key) do
    key = {instance_id, sub_key}
    pd_key = {:instance_sub_registered, key}

    if Process.get(pd_key) do
      :ok
    else
      case Registry.register(__MODULE__, key, %{
             subscribed_at: System.monotonic_time(:millisecond)
           }) do
        {:ok, _} ->
          Process.put(pd_key, true)
          :ok

        {:error, {:already_registered, _}} ->
          Process.put(pd_key, true)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec unregister_consumer(String.t(), term()) :: :ok
  def unregister_consumer(instance_id, sub_key) do
    key = {instance_id, sub_key}
    Process.delete({:instance_sub_registered, key})
    Registry.unregister(__MODULE__, key)
  end

  @spec dispatch(String.t(), term(), term()) :: :ok
  def dispatch(instance_id, sub_key, message) do
    Registry.dispatch(__MODULE__, {instance_id, sub_key}, fn entries ->
      for {pid, _meta} <- entries do
        send(pid, message)
      end
    end)
  end

  @spec count_consumers(String.t(), term()) :: non_neg_integer()
  def count_consumers(instance_id, sub_key) do
    Registry.count_match(__MODULE__, {instance_id, sub_key}, :_)
  end

  @spec has_consumers?(String.t(), term()) :: boolean()
  def has_consumers?(instance_id, sub_key) do
    count_consumers(instance_id, sub_key) > 0
  end
end
