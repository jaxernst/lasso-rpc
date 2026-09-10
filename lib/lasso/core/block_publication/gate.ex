defmodule Lasso.BlockPublication.Gate do
  @moduledoc """
  Local serving permissions, owned by the application and read directly by RPCs.
  One journal consumer writes each table. A worker restart retains its revision
  and boot; an application restart creates a fresh boot with no serving grants.
  """

  alias Lasso.BlockPublication.{Block, Scope}
  @table :lasso_block_publications

  @type key :: {String.t(), pos_integer()}
  @type grant :: map()

  @spec create_table!(atom(), keyword()) :: :ok
  def create_table!(table \\ @table, opts \\ []) do
    :ets.new(table, [:named_table, :public, :set, read_concurrency: true])

    :ets.insert(table, [
      {:boot, Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)},
      {:bootstrapped, false},
      {:retired, false},
      {:scope, Keyword.get(opts, :scope)}
    ])

    :ok
  end

  @spec boot(atom()) :: String.t()
  def boot(table \\ @table), do: :ets.lookup_element(table, :boot, 2)
  @spec bootstrapped(atom()) :: true
  def bootstrapped(table \\ @table), do: :ets.insert(table, {:bootstrapped, true})
  @spec retire(atom()) :: true
  def retire(table \\ @table), do: :ets.insert(table, {:retired, true})
  @spec retired?(atom()) :: boolean()
  def retired?(table \\ @table), do: :ets.lookup_element(table, :retired, 2)

  @spec install(key(), map(), String.t(), atom()) :: :ok
  def install(key, state, member, table \\ @table) do
    revision = state["revision"]

    current = revision(key, table)

    if revision > current do
      permission =
        cond do
          Map.has_key?(Map.get(state, "fenced_boots", %{}), boot(table)) ->
            {:closed, :member_fenced}

          state["phase"] in ["closing", "disabling"] ->
            {:closed, :publication_changing}

          state["phase"] == "disabled" ->
            :disabled

          state["active_members"][member] != boot(table) ->
            {:closed, :member_not_admitted}

          is_nil(state["published"]) ->
            {:closed, :publication_pending}

          true ->
            block = state["published"]

            {:open,
             %{
               block:
                 block
                 |> Map.take(["height", "hash", "timestamp_ms"])
                 |> Map.put("number", block["header"]["number"]),
               max_age_ms: state["max_age_ms"],
               epoch: state["published_epoch"],
               number_json: Jason.encode!(block["header"]["number"]),
               header_json: Jason.encode!(block["header"]),
               evidence: state["evidence"],
               chain_change: state["chain_change"]
             }}
        end

      :ets.insert(table, {key, revision, permission})
      Lasso.BlockPublication.Handoff.notify(key, table)
    end

    :ok
  end

  @spec revision(key(), atom()) :: integer()
  def revision(key, table \\ @table) do
    case :ets.lookup(table, key) do
      [{_, revision, _}] -> revision
      [] -> -1
    end
  end

  @spec managed?(key(), atom()) :: boolean()
  def managed?(key, table \\ @table), do: :ets.member(table, key)

  @spec read(key(), integer(), atom()) :: {:ok, grant()} | {:error, atom()} | :unmanaged
  def read(key, now_ms \\ System.system_time(:millisecond), table \\ @table) do
    cond do
      :ets.lookup_element(table, :retired, 2) ->
        {:error, :member_retired}

      not managed?(key, table) and
          not Scope.supports?(key, :ets.lookup_element(table, :scope, 2)) ->
        :unmanaged

      not :ets.lookup_element(table, :bootstrapped, 2) ->
        {:error, :publication_bootstrapping}

      true ->
        case :ets.lookup(table, key) do
          [{_, _, {:open, grant}}] ->
            with :ok <- Block.fresh?(grant.block["timestamp_ms"], now_ms, grant.max_age_ms),
                 do: {:ok, grant}

          [{_, _, {:closed, reason}}] ->
            {:error, reason}

          [{_, _, :disabled}] ->
            :unmanaged

          [] ->
            :unmanaged
        end
    end
  rescue
    ArgumentError -> {:error, :publication_unavailable}
  end
end
