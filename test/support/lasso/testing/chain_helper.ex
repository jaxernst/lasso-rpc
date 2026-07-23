defmodule Lasso.Testing.ChainHelper do
  @moduledoc """
  Helper utilities for managing test chains and their supervisors.

  Consolidates chain creation and supervisor management logic used by
  mock providers during integration testing.
  """

  require Logger

  @test_profile "public"

  @doc """
  Ensures a chain exists for the given profile and its supervisors are running.

  If the chain doesn't exist, creates it with default test configuration.
  If the chain exists but supervisors aren't running, starts them.

  ## Options
  - `:profile` - Profile to use (default: "public")
  """
  @spec ensure_chain_exists(pos_integer(), keyword()) :: :ok | {:error, term()}
  def ensure_chain_exists(chain_id, opts \\ []) when is_integer(chain_id) and chain_id > 0 do
    profile = Keyword.get(opts, :profile, @test_profile)

    case Lasso.Config.ConfigStore.get_chain(profile, chain_id) do
      {:ok, _chain_config} ->
        ensure_chain_supervisors_running(profile, chain_id)

      {:error, :not_found} ->
        Logger.info("Chain #{chain_id} not found, creating for mock provider")

        with :ok <- create_chain(profile, chain_id),
             {:ok, chain_config} <- Lasso.Config.ConfigStore.get_chain(profile, chain_id),
             :ok <- start_chain_supervisors(profile, chain_id, chain_config) do
          Logger.info("Successfully started chain supervisor for #{chain_id}")
          :ok
        else
          {:error, reason} = error ->
            Logger.error("Failed to start chain #{chain_id}: #{inspect(reason)}")
            error
        end
    end
  end

  @doc """
  Returns default chain configuration for test chains.
  """
  @spec default_chain_config(pos_integer()) :: map()
  def default_chain_config(chain_id) when is_integer(chain_id) and chain_id > 0 do
    %{
      chain_id: chain_id,
      display_name: "Chain #{chain_id}",
      providers: [],
      connection: %{
        heartbeat_interval: 30_000,
        reconnect_interval: 5_000,
        max_reconnect_attempts: 5
      },
      failover: %{
        enabled: false,
        max_backfill_blocks: 100,
        backfill_timeout: 30_000
      }
    }
  end

  @doc """
  Checks if the chain supervisor is running for a given profile and chain.
  """
  @spec chain_supervisor_running?(String.t(), pos_integer()) :: boolean()
  def chain_supervisor_running?(profile, chain_id) when is_integer(chain_id) do
    Lasso.ProfileChainSupervisor.running?(profile, chain_id)
  end

  # Private helpers

  defp create_chain(profile, chain_id) do
    config = default_chain_config(chain_id)
    Lasso.Config.ConfigStore.register_chain_runtime(profile, chain_id, config)
  end

  defp ensure_chain_supervisors_running(profile, chain_id) do
    case Lasso.ProfileChainSupervisor.running?(profile, chain_id) do
      true ->
        :ok

      false ->
        case Lasso.Config.ConfigStore.get_chain(profile, chain_id) do
          {:ok, chain_config} ->
            start_chain_supervisors(profile, chain_id, chain_config)

          {:error, _} = error ->
            error
        end
    end
  end

  defp start_chain_supervisors(profile, chain_id, chain_config) do
    case Lasso.ProfileChainSupervisor.start_profile_chain(profile, chain_id, chain_config) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
