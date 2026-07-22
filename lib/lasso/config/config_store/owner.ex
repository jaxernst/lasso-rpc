defmodule Lasso.Config.ConfigStore.Owner do
  @moduledoc false

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @spec schedule_delete(:ets.tid(), non_neg_integer()) :: :ok
  def schedule_delete(table, delay_ms) do
    GenServer.cast(__MODULE__, {:schedule_delete, table, delay_ms})
  end

  @impl true
  def init(state), do: {:ok, state, {:continue, :notify_config_store}}

  @impl true
  def handle_continue(:notify_config_store, state) do
    if pid = Process.whereis(Lasso.Config.ConfigStore) do
      send(pid, {:config_store_owner_restarted, self()})
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:schedule_delete, table, delay_ms}, state) do
    Process.send_after(self(), {:delete, table}, delay_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info({:"ETS-TRANSFER", _table, _from, :config_store}, state), do: {:noreply, state}

  def handle_info({:delete, table}, state) do
    case :ets.info(table, :owner) do
      owner when owner == self() -> :ets.delete(table)
      owner when is_pid(owner) -> send(owner, {:delete_old_table, table})
      _ -> :ok
    end

    {:noreply, state}
  rescue
    ArgumentError -> {:noreply, state}
  end
end
