defmodule Livechain.RPC.WSSupervisor do
  @moduledoc false

  # Deprecated. This module is intentionally left as a stub to avoid compile-time
  # breakages during migration. Callers should use `Livechain.RPC.ChainRegistry`
  # and `Livechain.RPC.ChainSupervisor` flows. All functions now raise.

  def start_link(_opts \\ []), do: raise("WSSupervisor is deprecated")
  def start_connection(_endpoint), do: raise("WSSupervisor is deprecated")
  def stop_connection(_connection_id), do: raise("WSSupervisor is deprecated")
  def list_connections, do: raise("WSSupervisor is deprecated")
  def connection_status(_id), do: raise("WSSupervisor is deprecated")
  def send_message(_id, _message), do: raise("WSSupervisor is deprecated")
  def subscribe(_id, _topic), do: raise("WSSupervisor is deprecated")
  def broadcast_connection_status_update, do: raise("WSSupervisor is deprecated")
end
