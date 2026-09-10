defmodule Lasso.BlockPublication.Repo.Migrations.IndexActiveBlockPublications do
  use Ecto.Migration

  def change do
    create(
      index(:block_publications, [:profile, :chain_id],
        name: :block_publications_active,
        where: "state->>'phase' <> 'disabled'"
      )
    )

    create(index(:block_publications, ["(state->>'phase')"], name: :block_publications_phase))

    execute("ANALYZE block_publications", "SELECT 1")
  end
end
