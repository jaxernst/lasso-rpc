defmodule Lasso.RPC.StreamSupervisor do
  @moduledoc """
  Per-profile, per-chain DynamicSupervisor for StreamCoordinator processes.
  """

  use DynamicSupervisor

  alias Lasso.RPC.StreamCoordinator

  def start_link({profile, chain}) when is_binary(profile) and is_binary(chain) do
    DynamicSupervisor.start_link(__MODULE__, {profile, chain}, name: via(profile, chain))
  end

  def via(profile, chain) when is_binary(profile) and is_binary(chain) do
    {:via, Registry, {Lasso.Registry, {:stream_supervisor, profile, chain}}}
  end

  @impl true
  def init(_args) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def ensure_coordinator(profile, chain, key, opts)
      when is_binary(profile) and is_binary(chain) do
    name = StreamCoordinator.via(profile, chain, key)

    case GenServer.whereis(name) do
      nil ->
        spec = {StreamCoordinator, {profile, chain, key, opts}}

        case DynamicSupervisor.start_child(via(profile, chain), spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end

      pid ->
        {:ok, pid}
    end
  end

  def stop_coordinator(profile, chain, key) when is_binary(profile) and is_binary(chain) do
    name = StreamCoordinator.via(profile, chain, key)

    case GenServer.whereis(name) do
      nil ->
        :ok

      pid ->
        DynamicSupervisor.terminate_child(via(profile, chain), pid)
    end
  end
end
