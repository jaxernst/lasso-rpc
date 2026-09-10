defmodule Lasso.BlockPublication.Storage do
  @moduledoc "Explicit installation of the optional durable publication journal."

  @doc "Runs journal migrations without starting RPC ingress."
  @spec migrate() :: {:ok, [integer()], [atom()]} | {:error, term()}
  def migrate do
    repo = Application.fetch_env!(:lasso, :block_publication_repo)

    if repo.config()[:database] in [nil, ""],
      do: raise(ArgumentError, "Publication repository database configuration is required")

    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    path = Application.app_dir(:lasso, "priv/block_publication/migrations")
    Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, path, :up, all: true))
  end
end
