defmodule Lasso.Config.ProfileId do
  @moduledoc """
  Opaque routing key for a file-backed profile.

  System profile IDs are their YAML slugs. Callers should treat the value as
  opaque even though the current file backend makes the two equal.
  """

  @typedoc "Opaque routing key."
  @type t :: String.t()

  @spec for_system(String.t()) :: t()
  def for_system(slug) when is_binary(slug), do: slug

  @spec system?(String.t()) :: boolean()
  def system?(slug) when is_binary(slug) do
    canonical = Lasso.Config.ProfileValidator.resolve_alias(slug)
    match?({:ok, _profile_id}, Lasso.Config.ConfigStore.resolve(:system, canonical))
  end
end
