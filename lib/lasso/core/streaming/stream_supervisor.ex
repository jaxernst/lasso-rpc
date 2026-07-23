defmodule Lasso.Core.Streaming.StreamSupervisor do
  @moduledoc """
  Per-profile, per-chain DynamicSupervisor for StreamCoordinator processes.
  """

  use DynamicSupervisor

  alias Lasso.Core.Streaming.StreamCoordinator

  @spec start_link({String.t(), pos_integer()}) :: Supervisor.on_start()
  def start_link({profile, chain_id})
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    DynamicSupervisor.start_link(__MODULE__, {profile, chain_id}, name: via(profile, chain_id))
  end

  @spec via(String.t(), pos_integer()) :: {:via, Registry, {atom(), tuple()}}
  def via(profile, chain_id)
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    {:via, Registry, {Lasso.Registry, {:stream_supervisor, profile, chain_id}}}
  end

  @impl true
  def init(_args) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec ensure_coordinator(String.t(), pos_integer(), term(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def ensure_coordinator(profile, chain_id, key, opts)
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    name = StreamCoordinator.via(profile, chain_id, key)

    case GenServer.whereis(name) do
      nil ->
        spec = {StreamCoordinator, {profile, chain_id, key, opts}}

        case DynamicSupervisor.start_child(via(profile, chain_id), spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end

      pid ->
        {:ok, pid}
    end
  end

  @spec stop_coordinator(String.t(), pos_integer(), term()) :: :ok | {:error, :not_found}
  def stop_coordinator(profile, chain_id, key)
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    name = StreamCoordinator.via(profile, chain_id, key)

    case GenServer.whereis(name) do
      nil ->
        :ok

      pid ->
        DynamicSupervisor.terminate_child(via(profile, chain_id), pid)
    end
  end
end
