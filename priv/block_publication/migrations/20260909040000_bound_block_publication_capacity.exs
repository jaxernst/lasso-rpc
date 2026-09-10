defmodule Lasso.BlockPublication.Repo.Migrations.BoundBlockPublicationCapacity do
  use Ecto.Migration

  def up do
    publications = qualified("block_publications")
    capacity = qualified("block_publication_capacity")
    function = qualified("reserve_block_publication_capacity")

    create table(:block_publication_capacity, primary_key: false) do
      add(:singleton, :boolean, primary_key: true, default: true)
      add(:active_scopes, :integer, null: false)
      add(:retained_scopes, :integer, null: false)
      add(:reserved_bytes, :bigint, null: false)
    end

    create constraint(:block_publication_capacity, :block_publication_capacity_singleton,
             check: "singleton"
           )

    create constraint(:block_publication_capacity, :block_publication_active_capacity,
             check: "active_scopes BETWEEN 0 AND 4"
           )

    create constraint(:block_publication_capacity, :block_publication_retained_capacity,
             check: "retained_scopes BETWEEN 0 AND 1024"
           )

    create constraint(:block_publication_capacity, :block_publication_byte_capacity,
             check: "reserved_bytes BETWEEN 0 AND 33554432"
           )

    create constraint(:block_publications, :block_publication_state_size,
             check: "octet_length(state::text) <= 2359296"
           )

    execute("""
    INSERT INTO #{capacity} (singleton, active_scopes, retained_scopes, reserved_bytes)
    SELECT true,
           count(*) FILTER (WHERE state->>'phase' IS DISTINCT FROM 'disabled'),
           count(*),
           coalesce(sum(CASE WHEN state->>'phase' = 'disabled'
                            THEN octet_length(state::text) ELSE 2359296 END), 0)
    FROM #{publications}
    """)

    execute("""
    CREATE FUNCTION #{function}() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE
      active_delta integer := 0;
      retained_delta integer := 0;
      byte_delta bigint := 0;
    BEGIN
      IF TG_OP <> 'INSERT' THEN
        active_delta := -CASE WHEN OLD.state->>'phase' = 'disabled' THEN 0 ELSE 1 END;
        retained_delta := -1;
        byte_delta := -CASE WHEN OLD.state->>'phase' = 'disabled'
                           THEN octet_length(OLD.state::text) ELSE 2359296 END;
      END IF;
      IF TG_OP <> 'DELETE' THEN
        active_delta := active_delta + CASE WHEN NEW.state->>'phase' = 'disabled' THEN 0 ELSE 1 END;
        retained_delta := retained_delta + 1;
        byte_delta := byte_delta + CASE WHEN NEW.state->>'phase' = 'disabled'
                                       THEN octet_length(NEW.state::text) ELSE 2359296 END;
      END IF;
      IF active_delta <> 0 OR retained_delta <> 0 OR byte_delta <> 0 THEN
        UPDATE #{capacity}
        SET active_scopes = active_scopes + active_delta,
            retained_scopes = retained_scopes + retained_delta,
            reserved_bytes = reserved_bytes + byte_delta
        WHERE singleton;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'publication capacity reservation is unavailable';
        END IF;
      END IF;
      RETURN NULL;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER reserve_block_publication_capacity
    AFTER INSERT OR UPDATE OR DELETE ON #{publications}
    FOR EACH ROW EXECUTE FUNCTION #{function}()
    """)
  end

  def down do
    execute("DROP TRIGGER reserve_block_publication_capacity ON #{qualified("block_publications")}")
    execute("DROP FUNCTION #{qualified("reserve_block_publication_capacity")}()")
    drop(constraint(:block_publications, :block_publication_state_size))
    drop(table(:block_publication_capacity))
  end

  defp qualified(name), do: ~s("#{String.replace(prefix() || "public", "\"", "\"\"")}"."#{name}")
end
