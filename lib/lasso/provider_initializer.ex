defmodule Lasso.ProviderInitializer do
  @moduledoc """
  Supervised initialization of provider infrastructure.

  Runs profile loading, catalog building, provider validation,
  and shared infrastructure startup within supervision. Failures
  trigger a retry with exponential backoff rather than leaving the
  system partially initialized.
  """

  use GenServer
  require Logger

  alias Lasso.Config.{ChainConfig, ConfigStore}
  alias Lasso.Config.ProfileValidator
  alias Lasso.Providers.{Catalog, InstanceSupervisor, ProbeCoordinator}

  @max_retries 5
  @base_retry_delay_ms 2_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    case initialize_with_retries(0) do
      :ok -> {:ok, %{status: :ready}}
      {:error, reason} -> {:stop, {:initialization_failed, reason}}
    end
  end

  defp initialize_with_retries(attempt) when attempt >= @max_retries do
    Logger.error("Provider initialization failed after #{@max_retries} attempts")
    {:error, :max_retries_exceeded}
  end

  defp initialize_with_retries(attempt) do
    case do_initialize() do
      :ok ->
        :ok

      {:error, reason} ->
        delay = @base_retry_delay_ms * Integer.pow(2, attempt)

        Logger.warning(
          "Provider initialization failed (attempt #{attempt + 1}), retrying in #{delay}ms: #{inspect(reason)}"
        )

        :timer.sleep(delay)
        initialize_with_retries(attempt + 1)
    end
  end

  defp do_initialize do
    with {:ok, profile_slugs} <- load_profiles(),
         :ok <- validate_public_profile(),
         :ok <- validate_provider_urls(profile_slugs),
         :ok <- build_catalog(),
         :ok <- start_shared_infrastructure() do
      start_all_chains()
    end
  end

  defp load_profiles do
    case ConfigStore.load_all_profiles() do
      {:ok, profile_slugs} ->
        Logger.info("Loaded #{length(profile_slugs)} profiles: #{Enum.join(profile_slugs, ", ")}")

        {:ok, profile_slugs}

      {:error, reason} ->
        Logger.warning("Failed to load profiles: #{inspect(reason)}")
        {:error, {:load_profiles, reason}}
    end
  end

  defp validate_public_profile do
    case ProfileValidator.validate("public") do
      {:ok, _} ->
        Logger.info("Startup validation passed: 'public' profile found")
        :ok

      {:error, _type, message} ->
        Logger.error("STARTUP FAILURE: #{message}")
        Logger.error("The 'public' profile must be configured at startup")
        Logger.error("Ensure config/profiles/public.yml exists and is valid")
        {:error, {:public_profile_missing, message}}
    end
  end

  defp validate_provider_urls(profile_slugs) do
    profile_slugs
    |> Enum.flat_map(&collect_profile_validation_errors/1)
    |> case do
      [] ->
        Logger.info("Startup validation passed: all provider URLs resolved")
        :ok

      errors ->
        log_validation_errors(errors)
        {:error, {:unresolved_env_vars, length(errors)}}
    end
  end

  defp build_catalog do
    Catalog.build_from_config()

    Logger.info("Provider catalog built: #{Catalog.instance_count()} unique instances")

    :ok
  end

  defp start_shared_infrastructure do
    instance_ids = Catalog.list_all_instance_ids()

    instance_failures =
      Enum.reduce(instance_ids, 0, fn instance_id, failures ->
        case DynamicSupervisor.start_child(
               Lasso.Providers.InstanceDynamicSupervisor,
               {InstanceSupervisor, instance_id}
             ) do
          {:ok, _} ->
            failures

          {:error, {:already_started, _}} ->
            failures

          {:error, reason} ->
            Logger.warning(
              "Failed to start InstanceSupervisor for #{instance_id}: #{inspect(reason)}"
            )

            failures + 1
        end
      end)

    cond do
      instance_ids == [] ->
        Logger.info("No instances configured - skipping instance supervisor startup")
        :ok

      instance_failures == length(instance_ids) ->
        {:error, :all_instance_supervisors_failed}

      true ->
        Logger.info(
          "Started #{length(instance_ids) - instance_failures}/#{length(instance_ids)} instance supervisors"
        )

        start_probe_coordinators_and_block_sync()
    end
  end

  defp start_probe_coordinators_and_block_sync do
    chains = ConfigStore.list_chains()

    probe_failures =
      Enum.reduce(chains, 0, fn chain, failures ->
        case DynamicSupervisor.start_child(
               Lasso.Providers.ProbeSupervisor,
               {ProbeCoordinator, chain}
             ) do
          {:ok, _} ->
            failures

          {:error, {:already_started, _}} ->
            failures

          {:error, reason} ->
            Logger.warning("Failed to start ProbeCoordinator for #{chain}: #{inspect(reason)}")
            failures + 1
        end
      end)

    cond do
      chains == [] ->
        :ok

      probe_failures == length(chains) ->
        {:error, :all_probe_coordinators_failed}

      true ->
        Logger.info(
          "Started #{length(chains) - probe_failures}/#{length(chains)} probe coordinators"
        )

        for chain <- chains do
          Lasso.BlockSync.Initializer.start_workers_for_chain(chain)
        end

        Logger.info("Started BlockSync workers for #{length(chains)} chains")
        :ok
    end
  end

  defp start_all_chains do
    profiles = ConfigStore.list_profiles()

    if Enum.empty?(profiles) do
      Logger.warning("No profiles loaded - skipping chain startup")
      :ok
    else
      results =
        Enum.flat_map(profiles, fn profile ->
          case ConfigStore.get_profile_chains(profile) do
            {:ok, chains} ->
              Enum.map(chains, fn {chain_name, chain_config} ->
                result = start_profile_chain(profile, chain_name, chain_config)
                {profile, chain_name, result}
              end)

            {:error, :not_found} ->
              Logger.warning("Profile #{profile} not found during chain startup")
              []
          end
        end)

      successful_count =
        results
        |> Enum.filter(fn {_, _, result} -> match?({:ok, _}, result) end)
        |> length()

      cond do
        results == [] ->
          Logger.info("No chains configured - starting in minimal mode")
          :ok

        successful_count == 0 ->
          {:error, :no_chains_started}

        true ->
          Logger.info("Started #{successful_count}/#{length(results)} chain supervisors")
          :ok
      end
    end
  end

  defp start_profile_chain(profile, chain_name, chain_config) do
    case ChainConfig.validate_chain_config(chain_config) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Chain #{chain_name} validation failed for profile #{profile}: #{inspect(reason)}"
        )
    end

    result = Lasso.ProfileChainSupervisor.start_profile_chain(profile, chain_name, chain_config)

    case result do
      {:ok, _pid} ->
        Logger.info("Started chain supervisor: #{profile}/#{chain_name}")

      {:error, reason} ->
        Logger.error(
          "Failed to start chain supervisor: #{profile}/#{chain_name} - #{inspect(reason)}"
        )
    end

    result
  end

  defp collect_profile_validation_errors(profile) do
    case ConfigStore.get_profile_chains(profile) do
      {:ok, chains} ->
        Enum.flat_map(chains, fn {chain_name, chain_config} ->
          case ChainConfig.validate_no_unresolved_placeholders(chain_config) do
            :ok -> []
            {:error, {:unresolved_env_vars, providers}} -> [{profile, chain_name, providers}]
          end
        end)

      _ ->
        []
    end
  end

  defp log_validation_errors(errors) do
    Logger.error("""
    STARTUP FAILURE: Unresolved environment variables in provider configuration

    #{format_validation_errors(errors)}

    Please ensure all required environment variables are set in your .env file or system environment.
    """)
  end

  defp format_validation_errors(errors) do
    Enum.map_join(errors, "\n\n", fn {profile, chain, providers} ->
      "Profile '#{profile}', Chain '#{chain}':\n#{format_provider_issues(providers)}"
    end)
  end

  defp format_provider_issues(providers) do
    Enum.map_join(providers, "\n", fn {provider_id, issues} ->
      issue_list = Enum.map_join(issues, "\n", fn {type, url} -> "    - #{type}: #{url}" end)
      "  Provider '#{provider_id}':\n#{issue_list}"
    end)
  end
end
