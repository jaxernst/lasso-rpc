defmodule Livechain.RPC.WSSupervisor do
  @moduledoc """
  A supervisor that manages multiple WebSocket connections to blockchain RPC endpoints.

  This supervisor uses a DynamicSupervisor to manage individual WebSocket connections.
  Each connection runs in its own process, providing fault isolation and independent
  lifecycle management.

  ## Architecture

  ```
  WSSupervisor (DynamicSupervisor)
  ├── WSConnection (GenServer) - Ethereum Mainnet
  ├── WSConnection (GenServer) - Polygon
  ├── WSConnection (GenServer) - Arbitrum
  └── ... (more connections)
  ```

  ## Benefits

  - **Fault Isolation**: One connection failure doesn't affect others
  - **Independent Lifecycle**: Each connection can be started/stopped independently
  - **Scalability**: Can handle hundreds of connections efficiently
  - **Monitoring**: Easy to monitor individual connection health
  """

  use DynamicSupervisor
  require Logger

  alias Livechain.RPC.{WSEndpoint, WSConnection}
  alias Livechain.Simulator.MockWSEndpoint

  # Client API

  @doc """
  Starts the WebSocket supervisor.

  ## Examples

      iex> {:ok, pid} = Livechain.RPC.WSSupervisor.start_link()
      iex> Process.alive?(pid)
      true
  """
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts a new WebSocket connection under the supervisor.

  ## Examples

      iex> endpoint = Livechain.RPC.WSEndpoint.new(...)
      iex> {:ok, pid} = Livechain.RPC.WSSupervisor.start_connection(endpoint)
      iex> Process.alive?(pid)
      true
  """
  def start_connection(%WSEndpoint{} = endpoint) do
    case validate_endpoint(endpoint) do
      {:ok, validated_endpoint} ->
        spec = {WSConnection, validated_endpoint}

        case DynamicSupervisor.start_child(__MODULE__, spec) do
          {:ok, pid} ->
            Logger.debug("Started WebSocket connection: #{endpoint.name}")

            broadcast_connection_event(:started, endpoint.id, %{
              id: endpoint.id,
              name: endpoint.name,
              status: :starting
            })

            broadcast_connection_status_update()
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            Logger.warning("WebSocket connection already started: #{endpoint.id}")
            {:ok, pid}

          {:error, reason} ->
            Logger.error("Failed to start WebSocket connection: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Invalid endpoint configuration: #{reason}")
        {:error, reason}
    end
  end

  @doc """
  Stops a WebSocket connection.

  ## Examples

      iex> Livechain.RPC.WSSupervisor.stop_connection("ethereum_ws")
      :ok
  """
  def stop_connection(connection_id) do
    case find_connection(connection_id) do
      {:ok, pid} ->
        Logger.debug("Stopping WebSocket connection: #{connection_id}")
        result = DynamicSupervisor.terminate_child(__MODULE__, pid)

        broadcast_connection_event(:stopped, connection_id, %{
          id: connection_id,
          status: :stopped
        })

        Task.start(fn -> broadcast_connection_status_update() end)
        result

      {:error, :not_found} ->
        Logger.warning("WebSocket connection not found: #{connection_id}")
        {:error, :not_found}
    end
  end

  @doc """
  Lists all active WebSocket connections.

  ## Examples

      iex> Livechain.RPC.WSSupervisor.list_connections()
      [
        %{id: "ethereum_ws", name: "Ethereum Mainnet", status: :connected},
        %{id: "polygon_ws", name: "Polygon", status: :connected}
      ]
  """
  def list_connections do
    __MODULE__
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn
      {_id, pid, :worker, [WSConnection]} ->
        get_connection_status(pid, WSConnection)

      {_id, _pid, :worker, [other]} ->
        %{id: "unknown", name: "Unknown (#{inspect(other)})", status: :unknown}
    end)
  end

  @doc """
  Gets the status of a specific WebSocket connection.

  ## Examples

      iex> Livechain.RPC.WSSupervisor.connection_status("ethereum_ws")
      %{connected: true, endpoint_id: "ethereum_ws", reconnect_attempts: 0}
  """
  def connection_status(connection_id) do
    case find_connection(connection_id) do
      {:ok, pid} ->
        GenServer.call(pid, :status)

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Sends a message to a specific WebSocket connection.

  ## Examples

      iex> Livechain.RPC.WSSupervisor.send_message("ethereum_ws", %{method: "eth_blockNumber"})
      :ok
  """
  def send_message(connection_id, message) do
    case find_connection(connection_id) do
      {:ok, pid} ->
        WSConnection.send_message(pid, message)

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Subscribes to a topic on a specific WebSocket connection.

  ## Examples

      iex> Livechain.RPC.WSSupervisor.subscribe("ethereum_ws", "newHeads")
      :ok
  """
  def subscribe(connection_id, topic) do
    case find_connection(connection_id) do
      {:ok, pid} ->
        WSConnection.subscribe(pid, topic)

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    Logger.debug("Starting WebSocket supervisor")

    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 10,
      max_seconds: 60
    )
  end

  @doc """
  Broadcasts connection status updates to all interested LiveViews.
  """
  def broadcast_connection_status_update do
    connections = list_connections()

    Phoenix.PubSub.broadcast(
      Livechain.PubSub,
      "ws_connections",
      {:connection_status_update, connections}
    )
  end

  # Private functions

  defp validate_endpoint(endpoint) do
    WSEndpoint.validate(endpoint)
  end

  defp broadcast_connection_event(event_type, connection_id, data) do
    Phoenix.PubSub.broadcast(
      Livechain.PubSub,
      "ws_connections",
      {:connection_event, event_type, connection_id, data}
    )
  end

  defp find_connection(connection_id) do
    case Registry.lookup(Livechain.Registry, {:ws_conn, connection_id}) do
      [{pid, _}] -> {:ok, pid}
      _ -> {:error, :not_found}
    end
  end

  defp get_connection_status(pid, _connection_module) do
    case Process.alive?(pid) do
      true ->
        status_result =
          try do
            GenServer.call(pid, :status, 5_000)
          catch
            :exit, {:timeout, _} ->
              %{connected: false, error: "status_timeout"}

            :exit, {:noproc, _} ->
              %{connected: false, error: "process_dead"}

            :exit, {reason, _} ->
              %{connected: false, error: "call_failed", reason: reason}
          end

        case status_result do
          %{connected: true} = status ->
            %{
              id: Map.get(status, :endpoint_id, "unknown"),
              name: Map.get(status, :endpoint_name, get_connection_name(pid)),
              status: :connected,
              reconnect_attempts: Map.get(status, :reconnect_attempts, 0),
              subscriptions: Map.get(status, :subscriptions, 0),
              last_seen: Map.get(status, :last_seen)
            }

          %{connected: false} = status ->
            %{
              id: Map.get(status, :endpoint_id, "unknown"),
              name: get_connection_name(pid),
              status: :disconnected,
              reconnect_attempts: Map.get(status, :reconnect_attempts, 0),
              last_seen: Map.get(status, :last_seen)
            }

          other ->
            %{
              id: "unknown",
              name: get_connection_name(pid),
              status: :unknown,
              details: other
            }
        end

      false ->
        %{id: "unknown", name: "Dead process", status: :dead}
    end
  end

  defp get_connection_name(pid) do
    # This would need to be implemented based on how we store connection metadata
    # For now, return a placeholder
    "Connection #{inspect(pid)}"
  end
end
