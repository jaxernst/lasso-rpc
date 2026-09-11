defmodule Lasso.BlockPublication.ClusterTest do
  use ExUnit.Case, async: false
  use Lasso.Test.PublicationDBCase
  import Ecto.Query
  alias Lasso.Test.BlockPublicationPeer, as: Peer
  alias Lasso.BlockPublication.Postgres, as: BlockPublicationJournal

  @moduletag :integration
  @moduletag timeout: 120_000

  test "three BEAM instances reconcile PostgreSQL grants through interruption and worker restart" do
    {_output, 0} = System.cmd("epmd", ["-daemon"])
    :ok = LocalCluster.start()

    endpoint =
      Application.get_env(:lasso, LassoWeb.Endpoint)
      |> Keyword.put(:server, false)
      |> Keyword.put(:http, ip: {127, 0, 0, 1}, port: 0)

    {:ok, cluster} =
      LocalCluster.start_link(3,
        prefix: "publication#{System.unique_integer([:positive])}",
        applications: [:lasso],
        environment: [
          lasso: [
            {LassoWeb.Endpoint, endpoint},
            {Repo,
             Keyword.put(Application.get_env(:lasso, Repo), :pool, DBConnection.ConnectionPool)},
            {:block_publication, [journal: Lasso.BlockPublication.Postgres]}
          ]
        ]
      )

    on_exit(fn -> if Process.alive?(cluster), do: GenServer.stop(cluster, :normal, 30_000) end)
    {:ok, nodes} = LocalCluster.nodes(cluster)
    key = {"cluster-" <> Ecto.UUID.generate(), 1}
    {profile, _} = key
    members = ["a", "b", "c"]

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, _} = BlockPublicationJournal.ensure(key, members, 60_000)
    end)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from(p in BlockPublicationJournal, where: p.profile == ^profile))
      end)
    end)

    for {node, member} <- Enum.zip(nodes, members),
        do: assert(:ok == :erpc.call(node, Peer, :configure, [member, members, key]))

    eventually(fn -> reads(nodes, key) == [ok: 100, ok: 100, ok: 100] end)

    for node <- nodes, do: :erpc.call(node, Peer, :journal_available, [false])
    for node <- nodes, do: :erpc.call(node, Peer, :set_height, [key, 101])
    Process.sleep(300)
    assert reads(nodes, key) == [ok: 100, ok: 100, ok: 100]
    for node <- nodes, do: :erpc.call(node, Peer, :journal_available, [true])

    for node <- nodes, do: :erpc.call(node, Peer, :set_height, [key, 101])
    eventually(fn -> Enum.any?(reads(nodes, key), &(&1 == {:ok, 101})) end)

    assert Enum.all?(reads(nodes, key), fn result ->
             result == {:ok, 101} or match?({:error, _}, result)
           end)

    eventually(fn -> reads(nodes, key) == [ok: 101, ok: 101, ok: 101] end)

    [a, b, c] = nodes
    assert :ok == :erpc.call(c, Peer, :suspend, [])
    for node <- nodes, do: :erpc.call(node, Peer, :set_height, [key, 102])
    Process.sleep(400)
    assert reads(nodes, key) == [ok: 101, ok: 101, ok: 101]
    assert true == :erpc.call(a, Peer, :restart_worker, [])
    assert reads(nodes, key) == [ok: 101, ok: 101, ok: 101]
    assert :ok == :erpc.call(c, Peer, :resume, [])
    eventually(fn -> reads(nodes, key) == [ok: 102, ok: 102, ok: 102] end)

    assert :ok == :erpc.call(b, Lasso.BlockPublication.Runtime, :quiesce, [])
    assert {:error, :member_retired} == :erpc.call(b, Peer, :read, [key])
    assert true == :erpc.call(b, Peer, :restart_worker, [])
    assert {:error, :member_retired} == :erpc.call(b, Peer, :read, [key])
    for node <- nodes, do: :erpc.call(node, Peer, :set_height, [key, 103])
    Process.sleep(300)
    assert {:ok, 102} == :erpc.call(a, Peer, :read, [key])

    {old_boot, new_boot} = :erpc.call(b, Peer, :restart_application, [])
    refute old_boot == new_boot
    eventually(fn -> reads(nodes, key) == [ok: 103, ok: 103, ok: 103] end)

    :erpc.call(b, Peer, :journal_available, [false])
    {unfenced_boot, replacement_boot} = :erpc.call(b, Peer, :restart_application, [])
    refute unfenced_boot == replacement_boot
    assert {:error, :publication_bootstrapping} == :erpc.call(b, Peer, :read, [key])
    assert {:error, :publication_bootstrapping} == :erpc.call(b, Peer, :read, [{"public", 1}])
    :erpc.call(b, Peer, :journal_available, [true])
    eventually(fn -> :erpc.call(b, Peer, :read, [key]) == {:error, :member_not_admitted} end)
    for node <- nodes, do: :erpc.call(node, Peer, :set_height, [key, 104])
    Process.sleep(300)
    assert {:ok, 103} == :erpc.call(a, Peer, :read, [key])

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, _} =
               BlockPublicationJournal.command(
                 key,
                 {:fence, "b", unfenced_boot, "Previous application was stopped by this test"}
               )
    end)

    eventually(fn -> reads(nodes, key) == [ok: 104, ok: 104, ok: 104] end)
    assert :ok == :erpc.call(b, Lasso.BlockPublication.Runtime, :quiesce, [])

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, _} = BlockPublicationJournal.command(key, {:remove_fenced_member, "b"})
    end)

    for node <- [a, c], do: :erpc.call(node, Peer, :set_height, [key, 105])
    eventually(fn -> reads([a, c], key) == [ok: 105, ok: 105] end)

    previous =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        previous = BlockPublicationJournal.get(key)
        assert {:ok, _} = BlockPublicationJournal.command(key, :disable)
        previous
      end)

    eventually(fn -> reads([a, c], key) == [:unmanaged, :unmanaged] end)

    for node <- [a, c] do
      refute :erpc.call(node, Peer, :tracked?, [key])
      refute :erpc.call(node, Peer, :replay, [key, previous])
      assert :unmanaged == :erpc.call(node, Peer, :read, [key])
      assert true == :erpc.call(node, Peer, :restart_worker, [])
      :erpc.call(node, Peer, :set_height, [key, 106])
    end

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, _} = BlockPublicationJournal.command(key, :enable)
    end)

    eventually(fn -> reads([a, c], key) == [ok: 106, ok: 106] end)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, _} = BlockPublicationJournal.command(key, {:add_member, "never-joined"})
      assert {:ok, _} = BlockPublicationJournal.command(key, :disable)
    end)

    eventually(fn -> reads([a, c], key) == [:unmanaged, :unmanaged] end)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      assert BlockPublicationJournal.get(key)["minimum_height"] == 106

      assert {:ok, %{"phase" => "disabled"}} =
               BlockPublicationJournal.command(key, {:remove_fenced_member, "never-joined"})

      assert {:ok, %{"phase" => "active"}} = BlockPublicationJournal.command(key, :enable)
    end)

    for node <- [a, c], do: :erpc.call(node, Peer, :set_height, [key, 107])
    eventually(fn -> reads([a, c], key) == [ok: 107, ok: 107] end)

    {retired_boot, replacement_boot} = :erpc.call(c, Peer, :restart_application, [])
    refute retired_boot == replacement_boot
    eventually(fn -> reads([a, c], key) == [ok: 107, ok: 107] end)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      state = BlockPublicationJournal.get(key)
      assert state["fenced_boots"][retired_boot] == "c"
      assert state["members"]["c"] == replacement_boot
      assert state["minimum_height"] == 107
    end)

    retained_keys =
      for _ <- 1..32, do: {"cluster-" <> Ecto.UUID.generate(), 1}

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        profiles = Enum.map(retained_keys, &elem(&1, 0))
        Repo.delete_all(from(p in BlockPublicationJournal, where: p.profile in ^profiles))
      end)
    end)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, _} =
               Repo.transaction(fn ->
                 for retained_key <- retained_keys do
                   assert {:ok, _} = BlockPublicationJournal.ensure(retained_key, ["c"], 60_000)

                   assert {:ok, _} =
                            BlockPublicationJournal.command(
                              retained_key,
                              {:join, "c", replacement_boot, 90}
                            )

                   assert {:ok, %{"phase" => "disabled"}} =
                            BlockPublicationJournal.command(retained_key, :disable)
                 end
               end)
    end)

    :erpc.call(c, Peer, :block_history, [retained_keys, self()])

    try do
      shutdown =
        Task.async(fn -> :erpc.call(c, Lasso.BlockPublication.Runtime, :quiesce, [1_000]) end)

      assert_receive {:fencing_history, cleanup_worker, _}, 2_000

      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        state = BlockPublicationJournal.get(key)
        assert state["fenced_boots"][replacement_boot] == "c"
        assert state["minimum_height"] == 107
      end)

      assert {:error, :shutdown_timeout} = Task.await(shutdown, 2_000)
      refute :erpc.call(c, Process, :alive?, [cleanup_worker])
      assert {:error, :member_retired} == :erpc.call(c, Peer, :read, [key])
    after
      :erpc.call(c, Peer, :block_history, [[], nil])
    end

    {^replacement_boot, next_boot} = :erpc.call(c, Peer, :restart_application, [])
    refute replacement_boot == next_boot
    eventually(fn -> reads([a, c], key) == [ok: 107, ok: 107] end)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      for retained_key <- retained_keys do
        state = BlockPublicationJournal.get(retained_key)
        assert state["fenced_boots"][replacement_boot] == "c"
        assert state["minimum_height"] == 90
        assert state["phase"] == "disabled"
      end
    end)

    :erpc.call(c, Peer, :journal_available, [false])

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, _} = BlockPublicationJournal.command(key, :disable)
    end)

    eventually(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        state = BlockPublicationJournal.get(key)
        state["closed"]["a"] == state["members"]["a"]
      end)
    end)

    assert {:ok, 107} == :erpc.call(c, Peer, :read, [key])

    assert {:error, :journal_unavailable} ==
             :erpc.call(c, Lasso.BlockPublication.Runtime, :quiesce, [])

    assert {:error, :member_retired} == :erpc.call(c, Peer, :read, [key])

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      state = BlockPublicationJournal.get(key)

      assert {:ok, %{"phase" => "disabled", "minimum_height" => 107}} =
               BlockPublicationJournal.command(
                 key,
                 {:fence, "c", state["members"]["c"],
                  "Runtime quiescence permanently closed its serving gate"}
               )
    end)

    eventually(fn -> :erpc.call(a, Peer, :read, [key]) == :unmanaged end)
  end

  test "four scopes close concurrently without blocking the runtime or opening before durable acknowledgments" do
    {_output, 0} = System.cmd("epmd", ["-daemon"])
    :ok = LocalCluster.start()

    endpoint =
      Application.get_env(:lasso, LassoWeb.Endpoint)
      |> Keyword.put(:server, false)
      |> Keyword.put(:http, ip: {127, 0, 0, 1}, port: 0)

    {:ok, cluster} =
      LocalCluster.start_link(2,
        prefix: "closure#{System.unique_integer([:positive])}",
        applications: [:lasso],
        environment: [
          lasso: [
            {LassoWeb.Endpoint, endpoint},
            {Repo,
             Keyword.put(Application.get_env(:lasso, Repo), :pool, DBConnection.ConnectionPool)},
            {:block_publication, [journal: Lasso.BlockPublication.Postgres]}
          ]
        ]
      )

    on_exit(fn -> if Process.alive?(cluster), do: GenServer.stop(cluster, :normal, 30_000) end)
    {:ok, nodes} = LocalCluster.nodes(cluster)
    keys = for _ <- 1..4, do: {"cluster-" <> Ecto.UUID.generate(), 1}
    profiles = Enum.map(keys, &elem(&1, 0))
    members = ["a", "b"]

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      for key <- keys, do: assert({:ok, _} = BlockPublicationJournal.ensure(key, members, 60_000))
    end)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from(p in BlockPublicationJournal, where: p.profile in ^profiles))
      end)
    end)

    for {node, member} <- Enum.zip(nodes, members) do
      for key <- keys, do: :erpc.call(node, Peer, :set_height, [key, 100])
      assert :ok == :erpc.call(node, Peer, :configure, [member, members, hd(keys)])
    end

    eventually(fn -> Enum.all?(keys, &(reads(nodes, &1) == [ok: 100, ok: 100])) end)
    for node <- nodes, do: :erpc.call(node, Peer, :block_closures, [self()])

    try do
      for node <- nodes, key <- keys, do: :erpc.call(node, Peer, :set_height, [key, 101])

      workers =
        for _ <- 1..8 do
          assert_receive {:closure_waiting, node, pid, key}, 2_000
          {node, pid, key}
        end

      assert MapSet.new(Enum.map(workers, fn {node, _, key} -> {node, key} end)) ==
               MapSet.new(for node <- nodes, key <- keys, do: {node, key})

      for node <- nodes do
        state = :erpc.call(node, :sys, :get_state, [Lasso.BlockPublication.Runtime, 1_000])
        assert map_size(state.closure_tasks) == 4
        send({Lasso.BlockPublication.Runtime, node}, :publication_changed)
      end

      for key <- keys,
          do:
            assert(
              reads(nodes, key) == [error: :publication_changing, error: :publication_changing]
            )

      refute_receive {:closure_waiting, _, _, _}, 150

      [restarting | _] = nodes
      retired_workers = for {^restarting, pid, _} <- workers, do: pid
      monitors = Enum.map(retired_workers, &Process.monitor/1)
      :erpc.call(restarting, Peer, :crash_worker, [])

      for monitor <- monitors do
        assert_receive {:DOWN, ^monitor, :process, _, _}, 2_000
      end

      replacements =
        for _ <- 1..4 do
          assert_receive {:closure_waiting, ^restarting, pid, key}, 2_000
          refute pid in retired_workers
          {restarting, pid, key}
        end

      assert MapSet.new(Enum.map(replacements, &elem(&1, 2))) == MapSet.new(keys)

      for key <- keys,
          do:
            assert(
              reads(nodes, key) == [error: :publication_changing, error: :publication_changing]
            )

      refute_receive {:closure_waiting, _, _, _}, 150
      workers = Enum.reject(workers, fn {node, _, _} -> node == restarting end) ++ replacements
      for node <- nodes, do: :erpc.call(node, Peer, :block_closures, [nil])
      for {_, pid, _} <- workers, do: send(pid, :continue)
      eventually(fn -> Enum.all?(keys, &(reads(nodes, &1) == [ok: 101, ok: 101])) end)
    after
      for node <- nodes, do: :erpc.call(node, Peer, :block_closures, [nil])
    end
  end

  defp reads(nodes, key), do: Enum.map(nodes, &:erpc.call(&1, Peer, :read, [key]))
  defp eventually(fun, attempts \\ 150)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    unless fun.() do
      Process.sleep(100)
      eventually(fun, attempts - 1)
    end
  end
end
