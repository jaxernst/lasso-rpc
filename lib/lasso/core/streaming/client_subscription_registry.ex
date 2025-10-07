defmodule Lasso.RPC.ClientSubscriptionRegistry do
  @moduledoc """
  Per-chain registry that tracks client subscriptions and fans out events.

  Holds mappings:
    subscription_id → %{client_pid, key}
    key → [subscription_id]
  """

  use GenServer
  require Logger

  @type key :: {:newHeads} | {:logs, map()}

  def start_link(chain) when is_binary(chain) do
    GenServer.start_link(__MODULE__, chain, name: via(chain))
  end

  def via(chain), do: {:via, Registry, {Lasso.Registry, {:client_registry, chain}}}

  @spec add_client(String.t(), String.t(), pid(), key) :: :ok
  def add_client(chain, subscription_id, client_pid, key) do
    GenServer.call(via(chain), {:add, subscription_id, client_pid, key})
  end

  @spec remove_client(String.t(), String.t()) :: {:ok, key | nil}
  def remove_client(chain, subscription_id) do
    GenServer.call(via(chain), {:remove, subscription_id})
  end

  @spec list_by_key(String.t(), key) :: [String.t()]
  def list_by_key(chain, key) do
    GenServer.call(via(chain), {:list_by_key, key})
  end

  @spec dispatch(String.t(), key, map()) :: :ok
  def dispatch(chain, key, payload) do
    GenServer.cast(via(chain), {:dispatch, key, payload})
  end

  # GenServer callbacks

  @impl true
  def init(chain) do
    state = %{
      chain: chain,
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
      chain: state.chain,
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
          chain: state.chain,
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
    # Cleanup any subscriptions tied to this client process
    {removed, new_state} = remove_by_pid(state, pid)

    if removed > 0 do
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

    {length(to_remove), %{state | by_id: new_by_id, by_key: new_by_key}}
  end
end
