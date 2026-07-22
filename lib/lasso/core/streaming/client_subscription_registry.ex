defmodule Lasso.Core.Streaming.ClientSubscriptionRegistry do
  @moduledoc """
  Per-profile registry that tracks client subscriptions and fans out events.

  Holds mappings:
    subscription_id → %{client_pid, key}
    key → [subscription_id]
  """

  use GenServer
  require Logger

  alias Lasso.Core.Streaming.UpstreamSubscriptionPool

  @type subscription_key :: {:newHeads} | {:logs, map()}
  @type key :: subscription_key() | {:route, String.t() | :routed, subscription_key()}

  @spec start_link({String.t(), pos_integer()}) :: GenServer.on_start()
  def start_link({profile, chain_id})
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    GenServer.start_link(__MODULE__, {profile, chain_id}, name: via(profile, chain_id))
  end

  @spec via(String.t(), pos_integer()) :: {:via, Registry, {atom(), tuple()}}
  def via(profile, chain_id)
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    {:via, Registry, {Lasso.Registry, {:client_registry, profile, chain_id}}}
  end

  @spec add_client(String.t(), pos_integer(), String.t(), pid(), key) :: :ok
  def add_client(profile, chain_id, subscription_id, client_pid, key)
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    GenServer.call(via(profile, chain_id), {:add, subscription_id, client_pid, key})
  end

  @spec remove_client(String.t(), pos_integer(), String.t()) :: {:ok, key | nil}
  def remove_client(profile, chain_id, subscription_id)
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    GenServer.call(via(profile, chain_id), {:remove, subscription_id})
  end

  @spec list_by_key(String.t(), pos_integer(), key) :: [String.t()]
  def list_by_key(profile, chain_id, key)
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    GenServer.call(via(profile, chain_id), {:list_by_key, key})
  end

  @spec dispatch(String.t(), pos_integer(), key, map()) :: :ok
  def dispatch(profile, chain_id, key, payload)
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    GenServer.cast(via(profile, chain_id), {:dispatch, key, payload})
  end

  # GenServer callbacks

  @impl true
  def init({profile, chain_id}) do
    state = %{
      profile: profile,
      chain_id: chain_id,
      by_id: %{},
      by_key: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:add, subscription_id, client_pid, key}, _from, state) do
    Process.monitor(client_pid)

    by_id = Map.put(state.by_id, subscription_id, %{client_pid: client_pid, key: key})

    by_key =
      Map.update(state.by_key, key, [subscription_id], fn ids -> [subscription_id | ids] end)

    :telemetry.execute([:lasso, :subs, :client_subscribe], %{count: 1}, %{
      chain_id: state.chain_id,
      subscription_id: subscription_id
    })

    {:reply, :ok, %{state | by_id: by_id, by_key: by_key}}
  end

  @impl true
  def handle_call({:remove, subscription_id}, _from, state) do
    case Map.pop(state.by_id, subscription_id) do
      {nil, _} ->
        {:reply, {:ok, nil}, state}

      {%{key: key}, new_by_id} ->
        ids = Map.get(state.by_key, key, [])
        new_ids = Enum.reject(ids, &(&1 == subscription_id))

        new_by_key =
          if new_ids == [],
            do: Map.delete(state.by_key, key),
            else: Map.put(state.by_key, key, new_ids)

        :telemetry.execute([:lasso, :subs, :client_unsubscribe], %{count: 1}, %{
          chain_id: state.chain_id,
          subscription_id: subscription_id
        })

        {:reply, {:ok, key}, %{state | by_id: new_by_id, by_key: new_by_key}}
    end
  end

  @impl true
  def handle_call({:list_by_key, key}, _from, state) do
    {:reply, Map.get(state.by_key, key, []), state}
  end

  @impl true
  def handle_cast({:dispatch, key, payload}, state) do
    ids = Map.get(state.by_key, key, [])

    Logger.debug(
      "Dispatching to #{length(ids)} clients for key #{inspect(key)}, subscription_ids=#{inspect(ids)}"
    )

    Enum.each(ids, fn subscription_id ->
      case Map.get(state.by_id, subscription_id) do
        nil ->
          Logger.warning("Subscription ID #{subscription_id} not found in by_id registry")

        %{client_pid: pid} ->
          notification = %{
            "jsonrpc" => "2.0",
            "method" => "eth_subscription",
            "params" => %{
              "subscription" => subscription_id,
              "result" => payload
            }
          }

          send(pid, {:subscription_event, notification})
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _mref, :process, pid, _reason}, state) do
    {removed_by_key, new_state} = remove_by_pid(state, pid)
    removed = removed_by_key |> Map.values() |> Enum.sum()

    if removed > 0 do
      GenServer.cast(
        UpstreamSubscriptionPool.via(state.profile, state.chain_id),
        {:clients_removed, removed_by_key}
      )

      Logger.debug("Cleaned up #{removed} subscriptions for dead client pid")
    end

    {:noreply, new_state}
  end

  defp remove_by_pid(state, pid) do
    {to_remove, keep} = Enum.split_with(state.by_id, fn {_id, %{client_pid: cp}} -> cp == pid end)

    new_by_id = Map.new(keep)

    new_by_key =
      Enum.reduce(to_remove, state.by_key, fn {subscription_id, %{key: key}}, acc ->
        ids = Map.get(acc, key, [])
        new_ids = Enum.reject(ids, &(&1 == subscription_id))
        if new_ids == [], do: Map.delete(acc, key), else: Map.put(acc, key, new_ids)
      end)

    removed_by_key =
      Enum.reduce(to_remove, %{}, fn {_subscription_id, %{key: key}}, acc ->
        Map.update(acc, key, 1, &(&1 + 1))
      end)

    {removed_by_key, %{state | by_id: new_by_id, by_key: new_by_key}}
  end
end
