defmodule Lasso.Diagnostics do
  @moduledoc "Operator-facing snapshots of local runtime health."

  alias Lasso.Core.Support.CredentialHealth

  @doc "Returns active managed upstream credential failures across connected nodes."
  @spec credential_health() :: [map()]
  def credential_health, do: CredentialHealth.active()

  @doc "Returns queue occupancy and dropped credential observations on this node."
  @spec credential_health_stats() :: map()
  def credential_health_stats, do: CredentialHealth.stats()
end
