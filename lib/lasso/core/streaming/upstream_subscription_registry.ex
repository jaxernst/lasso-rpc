defmodule Lasso.Core.Streaming.UpstreamSubscriptionRegistry do
  @moduledoc """
  Registry for tracking consumers of upstream WebSocket subscriptions.

  Uses Elixir's Registry with automatic process monitoring - when a consumer
  process dies, its registrations are automatically cleaned up.

  ## Key Format

  Keys are tuples of `{profile, chain, provider_id, sub_key}` where:
  - `profile` is the routing profile name (e.g., "default")
  - `chain` is the blockchain name (e.g., "ethereum")
  - `provider_id` is the provider identifier
  - `sub_key` is the subscription type: `{:newHeads}` or `{:logs, normalized_filter}`
  """

  @doc """
  Child spec for supervision tree.

  Uses `:duplicate` keys to allow multiple consumers per subscription.
  """
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    Registry.child_spec(
      keys: :duplicate,
      name: __MODULE__,
      partitions: System.schedulers_online()
    )
  end

  @doc """
  Register current process as a consumer of a subscription.
  """
  @spec register_consumer(String.t(), String.t(), String.t(), term()) :: :ok | {:error, term()}
  def register_consumer(profile, chain, provider_id, sub_key) do
    key = {profile, chain, provider_id, sub_key}
    pd_key = {:upstream_sub_registered, key}

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

  @doc """
  Unregister current process from a subscription.
  """
  @spec unregister_consumer(String.t(), String.t(), String.t(), term()) :: :ok
  def unregister_consumer(profile, chain, provider_id, sub_key) do
    key = {profile, chain, provider_id, sub_key}
    Process.delete({:upstream_sub_registered, key})
    Registry.unregister(__MODULE__, key)
  end

  @doc """
  Look up all consumers for a subscription.
  """
  @spec lookup_consumers(String.t(), String.t(), String.t(), term()) :: [{pid(), map()}]
  def lookup_consumers(profile, chain, provider_id, sub_key) do
    Registry.lookup(__MODULE__, {profile, chain, provider_id, sub_key})
  end

  @doc """
  Count the number of consumers for a subscription.
  """
  @spec count_consumers(String.t(), String.t(), String.t(), term()) :: non_neg_integer()
  def count_consumers(profile, chain, provider_id, sub_key) do
    Registry.count_match(__MODULE__, {profile, chain, provider_id, sub_key}, :_)
  end

  @doc """
  Dispatch a message to all consumers of a subscription.
  """
  @spec dispatch(String.t(), String.t(), String.t(), term(), term()) :: :ok
  def dispatch(profile, chain, provider_id, sub_key, message) do
    Registry.dispatch(__MODULE__, {profile, chain, provider_id, sub_key}, fn entries ->
      for {pid, _meta} <- entries do
        send(pid, message)
      end
    end)
  end

  @doc """
  Check if any consumers exist for a subscription.
  """
  @spec has_consumers?(String.t(), String.t(), String.t(), term()) :: boolean()
  def has_consumers?(profile, chain, provider_id, sub_key) do
    count_consumers(profile, chain, provider_id, sub_key) > 0
  end
end
