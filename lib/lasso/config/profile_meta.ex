defmodule Lasso.Config.ProfileMeta do
  @moduledoc """
  Profile metadata stored in `Lasso.Config.ConfigStore`.

  Carries the opaque routing identity and YAML slug for a system profile,
  plus display fields (`name`, `logo`, `unlisted`) and request limits
  (`rps_limit`, `burst_limit`).

  Use the field accessors (`meta.name`, `meta.rps_limit`, etc.). For
  optional fields use `Map.get/3` rather than bracket access — structs
  do not implement `Access`.
  """

  @enforce_keys [
    :profile_id,
    :scope,
    :slug,
    :name,
    :rps_limit,
    :burst_limit,
    :unlisted
  ]
  defstruct [
    :profile_id,
    :scope,
    :slug,
    :name,
    :logo,
    :rps_limit,
    :burst_limit,
    :unlisted
  ]

  @type t :: %__MODULE__{
          profile_id: String.t(),
          scope: :system,
          slug: String.t(),
          name: String.t(),
          logo: String.t() | nil,
          rps_limit: pos_integer(),
          burst_limit: pos_integer(),
          unlisted: boolean()
        }
end
