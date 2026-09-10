defmodule Lasso.BlockPublication.Repo.Migrations.CreateBlockPublications do
  use Ecto.Migration

  def change do
    create table(:block_publications, primary_key: false) do
      add(:profile, :text, primary_key: true)
      add(:chain_id, :bigint, primary_key: true)
      add(:state, :map, null: false)
      add(:revision, :bigint, null: false, default: 0)
      timestamps(type: :utc_datetime_usec)
    end
  end
end
