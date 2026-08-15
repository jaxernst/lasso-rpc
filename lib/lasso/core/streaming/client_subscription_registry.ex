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

  @spec add_client_owned(
          String.t(),
          pos_integer(),
          String.t(),
          pid(),
          key,
          pid(),
          integer()
        ) :: :ok | {:error, :owner_down | :client_down | :deadline_expired}
  def add_client_owned(
        profile,
        chain_id,
        subscription_id,
        client_pid,
        key,
        request_owner_pid,
        deadline_us
      )
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    GenServer.call(
      via(profile, chain_id),
      {:add_owned, subscription_id, client_pid, key, request_owner_pid, deadline_us}
    )
  end

  @spec remove_client(String.t(), pos_integer(), String.t()) :: {:ok, key | nil}
  def remove_client(profile, chain_id, subscription_id)
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    GenServer.call(via(profile, chain_id), {:remove, subscription_id})
  end

  @spec remove_client_owned(
          String.t(),
          pos_integer(),
          String.t(),
          pid(),
          pid(),
          integer()
        ) :: {:ok, key | nil} | {:error, :owner_down | :client_down | :deadline_expired}
  def remove_client_owned(
        profile,
        chain_id,
        subscription_id,
        request_owner_pid,
        client_pid,
        deadline_us
      )
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    GenServer.call(
      via(profile, chain_id),
      {:remove_owned, subscription_id, request_owner_pid, client_pid, deadline_us}
    )
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
      by_key: %{},
      client_monitors: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:add, subscription_id, client_pid, key}, _from, state) do
    {:reply, :ok, add_client_to_state(state, subscription_id, client_pid, key)}
  end

  @impl true
  def handle_call(
        {:add_owned, subscription_id, client_pid, key, request_owner_pid, deadline_us},
        _from,
        state
      ) do
    case authorize_mutation(request_owner_pid, client_pid, deadline_us) do
      :ok ->
        {:reply, :ok, add_client_to_state(state, subscription_id, client_pid, key)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:remove, subscription_id}, _from, state) do
    {key, state} = remove_client_from_state(state, subscription_id)
    {:reply, {:ok, key}, state}
  end

  @impl true
  def handle_call(
        {:remove_owned, subscription_id, request_owner_pid, client_pid, deadline_us},
        _from,
        state
      ) do
    case authorize_mutation(request_owner_pid, client_pid, deadline_us) do
      :ok ->
        {key, state} = remove_client_from_state(state, subscription_id)
        {:reply, {:ok, key}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
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
  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    case state.client_monitors do
      %{^pid => ^monitor} ->
        {removed_by_key, new_state} = remove_by_pid(state, pid)
        removed = removed_by_key |> Map.values() |> Enum.sum()

        if removed > 0 do
          GenServer.cast(
            UpstreamSubscriptionPool.via(state.profile, state.chain_id),
            {:clients_removed, removed_by_key}
          )

          Logger.debug("Cleaned up #{removed} subscriptions for dead client pid")
        end

        {:noreply, %{new_state | client_monitors: Map.delete(new_state.client_monitors, pid)}}

      _stale ->
        {:noreply, state}
    end
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

  defp add_client_to_state(state, subscription_id, client_pid, key) do
    client_monitors =
      Map.put_new_lazy(state.client_monitors, client_pid, fn -> Process.monitor(client_pid) end)

    by_id = Map.put(state.by_id, subscription_id, %{client_pid: client_pid, key: key})

    by_key =
      Map.update(state.by_key, key, [subscription_id], fn ids -> [subscription_id | ids] end)

    %{state | by_id: by_id, by_key: by_key, client_monitors: client_monitors}
  end

  defp remove_client_from_state(state, subscription_id) do
    case Map.pop(state.by_id, subscription_id) do
      {nil, _} ->
        {nil, state}

      {%{client_pid: client_pid, key: key}, new_by_id} ->
        ids = Map.get(state.by_key, key, [])
        new_ids = Enum.reject(ids, &(&1 == subscription_id))

        new_by_key =
          if new_ids == [],
            do: Map.delete(state.by_key, key),
            else: Map.put(state.by_key, key, new_ids)

        client_monitors =
          maybe_release_client_monitor(state.client_monitors, new_by_id, client_pid)

        {key, %{state | by_id: new_by_id, by_key: new_by_key, client_monitors: client_monitors}}
    end
  end

  defp maybe_release_client_monitor(client_monitors, by_id, client_pid) do
    if Enum.any?(by_id, fn {_id, subscription} -> subscription.client_pid == client_pid end) do
      client_monitors
    else
      case Map.pop(client_monitors, client_pid) do
        {nil, remaining} ->
          remaining

        {monitor, remaining} ->
          Process.demonitor(monitor, [:flush])
          remaining
      end
    end
  end

  defp authorize_mutation(request_owner_pid, client_pid, deadline_us) do
    cond do
      not is_pid(request_owner_pid) or not Process.alive?(request_owner_pid) ->
        {:error, :owner_down}

      not is_pid(client_pid) or not Process.alive?(client_pid) ->
        {:error, :client_down}

      not is_integer(deadline_us) or System.monotonic_time(:microsecond) >= deadline_us ->
        {:error, :deadline_expired}

      true ->
        :ok
    end
  end
end
