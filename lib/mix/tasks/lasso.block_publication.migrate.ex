defmodule Mix.Tasks.Lasso.BlockPublication.Migrate do
  @moduledoc "Runs the optional journal migrations without opening RPC ingress."
  use Mix.Task
  @shortdoc "Install or upgrade the optional PostgreSQL publication journal"

  @impl true
  def run([]) do
    Mix.Task.run("app.config")

    case Lasso.BlockPublication.Storage.migrate() do
      {:ok, versions, _apps} ->
        Mix.shell().info("Publication migrations applied: #{inspect(versions)}")

      {:error, reason} ->
        Mix.raise("Publication migration failed: #{inspect(reason)}")
    end
  end
end
