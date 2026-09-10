defmodule Lasso.Test.PublicationDBCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :publication_db
      alias Lasso.BlockPublication.{Postgres, Repo}
    end
  end

  setup_all do
    alias Lasso.BlockPublication.{Repo, Storage}
    previous = Application.get_env(:lasso, Repo)
    url = System.fetch_env!("LASSO_TEST_PUBLICATION_DATABASE_URL")

    Application.put_env(:lasso, Repo,
      url: url,
      pool: Ecto.Adapters.SQL.Sandbox,
      pool_size: 4,
      log: false
    )

    on_exit(fn -> Application.put_env(:lasso, Repo, previous || []) end)
    {:ok, _, _} = Storage.migrate()
    start_supervised!(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    :ok
  end
end
