defmodule Lasso.Testing.ChainHelper do
  @moduledoc """
  Helper utilities for managing test chains and their supervisors.

  Consolidates chain creation and supervisor management logic used by
  mock providers during integration testing.
  """

  require Logger

  @test_profile "default"

  @doc """
  Ensures a chain exists and its supervisors are running.

  If the chain doesn't exist, creates it with default test configuration.
  If the chain exists but supervisors aren't running, starts them.

  ## Options
  - `:profile` - Profile to use (default: "default")

  ## Returns
  - `:ok` on success
  - `{:error, reason}` on failure
  """
  def ensure_chain_exists(chain_name, opts \\ []) do
    profile = Keyword.get(opts, :profile, @test_profile)

    case Lasso.Config.ConfigStore.get_chain(profile, chain_name) do
      {:ok, _chain_config} ->
        ensure_chain_supervisors_running(profile, chain_name)

      {:error, :not_found} ->
        Logger.info("Chain '#{chain_name}' not found, creating for mock provider")

        with :ok <- create_chain(profile, chain_name),
             {:ok, chain_config} <- Lasso.Config.ConfigStore.get_chain(profile, chain_name),
             :ok <- start_chain_supervisors(profile, chain_name, chain_config) do
          Logger.info("Successfully started chain supervisor for '#{chain_name}'")
          :ok
        else
          {:error, reason} = error ->
            Logger.error("Failed to start chain '#{chain_name}': #{inspect(reason)}")
            error
        end
    end
  end

  @doc """
  Returns default chain configuration for test chains.

  ## Example
      config = default_chain_config("test_chain")
  """
  def default_chain_config(chain_name) do
    %{
      chain_id: nil,
      name: chain_name,
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

  ## Example
      ChainHelper.chain_supervisor_running?("default", "ethereum")
      # => true
  """
  def chain_supervisor_running?(profile, chain_name) do
    Lasso.ProfileChainSupervisor.running?(profile, chain_name)
  end

  # Private helpers

  defp create_chain(profile, chain_name) do
    config = default_chain_config(chain_name)
    Lasso.Config.ConfigStore.register_chain_runtime(profile, chain_name, config)
  end

  defp ensure_chain_supervisors_running(profile, chain_name) do
    case Lasso.ProfileChainSupervisor.running?(profile, chain_name) do
      true ->
        :ok

      false ->
        case Lasso.Config.ConfigStore.get_chain(profile, chain_name) do
          {:ok, chain_config} ->
            start_chain_supervisors(profile, chain_name, chain_config)

          {:error, _} = error ->
            error
        end
    end
  end

  defp start_chain_supervisors(profile, chain_name, chain_config) do
    case Lasso.ProfileChainSupervisor.start_profile_chain(profile, chain_name, chain_config) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
