defmodule Lasso.ProfileChainSupervisor do
  @moduledoc """
  DynamicSupervisor for profile-scoped chain instances.

  Manages ChainSupervisor processes for each (profile, chain_id) pair. Each profile
  gets its own set of chain supervisors with full isolation. All components
  (BlockSync, WebSocket connections) are scoped per (profile, chain_id).
  """

  use DynamicSupervisor
  require Logger

  ## Client API

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start a ChainSupervisor for a specific profile and chain.

  Creates a complete supervisor tree for the (profile, chain_id) pair, including
  all providers, BlockSync, HealthProbe, and subscription management.

  Returns `{:ok, pid}` on success or `{:error, reason}` on failure.
  """
  @spec start_profile_chain(String.t(), pos_integer(), map()) :: {:ok, pid()} | {:error, term()}
  def start_profile_chain(profile_id, chain_id, chain_config)
      when is_binary(profile_id) and is_integer(chain_id) and chain_id > 0 do
    spec = {Lasso.RPC.ChainSupervisor, {profile_id, chain_id, chain_config}}

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} ->
        Logger.info(
          "Started chain supervisor",
          Lasso.Logging.profile_metadata(profile_id) ++ [chain_id: chain_id]
        )

        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} = error ->
        Logger.error(
          "Failed to start chain supervisor",
          Lasso.Logging.profile_metadata(profile_id) ++
            [chain_id: chain_id, reason: inspect(reason)]
        )

        error
    end
  end

  @doc """
  Stop a ChainSupervisor for a specific profile and chain.

  This gracefully terminates the chain supervisor and all its children.
  """
  @spec stop_profile_chain(String.t(), pos_integer()) :: :ok
  def stop_profile_chain(profile_id, chain_id)
      when is_binary(profile_id) and is_integer(chain_id) and chain_id > 0 do
    case GenServer.whereis(chain_supervisor_via(profile_id, chain_id)) do
      nil ->
        :ok

      pid ->
        case DynamicSupervisor.terminate_child(__MODULE__, pid) do
          :ok ->
            Logger.info(
              "Stopped chain supervisor",
              Lasso.Logging.profile_metadata(profile_id) ++ [chain_id: chain_id]
            )

            :ok

          {:error, :not_found} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Failed to terminate chain supervisor",
              Lasso.Logging.profile_metadata(profile_id) ++
                [chain_id: chain_id, reason: inspect(reason)]
            )

            {:error, reason}
        end
    end
  end

  @doc """
  List all running chain_ids that have running supervisors for a profile.
  """
  @spec list_profile_chains(String.t()) :: [pos_integer()]
  def list_profile_chains(profile) when is_binary(profile) do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.flat_map(fn {_, pid, _, _} ->
      case Registry.keys(Lasso.Registry, pid) do
        [{:chain_supervisor, ^profile, chain_id}] -> [chain_id]
        _ -> []
      end
    end)
  end

  @doc """
  List all running profile-chain pairs.

  Returns a list of `{profile, chain_id}` tuples.
  """
  @spec list_all() :: [{String.t(), pos_integer()}]
  def list_all do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.flat_map(fn {_, pid, _, _} ->
      case Registry.keys(Lasso.Registry, pid) do
        [{:chain_supervisor, profile, chain_id}] -> [{profile, chain_id}]
        _ -> []
      end
    end)
  end

  @doc """
  Check if a chain supervisor is running for a profile.
  """
  @spec running?(String.t(), pos_integer()) :: boolean()
  def running?(profile, chain_id)
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    GenServer.whereis(chain_supervisor_via(profile, chain_id)) != nil
  end

  ## DynamicSupervisor Callbacks

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  ## Private Functions

  defp chain_supervisor_via(profile, chain_id) do
    {:via, Registry, {Lasso.Registry, {:chain_supervisor, profile, chain_id}}}
  end
end
