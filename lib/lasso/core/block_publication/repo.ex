defmodule Lasso.BlockPublication.Repo do
  @moduledoc "Optional PostgreSQL connection pool for durable block publication."
  use Ecto.Repo, otp_app: :lasso, adapter: Ecto.Adapters.Postgres
end
