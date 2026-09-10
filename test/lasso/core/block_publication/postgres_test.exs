defmodule Lasso.BlockPublication.PostgresTest do
  use ExUnit.Case, async: false
  use Lasso.Test.PublicationDBCase

  alias Ecto.Adapters.SQL.Sandbox
  alias Lasso.BlockPublication.Publication

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  test "file profiles preserve acknowledged floors, boot fences and revision checks" do
    key = {"operator-profile", 1}
    assert {:ok, initial} = Postgres.ensure(key, ["a", "b"], 60_000)
    assert {:ok, joined} = Postgres.command(key, {:join, "a", "boot-a", 101})
    assert joined["minimum_height"] == 101
    assert Postgres.get(key) == joined

    assert {:error, :stale_revision} =
             Postgres.compare_and_apply(key, initial, {:join, "b", "boot-b", nil})

    assert {:ok, fenced} = Postgres.command(key, {:fence, "a", "boot-a", "Test boot stopped"})
    assert fenced["minimum_height"] == 101
    assert Map.has_key?(fenced["fenced_boots"], "boot-a")
    assert {:error, :membership_mismatch} = Postgres.ensure(key, ["a"], 60_000)
  end

  test "disabled history is retained and does not appear in every active poll" do
    state = %{
      Publication.new(["a"], 60_000)
      | "phase" => "disabled",
        "minimum_height" => 101,
        "revision" => 1
    }

    now = DateTime.utc_now()

    rows =
      for n <- 1..1000,
          do: %{
            profile: "history-#{n}",
            chain_id: 1,
            state: state,
            revision: 1,
            inserted_at: now,
            updated_at: now
          }

    Repo.insert_all(Postgres, rows)
    assert {:ok, []} = Postgres.changes(%{})
    key = {"history-500", 1}
    assert {:ok, [{^key, ^state}]} = Postgres.changes(%{key => 0})
    assert {:ok, enabled} = Postgres.command(key, :enable)
    assert enabled["minimum_height"] == 101
    assert {:ok, [{^key, ^enabled}]} = Postgres.changes(%{})
  end

  test "capacity rejection leaves existing reservations and floors intact" do
    prefix = "capacity-#{System.unique_integer([:positive])}-"

    Sandbox.unboxed_run(Repo, fn ->
      try do
        for n <- 1..4,
            do: assert({:ok, _} = Postgres.ensure({prefix <> to_string(n), 1}, ["a"], 60_000))

        assert {:error, :publication_capacity_exhausted} =
                 Postgres.ensure({prefix <> "overflow", 1}, ["a"], 60_000)

        assert {:ok, %{active_scopes: 4}} = Postgres.capacity()
        assert Postgres.get({prefix <> "overflow", 1}) == nil
      after
        Repo.query!("DELETE FROM block_publications WHERE profile LIKE $1", [prefix <> "%"])
      end
    end)
  end
end
