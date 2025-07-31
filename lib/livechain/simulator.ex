defmodule Livechain.Simulator do
  @moduledoc """
  WebSocket Connection Simulator for real-time dashboard demonstration.

  This module provides dynamic simulation of blockchain WebSocket connections
  to demonstrate the real-time capabilities of the LiveView dashboard.
  """

  use GenServer
  require Logger

  alias Livechain.RPC.{WSSupervisor, MockWSEndpoint}
  alias Livechain.Config.MockConnections

  # Available blockchain networks for simulation - now using comprehensive config
  @available_chains [
    {:ethereum, &MockWSEndpoint.ethereum_mainnet/1},
    {:polygon, &MockWSEndpoint.polygon/1},
    {:arbitrum, &MockWSEndpoint.arbitrum/1},
    {:bsc, &MockWSEndpoint.bsc/1}
  ]

  # Simulation configurations by mode
  @simulation_configs %{
    "normal" => %{
      min_connection_lifetime: 5_000,
      max_connection_lifetime: 30_000,
      min_spawn_interval: 2_000,
      max_spawn_interval: 8_000,
      max_concurrent_connections: 6,
      connection_failure_rate: 0.15,
      reconnection_probability: 0.7,
      enable_event_broadcasting: true,
      event_broadcast_interval: 3_000
    },
    "intense" => %{
      min_connection_lifetime: 2_000,
      max_connection_lifetime: 10_000,
      min_spawn_interval: 500,
      max_spawn_interval: 2_000,
      max_concurrent_connections: 12,
      connection_failure_rate: 0.25,
      reconnection_probability: 0.8,
      enable_event_broadcasting: true,
      event_broadcast_interval: 1_500
    },
    "calm" => %{
      min_connection_lifetime: 20_000,
      max_connection_lifetime: 60_000,
      min_spawn_interval: 8_000,
      max_spawn_interval: 15_000,
      max_concurrent_connections: 4,
      connection_failure_rate: 0.05,
      reconnection_probability: 0.9,
      enable_event_broadcasting: true,
      event_broadcast_interval: 5_000
    }
  }

  defstruct [
    :config,
    :mode,
    active_connections: %{},
    connection_timers: %{},
    spawn_timer: nil,
    event_timer: nil,
    stats: %{
      total_spawned: 0,
      total_stopped: 0,
      total_failures: 0,
      total_reconnections: 0
    }
  ]

  ## Client API

  def start_link(opts \\ []) do
    mode = Keyword.get(opts, :mode, "normal")
    GenServer.start_link(__MODULE__, mode, name: __MODULE__)
  end

  def start_simulation do
    GenServer.cast(__MODULE__, :start_simulation)
  end

  def stop_simulation do
    GenServer.cast(__MODULE__, :stop_simulation)
  end

  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  def get_mode do
    GenServer.call(__MODULE__, :get_mode)
  end

  def switch_mode(new_mode) when new_mode in ["normal", "intense", "calm"] do
    GenServer.cast(__MODULE__, {:switch_mode, new_mode})
  end

  def update_config(new_config) do
    GenServer.cast(__MODULE__, {:update_config, new_config})
  end

  @doc """
  Starts all configured mock connections from the comprehensive chains.yml configuration.
  This provides a more realistic simulation environment.
  """
  def start_all_mock_connections do
    GenServer.cast(__MODULE__, :start_all_mock_connections)
  end

  def stop_all_mock_connections do
    GenServer.cast(__MODULE__, :stop_all_mock_connections)
  end

  ## GenServer Callbacks

  @impl true
  def init(mode) do
    config = Map.get(@simulation_configs, mode, @simulation_configs["normal"])

    state = %__MODULE__{
      config: config,
      mode: mode,
      stats: %{
        total_spawned: 0,
        total_stopped: 0,
        total_failures: 0,
        total_reconnections: 0
      }
    }

    Logger.debug("WebSocket Connection Simulator initialized (#{mode} mode)")

    {:ok, state}
  end

  @impl true
  def handle_cast(:start_simulation, state) do
    Logger.info("Starting WebSocket simulation (#{state.mode} mode)")

    # Cancel existing timers
    state = cancel_all_timers(state)

    # Schedule first connection spawn
    spawn_timer = schedule_next_spawn(state.config)

    # Schedule event broadcasting
    event_timer =
      if state.config.enable_event_broadcasting do
        schedule_event_broadcast(state.config.event_broadcast_interval)
      else
        nil
      end

    state = %{state | spawn_timer: spawn_timer, event_timer: event_timer}

    {:noreply, state}
  end

  @impl true
  def handle_cast(:stop_simulation, state) do
    Logger.info("Stopping WebSocket simulation")

    # Stop all active connections
    Enum.each(state.active_connections, fn {connection_id, _chain} ->
      WSSupervisor.stop_connection(connection_id)
    end)

    # Cancel all timers
    state = cancel_all_timers(state)

    state = %{
      state
      | active_connections: %{},
        connection_timers: %{},
        spawn_timer: nil,
        event_timer: nil
    }

    {:noreply, state}
  end

  @impl true
  def handle_cast({:switch_mode, new_mode}, state) do
    Logger.info("Switching simulation mode: #{state.mode} → #{new_mode}")

    # Stop current simulation
    GenServer.cast(self(), :stop_simulation)

    # Update config for new mode
    new_config = Map.get(@simulation_configs, new_mode, @simulation_configs["normal"])

    # Wait a moment then restart
    Process.send_after(self(), :restart_simulation, 1_000)

    state = %{state | mode: new_mode, config: new_config}
    {:noreply, state}
  end

  @impl true
  def handle_cast({:update_config, new_config}, state) do
    updated_config = Map.merge(state.config, new_config)
    Logger.debug("Updated simulator configuration: #{inspect(new_config)}")
    {:noreply, %{state | config: updated_config}}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats =
      Map.merge(state.stats, %{
        active_connections: map_size(state.active_connections),
        active_timers: map_size(state.connection_timers),
        mode: state.mode
      })

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:get_mode, _from, state) do
    {:reply, state.mode, state}
  end

  @impl true
  def handle_cast(:start_all_mock_connections, state) do
    Logger.info("Starting all configured mock WebSocket connections...")

    Task.start(fn ->
      case MockConnections.start_all_mock_connections() do
        {:ok, %{started: started, failed: failed}} ->
          Logger.info("Mock connections started: #{started} successful, #{failed} failed")

        {:error, reason} ->
          Logger.error("Failed to start mock connections: #{inspect(reason)}")
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast(:stop_all_mock_connections, state) do
    Logger.info("Stopping all mock WebSocket connections...")

    Task.start(fn ->
      case MockConnections.stop_all_mock_connections() do
        {:ok, %{stopped: stopped, failed: failed}} ->
          Logger.info("Mock connections stopped: #{stopped} successful, #{failed} failed")

        {:error, reason} ->
          Logger.error("Failed to stop mock connections: #{inspect(reason)}")
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(:restart_simulation, state) do
    GenServer.cast(self(), :start_simulation)
    {:noreply, state}
  end

  @impl true
  def handle_info(:spawn_connection, state) do
    state = spawn_random_connection(state)

    # Schedule next spawn
    spawn_timer = schedule_next_spawn(state.config)
    state = %{state | spawn_timer: spawn_timer}

    {:noreply, state}
  end

  @impl true
  def handle_info({:connection_lifecycle, connection_id}, state) do
    state = handle_connection_lifecycle(connection_id, state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:broadcast_events, state) do
    state = broadcast_simulated_events(state)

    # Schedule next event broadcast
    event_timer =
      if state.config.enable_event_broadcasting do
        schedule_event_broadcast(state.config.event_broadcast_interval)
      else
        nil
      end

    state = %{state | event_timer: event_timer}
    {:noreply, state}
  end

  @impl true
  def handle_info({:reconnect, _old_connection_id, chain_name}, state) do
    # Create new connection ID for reconnection
    timestamp = System.system_time(:millisecond)
    new_connection_id = "sim_#{chain_name}_#{timestamp}_reconnect"

    # Get the chain function
    {_, chain_fn} = Enum.find(@available_chains, fn {name, _} -> name == chain_name end)

    # Create new endpoint
    endpoint =
      chain_fn.(
        id: new_connection_id,
        name: "Sim #{String.capitalize("#{chain_name}")} (Reconnected)"
      )

    case WSSupervisor.start_connection(endpoint) do
      {:ok, _pid} ->
        Logger.debug("Reconnected #{chain_name}: #{new_connection_id}")

        # Schedule new lifecycle
        lifetime = random_lifetime(state.config)

        timer_ref =
          Process.send_after(self(), {:connection_lifecycle, new_connection_id}, lifetime)

        state = %{
          state
          | active_connections: Map.put(state.active_connections, new_connection_id, chain_name),
            connection_timers: Map.put(state.connection_timers, new_connection_id, timer_ref),
            stats: %{
              state.stats
              | total_reconnections: state.stats.total_reconnections + 1,
                total_spawned: state.stats.total_spawned + 1
            }
        }

        {:noreply, state}

      {:error, reason} ->
        Logger.warning("Reconnection failed for #{chain_name}: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  ## Private Functions

  defp spawn_random_connection(state) do
    # Don't spawn if we're at max capacity
    if map_size(state.active_connections) >= state.config.max_concurrent_connections do
      state
    else
      # Select random chain
      {chain_name, chain_fn} = Enum.random(@available_chains)

      # Create unique connection ID
      timestamp = System.system_time(:millisecond)
      connection_id = "sim_#{chain_name}_#{timestamp}"

      # Create endpoint with custom ID
      endpoint = chain_fn.(id: connection_id, name: "Sim #{String.capitalize("#{chain_name}")}")

      # Start the connection
      case WSSupervisor.start_connection(endpoint) do
        {:ok, _pid} ->
          Logger.debug("Spawned #{chain_name} connection: #{connection_id}")

          # Schedule connection lifecycle event
          lifetime = random_lifetime(state.config)
          timer_ref = Process.send_after(self(), {:connection_lifecycle, connection_id}, lifetime)

          # Update state
          state = %{
            state
            | active_connections: Map.put(state.active_connections, connection_id, chain_name),
              connection_timers: Map.put(state.connection_timers, connection_id, timer_ref),
              stats: %{state.stats | total_spawned: state.stats.total_spawned + 1}
          }

          state

        {:error, reason} ->
          Logger.warning("Failed to spawn #{chain_name} connection: #{inspect(reason)}")
          state
      end
    end
  end

  defp handle_connection_lifecycle(connection_id, state) do
    case Map.get(state.active_connections, connection_id) do
      nil ->
        # Connection already removed
        state

      chain_name ->
        # Determine if this is a failure or normal termination
        is_failure = :rand.uniform() < state.config.connection_failure_rate

        if is_failure do
          Logger.debug("Connection #{connection_id} (#{chain_name}) failed")

          state = %{
            state
            | stats: %{state.stats | total_failures: state.stats.total_failures + 1}
          }

          # Maybe reconnect
          if :rand.uniform() < state.config.reconnection_probability do
            # Schedule reconnection
            Process.send_after(self(), {:reconnect, connection_id, chain_name}, 2_000)
            Logger.debug("Scheduled reconnection for #{connection_id}")
          end

          stop_connection_and_cleanup(connection_id, state)
        else
          Logger.debug("Connection #{connection_id} (#{chain_name}) completed lifecycle")
          stop_connection_and_cleanup(connection_id, state)
        end
    end
  end

  defp stop_connection_and_cleanup(connection_id, state) do
    # Stop the connection
    WSSupervisor.stop_connection(connection_id)

    # Cancel timer if it exists
    case Map.get(state.connection_timers, connection_id) do
      nil -> :ok
      timer_ref -> Process.cancel_timer(timer_ref)
    end

    # Remove from state
    %{
      state
      | active_connections: Map.delete(state.active_connections, connection_id),
        connection_timers: Map.delete(state.connection_timers, connection_id),
        stats: %{state.stats | total_stopped: state.stats.total_stopped + 1}
    }
  end

  defp broadcast_simulated_events(state) do
    # Generate and broadcast realistic blockchain events
    if map_size(state.active_connections) > 0 do
      # Pick a random active connection to "generate" an event from
      {connection_id, chain_name} = Enum.random(state.active_connections)

      # Generate a realistic event (simplified version)
      event = %{
        event_type: Enum.random([:new_block, :new_transaction, :network_status]),
        chain: chain_name,
        connection_id: connection_id,
        timestamp: DateTime.utc_now(),
        data: %{simulated: true}
      }

      # Broadcast the event
      Phoenix.PubSub.broadcast(
        Livechain.PubSub,
        "simulator_events",
        {:new_event, event}
      )
    end

    state
  end

  defp random_lifetime(config) do
    min = config.min_connection_lifetime
    max = config.max_connection_lifetime
    min + :rand.uniform(max - min)
  end

  defp schedule_next_spawn(config) do
    interval =
      config.min_spawn_interval +
        :rand.uniform(config.max_spawn_interval - config.min_spawn_interval)

    Process.send_after(self(), :spawn_connection, interval)
  end

  defp schedule_event_broadcast(interval) do
    Process.send_after(self(), :broadcast_events, interval)
  end

  defp cancel_all_timers(state) do
    # Cancel spawn timer
    if state.spawn_timer, do: Process.cancel_timer(state.spawn_timer)

    # Cancel event timer
    if state.event_timer, do: Process.cancel_timer(state.event_timer)

    # Cancel all connection timers
    Enum.each(state.connection_timers, fn {_id, timer_ref} ->
      Process.cancel_timer(timer_ref)
    end)

    %{state | spawn_timer: nil, event_timer: nil, connection_timers: %{}}
  end
end
