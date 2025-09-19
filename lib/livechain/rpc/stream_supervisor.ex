defmodule Livechain.RPC.StreamSupervisor do
  @moduledoc """
  Per-chain DynamicSupervisor for StreamCoordinator processes.
  """

  use DynamicSupervisor

  alias Livechain.RPC.StreamCoordinator

  def start_link(chain) when is_binary(chain) do
    DynamicSupervisor.start_link(__MODULE__, chain, name: via(chain))
  end

  def via(chain), do: {:via, Registry, {Livechain.Registry, {:stream_supervisor, chain}}}

  @impl true
  def init(_chain) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def ensure_coordinator(chain, key, opts) do
    name = StreamCoordinator.via(chain, key)

    case GenServer.whereis(name) do
      nil ->
        spec = {StreamCoordinator, {chain, key, opts}}

        case DynamicSupervisor.start_child(via(chain), spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end

      pid ->
        {:ok, pid}
    end
  end
end
