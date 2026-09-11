defmodule Lasso.RPC.HeadRecoveryClusterTest do
  use ExUnit.Case, async: false
  alias Lasso.Test.HeadRecoveryPeer, as: Peer
  @moduletag :integration
  @moduletag timeout: 90_000

  test "BEAM peers repair missed updates and recover after complete application state loss" do
    {_output, 0} = System.cmd("epmd", ["-daemon"])
    :ok = LocalCluster.start()

    endpoint =
      Application.get_env(:lasso, LassoWeb.Endpoint)
      |> Keyword.put(:server, false)
      |> Keyword.put(:http, ip: {127, 0, 0, 1}, port: 0)

    {:ok, cluster} =
      LocalCluster.start_link(2,
        prefix: "headrecovery#{System.unique_integer([:positive])}",
        applications: [:lasso],
        environment: [
          lasso: [
            {LassoWeb.Endpoint, endpoint}
          ]
        ]
      )

    on_exit(fn -> if Process.alive?(cluster), do: GenServer.stop(cluster, :normal, 30_000) end)
    {:ok, [a, b]} = LocalCluster.nodes(cluster)
    key = {"public", 56}
    for member <- [a, b], do: assert(:ok == :erpc.call(member, Peer, :configure, [key]))
    :ok = :erpc.call(a, Peer, :seed, [key, 100])
    eventually(fn -> match?(%{height: 100}, :erpc.call(b, Peer, :hint, [key])) end)
    assert [] == :erpc.call(b, Peer, :floor, [key])

    :ok = :erpc.call(b, Peer, :notifications, [false])
    :ok = :erpc.call(a, Peer, :seed, [key, 101])
    eventually(fn -> match?(%{height: 101}, :erpc.call(a, Peer, :hint, [key])) end)
    assert %{height: 100} = :erpc.call(b, Peer, :hint, [key])
    :ok = :erpc.call(b, Peer, :notifications, [true])
    eventually(fn -> match?(%{height: 101}, :erpc.call(b, Peer, :hint, [key])) end)

    assert true == :erpc.call(b, Peer, :restart_worker, [])
    :ok = :erpc.call(b, Peer, :configure, [key])
    assert %{height: 101} = :erpc.call(b, Peer, :hint, [key])
    old_generation = :erpc.call(a, Peer, :generation, [])
    :ok = :erpc.call(a, Application, :stop, [:lasso])
    assert %{height: 101} = :erpc.call(b, Peer, :hint, [key])
    assert {:ok, _} = :erpc.call(a, Application, :ensure_all_started, [:lasso])
    :ok = :erpc.call(a, Peer, :configure, [key])
    assert old_generation != :erpc.call(a, Peer, :generation, [])
    assert [] == :erpc.call(a, Peer, :floor, [key])
    eventually(fn -> match?(%{height: 101}, :erpc.call(a, Peer, :hint, [key])) end)
  end

  defp eventually(fun, attempts \\ 150)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    unless fun.() do
      Process.sleep(40)
      eventually(fun, attempts - 1)
    end
  end
end
