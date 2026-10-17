defmodule Lasso.Diagnostics do
  @moduledoc "Operator-facing snapshots of local runtime health."

  alias Lasso.Config.ConfigStore
  alias Lasso.Core.Support.CredentialHealth

  @doc "Reloads configured profiles and synchronously reconciles their runtime."
  @spec reload_profiles() :: :ok | {:error, term()}
  def reload_profiles, do: ConfigStore.reload()

  @doc "Acknowledges local retirement after the operator removes a profile file. Callers must be quiesced."
  @spec retire_tenant(String.t()) :: {:ok, map()} | {:error, term()}
  def retire_tenant(profile) when is_binary(profile) do
    operation = System.unique_integer([:positive, :monotonic])

    with :ok <- reload_profiles(),
         {:error, :not_found} <- ConfigStore.get_profile(profile) do
      receipt = %{
        profile: profile,
        node: node(),
        operation: operation,
        generation: ConfigStore.route_generation(),
        outcome: :ok
      }

      :telemetry.execute([:lasso, :tenant, :retired], %{count: 1}, receipt)
      {:ok, receipt}
    else
      {:ok, _profile} -> {:error, :profile_still_present}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns active managed upstream credential failures across connected nodes."
  @spec credential_health() :: [map()]
  def credential_health, do: CredentialHealth.active()

  @doc "Returns queue occupancy and dropped credential observations on this node."
  @spec credential_health_stats() :: map()
  def credential_health_stats, do: CredentialHealth.stats()
end
