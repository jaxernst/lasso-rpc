defmodule Lasso.BlockPublication.Scope do
  @moduledoc """
  Immutable publication eligibility for a deployment's profile namespaces.

  A scope adapter must be a pure, local predicate independent of mutable profile
  settings. Returning false authorizes ordinary routing before journal recovery,
  so the durable adapter must also prohibit enrollment outside this boundary.
  Narrowing the boundary requires migrating existing enrollment first.

  Without an adapter, every scope is eligible, including file-backed Core profiles.
  """
  @callback supports?({String.t(), pos_integer()}) :: boolean()

  @spec configured() :: module() | nil
  def configured, do: Application.get_env(:lasso, :block_publication, [])[:scope]

  @spec supports?({String.t(), pos_integer()}, module() | nil) :: boolean()
  def supports?(key, adapter \\ configured())
  def supports?(_key, nil), do: true
  def supports?(key, adapter), do: adapter.supports?(key)

  @spec validate({String.t(), pos_integer()}, String.t(), module() | nil) ::
          :ok | {:error, atom()}
  def validate(key, mode, adapter \\ configured())

  def validate(key, "global", adapter) do
    if supports?(key, adapter), do: :ok, else: {:error, :unsupported_publication_scope}
  end

  def validate(_key, _mode, _adapter), do: :ok
end
