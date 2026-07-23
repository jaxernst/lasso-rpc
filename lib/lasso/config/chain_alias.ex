defmodule Lasso.Config.ChainAlias do
  @moduledoc """
  Resolves chain presentation at configuration and routing boundaries.

  Loaded profile configuration is authoritative for friendly URL aliases and
  display names. Every positive chain ID also has its decimal representation as
  a universal fallback, so arbitrary EVM chains require no source-code change.
  """

  @spec canonical_slug(pos_integer(), [String.t()]) :: String.t()
  def canonical_slug(chain_id, configured_aliases \\ [])

  def canonical_slug(chain_id, configured_aliases)
      when is_integer(chain_id) and chain_id > 0 and is_list(configured_aliases) do
    Enum.find(configured_aliases, &valid_alias?/1) || Integer.to_string(chain_id)
  end

  @spec aliases(pos_integer()) :: [String.t()]
  def aliases(chain_id) when is_integer(chain_id) and chain_id > 0 do
    [Integer.to_string(chain_id)]
  end

  @spec display_name(non_neg_integer() | nil, String.t() | nil) :: String.t()
  def display_name(chain_id, label \\ nil)

  def display_name(chain_id, label) when is_binary(label) do
    case String.trim(label) do
      "" -> default_display_name(chain_id)
      trimmed -> trimmed
    end
  end

  def display_name(chain_id, nil), do: default_display_name(chain_id)

  defp valid_alias?(alias_name) when is_binary(alias_name), do: String.trim(alias_name) != ""
  defp valid_alias?(_), do: false

  defp default_display_name(chain_id) when is_integer(chain_id) and chain_id > 0,
    do: "Chain #{chain_id}"

  defp default_display_name(_), do: "Unknown chain"
end
