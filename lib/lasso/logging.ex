defmodule Lasso.Logging do
  @moduledoc """
  Logging helpers shared across the codebase.

  Profile identity in logs and telemetry events should always carry
  both the opaque routing key (`profile_id`, stable across rename) and
  the user-facing `profile_slug` (current display value). Callers use
  `profile_metadata/1` to derive the merged keyword list from a
  `profile_id`.
  """

  alias Lasso.Config.{ConfigStore, ProfileMeta}

  @doc """
  Returns Logger/telemetry metadata for a profile.

  Accepts either a `profile_id` (string), a `ProfileMeta` struct, or a
  spec map carrying `profile_id`, `slug`, and `name`. The string form
  reads display fields from `ConfigStore` and falls back to just
  `profile_id` if the profile is no longer addressable (e.g. mid-removal).
  Struct/map forms read directly — useful during inject when the profile
  is not yet in `ConfigStore`.
  """
  @spec profile_metadata(ConfigStore.profile_id() | ProfileMeta.t() | map()) :: keyword()
  def profile_metadata(profile_id) when is_binary(profile_id) do
    base = [profile_id: profile_id]

    case ConfigStore.get_profile(profile_id) do
      {:ok, %ProfileMeta{slug: slug, name: name}} ->
        Keyword.merge(base, profile_slug: slug, profile_name: name)

      {:error, :not_found} ->
        base
    end
  end

  def profile_metadata(%ProfileMeta{profile_id: profile_id, slug: slug, name: name}),
    do: [profile_id: profile_id, profile_slug: slug, profile_name: name]

  def profile_metadata(%{profile_id: profile_id, slug: slug, name: name}),
    do: [profile_id: profile_id, profile_slug: slug, profile_name: name]
end
