defmodule Livechain.RPC.ProcessRegistry do
  @moduledoc """
  Centralized process registry for Livechain RPC components.

  Provides consistent naming and lookup for all RPC processes,
  replacing global registry usage with a more robust solution.
  """

  use GenServer
  require Logger

  defstruct [
    :registry_name,
    processes: %{}
  ]

  @doc """
  Starts the process registry.
  """
  def start_link(opts \\ []) do
    registry_name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, registry_name, name: registry_name)
  end

  @doc """
  Registers a process with a unique name.
  """
  def register(registry_name, process_type, identifier, pid) do
    GenServer.call(registry_name, {:register, process_type, identifier, pid})
  end

  @doc """
  Looks up a process by type and identifier.
  """
  def lookup(registry_name, process_type, identifier) do
    GenServer.call(registry_name, {:lookup, process_type, identifier})
  end

  @doc """
  Unregisters a process.
  """
  def unregister(registry_name, process_type, identifier) do
    GenServer.cast(registry_name, {:unregister, process_type, identifier})
  end

  @doc """
  Gets all processes of a specific type.
  """
  def list_processes(registry_name, process_type) do
    GenServer.call(registry_name, {:list_processes, process_type})
  end

  # GenServer callbacks

  @impl true
  def init(registry_name) do
    {:ok, %__MODULE__{registry_name: registry_name}}
  end

  @impl true
  def handle_call({:register, process_type, identifier, pid}, _from, state) do
    key = {process_type, identifier}

    case Map.get(state.processes, key) do
      nil ->
        # Monitor the process
        Process.monitor(pid)
        new_processes = Map.put(state.processes, key, pid)
        new_state = %{state | processes: new_processes}
        Logger.debug("Registered #{process_type}:#{identifier} -> #{inspect(pid)}")
        {:reply, :ok, new_state}

      existing_pid ->
        if Process.alive?(existing_pid) do
          {:reply, {:error, :already_registered}, state}
        else
          # Process died, replace it
          Process.monitor(pid)
          new_processes = Map.put(state.processes, key, pid)
          new_state = %{state | processes: new_processes}
          Logger.info("Replaced dead process #{process_type}:#{identifier}")
          {:reply, :ok, new_state}
        end
    end
  end

  @impl true
  def handle_call({:lookup, process_type, identifier}, _from, state) do
    key = {process_type, identifier}

    case Map.get(state.processes, key) do
      nil ->
        {:reply, {:error, :not_found}, state}

      pid ->
        if Process.alive?(pid) do
          {:reply, {:ok, pid}, state}
        else
          # Process died, clean up
          new_processes = Map.delete(state.processes, key)
          new_state = %{state | processes: new_processes}
          {:reply, {:error, :process_dead}, new_state}
        end
    end
  end

  @impl true
  def handle_call({:list_processes, process_type}, _from, state) do
    processes =
      state.processes
      |> Enum.filter(fn {{type, _}, _} -> type == process_type end)
      |> Enum.map(fn {{_type, identifier}, pid} -> {identifier, pid} end)
      |> Enum.into(%{})

    {:reply, processes, state}
  end

  @impl true
  def handle_cast({:unregister, process_type, identifier}, state) do
    key = {process_type, identifier}
    new_processes = Map.delete(state.processes, key)
    new_state = %{state | processes: new_processes}
    Logger.debug("Unregistered #{process_type}:#{identifier}")
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Find and remove the dead process
    {key, _} = Enum.find(state.processes, {nil, nil}, fn {_k, p} -> p == pid end)

    if key do
      {process_type, identifier} = key
      new_processes = Map.delete(state.processes, key)
      new_state = %{state | processes: new_processes}
      Logger.info("Process #{process_type}:#{identifier} died, removed from registry")
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  # Convenience functions for common process types

  def via_name(registry_name, process_type, identifier) do
    {:via, GenServer, {registry_name, {:lookup, process_type, identifier}}}
  end

  def chain_supervisor_name(chain_name) do
    via_name(Livechain.RPC.ProcessRegistry, :chain_supervisor, chain_name)
  end

  def message_aggregator_name(chain_name) do
    via_name(Livechain.RPC.ProcessRegistry, :message_aggregator, chain_name)
  end

  def provider_pool_name(chain_name) do
    via_name(Livechain.RPC.ProcessRegistry, :provider_pool, chain_name)
  end

  def ws_connection_name(connection_id) do
    via_name(Livechain.RPC.ProcessRegistry, :ws_connection, connection_id)
  end
end
