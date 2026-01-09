defmodule Lasso.Core.Streaming.StreamSupervisor do
  @moduledoc """
  Per-profile, per-chain DynamicSupervisor for StreamCoordinator processes.
  """

  use DynamicSupervisor

  alias Lasso.Core.Streaming.StreamCoordinator

  @spec start_link({String.t(), String.t()}) :: Supervisor.on_start()
  def start_link({profile, chain}) when is_binary(profile) and is_binary(chain) do
    DynamicSupervisor.start_link(__MODULE__, {profile, chain}, name: via(profile, chain))
  end

  @spec via(String.t(), String.t()) :: {:via, Registry, {atom(), tuple()}}
  def via(profile, chain) when is_binary(profile) and is_binary(chain) do
    {:via, Registry, {Lasso.Registry, {:stream_supervisor, profile, chain}}}
  end

  @impl true
  def init(_args) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec ensure_coordinator(String.t(), String.t(), term(), keyword()) :: {:ok, pid()} | {:error, term()}
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

  @spec stop_coordinator(String.t(), String.t(), term()) :: :ok | {:error, :not_found}
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
