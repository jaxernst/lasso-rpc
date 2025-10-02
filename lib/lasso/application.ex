defmodule Lasso.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children =
      [
        # Start PubSub for real-time messaging
        {Phoenix.PubSub, name: Lasso.PubSub},

        # Start Finch HTTP client for RPC provider requests
        {Finch, name: Lasso.Finch},

        # Start benchmark store for performance metrics
        Lasso.Benchmarking.BenchmarkStore,

        # Start benchmark persistence for historical data
        Lasso.Benchmarking.Persistence,

        # Start process registry for centralized process management
        {Lasso.RPC.ProcessRegistry, name: Lasso.RPC.ProcessRegistry},

        # Add a local Registry for dynamic process names (high-cardinality)
        {Registry, keys: :unique, name: Lasso.Registry, partitions: System.schedulers_online()},

        # Start dynamic supervisor for chain supervisors
        {DynamicSupervisor, name: Lasso.RPC.Supervisor, strategy: :one_for_one},

        # Start configuration store for centralized config caching
        {Lasso.Config.ConfigStore,
         Application.get_env(:lasso, :chains_config_path, "config/chains.yml")},

        # Start Phoenix endpoint
        LassoWeb.Endpoint
      ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    opts = [strategy: :one_for_one, name: Lasso.Supervisor]

    with {:ok, supervisor} <- Supervisor.start_link(children, opts) do
      # Attach telemetry handlers after supervisor is started
      Lasso.Telemetry.attach_default_handlers()

      # Start all configured chains
      {:ok, started_count} = start_all_chains()
      Logger.info("Started #{started_count} chain supervisors")

      {:ok, supervisor}
    end
  end

  # Private helper functions

  defp start_all_chains do
    # Get all configured chains from ConfigStore
    all_chains = Lasso.Config.ConfigStore.get_all_chains()

    # Start chain supervisors for each configured chain
    results =
      Enum.map(all_chains, fn {chain_name, chain_config} ->
        case start_chain_supervisor(chain_name, chain_config) do
          {:ok, _pid} = result ->
            Logger.info("✓ Chain supervisor started successfully: #{chain_name}")
            {chain_name, result}

          {:error, reason} = result ->
            Logger.error("✗ Chain supervisor failed to start: #{chain_name} - #{inspect(reason)}")
            {chain_name, result}
        end
      end)

    # Count successful starts
    successful_count =
      results
      |> Enum.filter(fn {_, result} -> match?({:ok, _}, result) end)
      |> length()

    {:ok, successful_count}
  end

  defp start_chain_supervisor(chain_name, chain_config) do
    :ok = Lasso.Config.ChainConfig.validate_chain_config(chain_config)

    DynamicSupervisor.start_child(
      Lasso.RPC.Supervisor,
      {Lasso.RPC.ChainSupervisor, {chain_name, chain_config}}
    )
  end
end
