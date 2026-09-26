defmodule Lasso.Diagnostics do
  @moduledoc "Operator-facing snapshots of local runtime health."

  alias Lasso.Core.Support.CredentialHealth

  @doc "Returns active managed upstream credential failures across connected nodes."
  @spec credential_health() :: [map()]
  def credential_health, do: CredentialHealth.active()
end
