defmodule Lasso.BlockPublication.Journal do
  @moduledoc """
  Background-only durable serialization of publication commands.

  `changes/1` discovers non-disabled scopes and updates for tracked revisions,
  including their terminal disabled state. Consumers may then stop tracking a
  disabled scope; its durable floor remains available to later activation.
  """
  @callback list() :: {:ok, [{{String.t(), pos_integer()}, map()}]} | {:error, term()}
  @callback changes(map()) :: {:ok, [{{String.t(), pos_integer()}, map()}]} | {:error, term()}
  @callback ensure({String.t(), pos_integer()}, [String.t()], pos_integer()) ::
              {:ok, map()} | {:error, term()}
  @callback command({String.t(), pos_integer()}, Lasso.BlockPublication.Publication.command()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Applies a command only if the supplied journal snapshot is still current.
  A stale revision must not mutate durable state. Callers reconcile before retrying;
  they must not reopen a gate from an unsuccessful update.
  """
  @callback compare_and_apply(
              {String.t(), pos_integer()},
              Lasso.BlockPublication.Publication.t(),
              Lasso.BlockPublication.Publication.command()
            ) :: {:ok, map()} | {:error, term()}
  @optional_callbacks compare_and_apply: 3
end
