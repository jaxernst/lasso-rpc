defmodule Lasso.BlockSync.Supervisor do
  @moduledoc """
  Singleton interface to the BlockSync DynamicSupervisor.

  Manages one Worker per (chain, instance_id) pair. Workers are started
  during `start_shared_infrastructure` and can be added/removed at runtime.
  """

  require Logger

  alias Lasso.BlockSync.Worker

  @dynamic_supervisor Lasso.BlockSync.DynamicSupervisor

  @spec start_worker(String.t(), String.t()) :: {:ok, pid()} | {:error, term()}
  def start_worker(chain, instance_id) when is_binary(chain) and is_binary(instance_id) do
    spec = {Worker, {chain, instance_id}}

    case DynamicSupervisor.start_child(@dynamic_supervisor, spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} ->
        Logger.warning("Failed to start BlockSync worker",
          chain: chain,
          instance_id: instance_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  @spec stop_worker(String.t(), String.t()) :: :ok | {:error, term()}
  def stop_worker(chain, instance_id) when is_binary(chain) and is_binary(instance_id) do
    case GenServer.whereis(Worker.via(chain, instance_id)) do
      nil ->
        :ok

      pid ->
        case DynamicSupervisor.terminate_child(@dynamic_supervisor, pid) do
          :ok -> :ok
          {:error, _} = error -> error
        end
    end
  end

  @spec start_all_workers(String.t(), [String.t()]) :: :ok
  def start_all_workers(chain, instance_ids)
      when is_binary(chain) and is_list(instance_ids) do
    Logger.info("Starting BlockSync workers",
      chain: chain,
      instance_count: length(instance_ids)
    )

    Enum.each(instance_ids, fn instance_id ->
      start_worker(chain, instance_id)
    end)
  end

  @spec list_workers() :: [pid()]
  def list_workers do
    DynamicSupervisor.which_children(@dynamic_supervisor)
    |> Enum.map(fn {_, pid, _, _} -> pid end)
    |> Enum.reject(&is_nil/1)
  end
end
