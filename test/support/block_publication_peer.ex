defmodule Lasso.Test.BlockPublicationPeer do
  @moduledoc false
  alias Lasso.BlockPublication.{Block, Gate, Runtime}
  alias Lasso.JSONRPC.Quantity

  defmodule Journal do
    @behaviour Lasso.BlockPublication.Journal
    alias Lasso.BlockPublication.Postgres, as: Durable

    def list do
      available(fn ->
        with {:ok, rows} <- Durable.list() do
          {:ok, Enum.sort_by(rows, fn {_, publication} -> publication["phase"] != "disabled" end)}
        end
      end)
    end

    def changes(revisions), do: available(fn -> Durable.changes(revisions) end)
    def ensure(key, members, age), do: available(fn -> Durable.ensure(key, members, age) end)

    def command(key, command) do
      case {command, :persistent_term.get({__MODULE__, :blocked_history}, nil)} do
        {{:fence, _, _, _}, {keys, owner}} when is_map_key(keys, key) ->
          send(owner, {:fencing_history, self(), key})

          receive do
            :continue -> :ok
          end

        _ ->
          :ok
      end

      available(fn -> Durable.command(key, command) end)
    end

    def compare_and_apply(key, snapshot, command) do
      case {command, :persistent_term.get({__MODULE__, :blocked_closures}, nil)} do
        {{:closed, _, _, _}, owner} when is_pid(owner) ->
          send(owner, {:closure_waiting, node(), self(), key})

          receive do
            :continue -> available(fn -> Durable.compare_and_apply(key, snapshot, command) end)
          after
            30_000 -> {:error, :journal_unavailable}
          end

        _ ->
          available(fn -> Durable.compare_and_apply(key, snapshot, command) end)
      end
    end

    defp available(fun) do
      if :persistent_term.get({__MODULE__, :available}, true),
        do: fun.(),
        else: {:error, :journal_unavailable}
    end
  end

  def block_closures(owner), do: :persistent_term.put({Journal, :blocked_closures}, owner)

  def journal_available(value), do: :persistent_term.put({Journal, :available}, value)

  def block_history(keys, owner),
    do: :persistent_term.put({Journal, :blocked_history}, {Map.from_keys(keys, true), owner})

  def configure(member, members, key) do
    Application.put_env(:lasso, :node_id, member)
    :persistent_term.put({Lasso.Cluster.Topology, :self_node_id}, member)
    set_height(key, 100)
    :ok = Supervisor.terminate_child(Lasso.Supervisor, Lasso.BlockPublication.Supervisor)

    Application.put_env(:lasso, :block_publication,
      members: members,
      journal: Journal,
      probe: __MODULE__,
      interval_ms: 100
    )

    {:ok, _} = Supervisor.restart_child(Lasso.Supervisor, Lasso.BlockPublication.Supervisor)
    :ok
  end

  def set_height(key, height), do: :persistent_term.put({__MODULE__, key}, height)
  def latest(key, _), do: {:ok, block(:persistent_term.get({__MODULE__, key})), nil}

  def prepare(key, candidate, published, _) do
    if :persistent_term.get({__MODULE__, key}) >= candidate["height"] do
      {:ok,
       %{
         "block_hash" => candidate["hash"],
         "anchor_hash" => published && published["hash"],
         "provider_id" => "regional-fixture"
       }}
    else
      {:error, :provider_behind}
    end
  end

  def read(key) do
    case Gate.read(key) do
      {:ok, grant} -> {:ok, grant.block["height"]}
      other -> other
    end
  end

  def restart_worker do
    old_boot = Gate.boot()
    :ok = Supervisor.terminate_child(Lasso.Supervisor, Lasso.BlockPublication.Supervisor)
    {:ok, _} = Supervisor.restart_child(Lasso.Supervisor, Lasso.BlockPublication.Supervisor)
    old_boot == Gate.boot()
  end

  def crash_worker do
    pid = Process.whereis(Runtime)
    Process.exit(pid, :kill)
    pid
  end

  def suspend, do: :sys.suspend(Runtime)

  def restart_application do
    old_boot = Gate.boot()
    :ok = Application.stop(:lasso)
    {:ok, _} = Application.ensure_all_started(:lasso)
    {old_boot, Gate.boot()}
  end

  def resume, do: :sys.resume(Runtime)

  def tracked?(key), do: Map.has_key?(:sys.get_state(Runtime).snapshots, key)

  def replay(key, publication) do
    send(Runtime, {make_ref(), {key, {:ok, publication}}})
    tracked?(key)
  end

  defp block(n) do
    header = %{
      "number" => Quantity.encode(n),
      "hash" => hash(n),
      "parentHash" => hash(n - 1),
      "timestamp" => Quantity.encode(System.system_time(:second)),
      "transactions" => []
    }

    {:ok, block} = Block.decode(header, System.system_time(:millisecond), 60_000)
    block
  end

  defp hash(n),
    do: ("0x" <> String.pad_leading(Integer.to_string(n, 16), 64, "0")) |> String.downcase()
end
