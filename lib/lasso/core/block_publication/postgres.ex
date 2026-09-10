defmodule Lasso.BlockPublication.Postgres do
  @moduledoc "PostgreSQL authority for background block publication. Never called by RPCs."
  @behaviour Lasso.BlockPublication.Journal
  use Ecto.Schema
  import Ecto.Query
  alias Lasso.BlockPublication.Publication

  @primary_key false
  schema "block_publications" do
    field(:profile, :string, primary_key: true)
    field(:chain_id, :integer, primary_key: true)
    field(:state, :map)
    field(:revision, :integer, default: 0)
    timestamps(type: :utc_datetime_usec)
  end

  @doc "Fleet-wide reservations; active scopes reserve one probe slot and the maximum record size."
  @spec capacity() :: {:ok, map()} | {:error, atom()}
  def capacity do
    safely(fn ->
      case repo().query!(
             "SELECT active_scopes, retained_scopes, reserved_bytes FROM block_publication_capacity WHERE singleton"
           ).rows do
        [[active, retained, bytes]] ->
          {:ok,
           %{
             active_scopes: active,
             active_limit: 4,
             retained_scopes: retained,
             retained_limit: 1_024,
             reserved_bytes: bytes,
             byte_limit: 33_554_432,
             state_byte_limit: 2_359_296
           }}

        [] ->
          {:error, :journal_unavailable}
      end
    end)
  end

  @impl true
  def list do
    safely(fn ->
      {:ok, Enum.map(repo().all(__MODULE__), &{{&1.profile, &1.chain_id}, &1.state})}
    end)
  end

  @spec get({String.t(), pos_integer()}) :: map() | nil
  def get(key) do
    case repo().one(query(key)) do
      nil -> nil
      row -> row.state
    end
  end

  @spec configure({String.t(), pos_integer()}, String.t(), pos_integer()) ::
          {:ok, map() | nil} | {:error, term()}
  def configure(key, "global", block_time_ms) do
    config = Application.get_env(:lasso, :block_publication, [])
    members = Keyword.get(config, :members, [])

    if members == [] do
      {:error, :global_publication_unconfigured}
    else
      max_age_ms = Lasso.BlockPublication.Runtime.max_age(block_time_ms)

      with {:ok, _} <- ensure(key, members, max_age_ms),
           {:ok, state} <- command(key, {:max_age, max_age_ms}) do
        case state["phase"] do
          phase when phase in ["disabled", "disabling"] -> command(key, :enable)
          _ -> {:ok, state}
        end
      end
    end
  end

  def configure(key, _mode, _block_time_ms) do
    if get(key), do: command(key, :disable), else: {:ok, nil}
  end

  @spec disable_profile(String.t()) :: {:ok, :ok} | {:error, term()}
  def disable_profile(profile) do
    safely(fn ->
      repo().transaction(fn ->
        keys =
          repo().all(
            from(p in __MODULE__,
              where: p.profile == ^profile and fragment("?->>'phase' <> 'disabled'", p.state),
              order_by: p.chain_id,
              select: {p.profile, p.chain_id}
            )
          )

        Enum.each(keys, fn key ->
          case command(key, :disable) do
            {:ok, _} -> :ok
            {:error, reason} -> repo().rollback(reason)
          end
        end)
      end)
    end)
  end

  @impl true
  def changes(known_revisions) do
    known =
      Enum.map(known_revisions, fn {{profile, chain_id}, revision} ->
        %{profile: profile, chain_id: chain_id, revision: revision}
      end)

    safely(fn ->
      active =
        from(p in __MODULE__,
          left_join:
            k in fragment(
              "(SELECT * FROM jsonb_to_recordset(?::jsonb) AS known(profile text, chain_id bigint, revision bigint))",
              ^known
            ),
          on: p.profile == field(k, :profile) and p.chain_id == field(k, :chain_id),
          where: fragment("?->>'phase' <> 'disabled'", p.state),
          where: is_nil(field(k, :revision)) or p.revision > field(k, :revision)
        )

      closed =
        from(
          k in fragment(
            "(SELECT * FROM jsonb_to_recordset(?::jsonb) AS known(profile text, chain_id bigint, revision bigint))",
            ^known
          ),
          join: p in __MODULE__,
          on: p.profile == field(k, :profile) and p.chain_id == field(k, :chain_id),
          where: fragment("?->>'phase' = 'disabled'", p.state),
          where: p.revision > field(k, :revision),
          select: p
        )

      rows = repo().all(union_all(active, ^closed))
      {:ok, Enum.map(rows, &{{&1.profile, &1.chain_id}, &1.state})}
    end)
  end

  @impl true
  def ensure({profile, chain_id} = key, members, max_age_ms) do
    if Lasso.BlockPublication.Scope.supports?(key),
      do: ensure_scope(profile, chain_id, key, members, max_age_ms),
      else: {:error, :unsupported_publication_scope}
  end

  defp ensure_scope(profile, chain_id, key, members, max_age_ms) do
    safely(fn ->
      repo().transaction(fn ->
        repo().insert!(
          %__MODULE__{
            profile: profile,
            chain_id: chain_id,
            state: Publication.new(members, max_age_ms)
          },
          on_conflict: :nothing
        )

        row = repo().one!(query(key))

        if Enum.sort(Map.keys(row.state["members"])) != Enum.sort(members),
          do: repo().rollback(:membership_mismatch)

        row.state
      end)
    end)
  end

  @impl true
  def compare_and_apply(key, snapshot, command) do
    with {:ok, next} <- Publication.apply(snapshot, command) do
      safely(fn ->
        revision = snapshot["revision"]
        query = from(p in query(key), where: p.revision == ^revision)

        case repo().update_all(
               query,
               [set: [state: next, revision: next["revision"], updated_at: DateTime.utc_now()]],
               timeout: 1_000
             ) do
          {1, _} -> {:ok, next}
          {0, _} -> {:error, :stale_revision}
        end
      end)
    end
  end

  @impl true
  def command(key, command) do
    safely(fn ->
      repo().transaction(fn ->
        repo().query!("SET LOCAL lock_timeout = '1000ms'")
        row = repo().one(from(p in query(key), lock: "FOR UPDATE")) || repo().rollback(:not_found)

        case Publication.apply(row.state, command) do
          {:ok, state} ->
            if state != row.state do
              row
              |> Ecto.Changeset.change(state: state, revision: state["revision"])
              |> repo().update!()
            end

            state

          {:error, reason} ->
            repo().rollback(reason)
        end
      end)
    end)
  end

  defp repo, do: Application.fetch_env!(:lasso, :block_publication_repo)

  defp query({profile, chain_id}),
    do: from(p in __MODULE__, where: p.profile == ^profile and p.chain_id == ^chain_id)

  defp constraint_error(%Postgrex.Error{postgres: %{constraint: constraint}}),
    do: constraint_error(constraint)

  defp constraint_error(%Ecto.ConstraintError{constraint: constraint}),
    do: constraint_error(constraint)

  defp constraint_error(constraint)
       when constraint in [
              "block_publication_active_capacity",
              "block_publication_retained_capacity",
              "block_publication_byte_capacity"
            ],
       do: {:error, :publication_capacity_exhausted}

  defp constraint_error("block_publication_state_size"),
    do: {:error, :publication_state_too_large}

  defp constraint_error(_), do: {:error, :journal_unavailable}

  defp safely(fun) do
    fun.()
  rescue
    error in [Postgrex.Error, Ecto.ConstraintError] -> constraint_error(error)
    _ in DBConnection.ConnectionError -> {:error, :journal_unavailable}
  catch
    :exit, _ -> {:error, :journal_unavailable}
  end
end
