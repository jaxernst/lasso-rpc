defmodule Lasso.ProfileChainSupervisor do
  @moduledoc """
  DynamicSupervisor for profile-scoped chain instances.

  Manages ChainSupervisor processes for each (profile, chain) pair. Each profile
  gets its own set of chain supervisors, enabling isolation between profiles
  while sharing global components (BlockSync, HealthProbe) via GlobalChainSupervisor.

  ## Architecture

  ```
  ProfileChainSupervisor (DynamicSupervisor)
  ├── ChainSupervisor {default, ethereum}
  ├── ChainSupervisor {default, polygon}
  ├── ChainSupervisor {premium, ethereum}
  └── ChainSupervisor {premium, arbitrum}
  ```

  ## Usage

  ```elixir
  # Start a chain for a profile
  ProfileChainSupervisor.start_profile_chain("premium", "ethereum", chain_config)

  # Stop a chain for a profile
  ProfileChainSupervisor.stop_profile_chain("premium", "ethereum")

  # List all chains for a profile
  ProfileChainSupervisor.list_profile_chains("premium")
  ```
  """

  use DynamicSupervisor
  require Logger

  ## Client API

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start a ChainSupervisor for a specific profile and chain.

  This should be called after `GlobalChainSupervisor.ensure_chain_processes/1`
  to ensure global components are running.

  Returns `{:ok, pid}` on success or `{:error, reason}` on failure.
  """
  @spec start_profile_chain(String.t(), String.t(), map()) :: {:ok, pid()} | {:error, term()}
  def start_profile_chain(profile, chain_name, chain_config)
      when is_binary(profile) and is_binary(chain_name) do
    spec = {Lasso.RPC.ChainSupervisor, {profile, chain_name, chain_config}}

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} ->
        Logger.info("Started chain supervisor",
          profile: profile,
          chain: chain_name
        )

        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} = error ->
        Logger.error("Failed to start chain supervisor",
          profile: profile,
          chain: chain_name,
          reason: inspect(reason)
        )

        error
    end
  end

  @doc """
  Stop a ChainSupervisor for a specific profile and chain.

  This gracefully terminates the chain supervisor and all its children.
  """
  @spec stop_profile_chain(String.t(), String.t()) :: :ok
  def stop_profile_chain(profile, chain_name)
      when is_binary(profile) and is_binary(chain_name) do
    case GenServer.whereis(chain_supervisor_via(profile, chain_name)) do
      nil ->
        :ok

      pid ->
        case DynamicSupervisor.terminate_child(__MODULE__, pid) do
          :ok ->
            Logger.info("Stopped chain supervisor",
              profile: profile,
              chain: chain_name
            )

            :ok

          {:error, :not_found} ->
            :ok
        end
    end
  end

  @doc """
  List all running chain supervisors for a profile.

  Returns a list of chain names that have running supervisors for the profile.
  """
  @spec list_profile_chains(String.t()) :: [String.t()]
  def list_profile_chains(profile) when is_binary(profile) do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.flat_map(fn {_, pid, _, _} ->
      case Registry.keys(Lasso.Registry, pid) do
        [{:chain_supervisor, ^profile, chain_name}] -> [chain_name]
        _ -> []
      end
    end)
  end

  @doc """
  List all running profile-chain pairs.

  Returns a list of `{profile, chain_name}` tuples.
  """
  @spec list_all() :: [{String.t(), String.t()}]
  def list_all do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.flat_map(fn {_, pid, _, _} ->
      case Registry.keys(Lasso.Registry, pid) do
        [{:chain_supervisor, profile, chain_name}] -> [{profile, chain_name}]
        _ -> []
      end
    end)
  end

  @doc """
  Check if a chain supervisor is running for a profile.
  """
  @spec running?(String.t(), String.t()) :: boolean()
  def running?(profile, chain_name) do
    GenServer.whereis(chain_supervisor_via(profile, chain_name)) != nil
  end

  ## DynamicSupervisor Callbacks

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  ## Private Functions

  defp chain_supervisor_via(profile, chain_name) do
    {:via, Registry, {Lasso.Registry, {:chain_supervisor, profile, chain_name}}}
  end
end
