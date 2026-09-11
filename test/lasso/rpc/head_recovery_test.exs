defmodule Lasso.RPC.HeadRecoveryTest do
  use ExUnit.Case, async: false

  alias Lasso.RPC.HeadRecovery
  @pubsub Lasso.Test.HeadRecoveryPubSub
  @topic "local_head_recovery:v1"
  @key {"recovery-test", 1}

  setup do
    start_supervised!({Phoenix.PubSub, name: @pubsub})

    for table <- [
          :recovery_floors_a,
          :recovery_floors_b,
          :recovery_floors_c,
          :recovery_hints_a,
          :recovery_hints_b,
          :recovery_hints_c
        ] do
      :ets.new(table, [:named_table, :public, :set])
    end

    :ok
  end

  test "duplicate and delayed updates converge without advancing the hard floor" do
    worker(:a)
    worker(:b)
    :ets.insert(:recovery_floors_a, {@key, 100, hash(100), make_ref()})

    eventually(fn ->
      HeadRecovery.read(@key, :recovery_hints_b) == %{height: 100, hash: hash(100)}
    end)

    Phoenix.PubSub.broadcast(
      @pubsub,
      @topic,
      {:local_heads, [{@key, 99, hash(99)}, {@key, 100, hash(100)}]}
    )

    assert :ets.lookup(:recovery_floors_b, @key) == []
    assert HeadRecovery.read(@key, :recovery_hints_b).height == 100
  end

  test "periodic repair recovers an update missed while the receiver was unsubscribed" do
    worker(:a)
    b = worker(:b)
    :ets.insert(:recovery_floors_a, {@key, 100, hash(100), make_ref()})
    eventually(fn -> match?(%{height: 100}, HeadRecovery.read(@key, :recovery_hints_b)) end)

    :sys.replace_state(b, fn state ->
      Phoenix.PubSub.unsubscribe(@pubsub, @topic)
      state
    end)

    :ets.insert(:recovery_floors_a, {@key, 101, hash(101), make_ref()})
    eventually(fn -> match?(%{height: 101}, HeadRecovery.read(@key, :recovery_hints_a)) end)
    assert HeadRecovery.read(@key, :recovery_hints_b).height == 100

    :sys.replace_state(b, fn state ->
      Phoenix.PubSub.subscribe(@pubsub, @topic)
      state
    end)

    eventually(fn -> match?(%{height: 101}, HeadRecovery.read(@key, :recovery_hints_b)) end)
  end

  test "a surviving peer repairs a replacement after the original source and its worker are gone" do
    worker(:a)
    worker(:b)
    :ets.insert(:recovery_floors_a, {@key, 101, hash(101), make_ref()})
    eventually(fn -> match?(%{height: 101}, HeadRecovery.read(@key, :recovery_hints_b)) end)
    stop_supervised!(:recovery_worker_a)
    stop_supervised!(:recovery_worker_b)
    :ets.delete_all_objects(:recovery_floors_a)
    :ets.delete_all_objects(:recovery_hints_a)
    worker(:b)
    worker(:c)

    eventually(fn -> match?(%{height: 101}, HeadRecovery.read(@key, :recovery_hints_c)) end)
    assert :ets.lookup(:recovery_floors_b, @key) == []
    assert :ets.lookup(:recovery_floors_c, @key) == []
  end

  test "unknown scopes, malformed entries, and oversized batches do not create hints" do
    b = worker(:b)

    send(
      b,
      {:local_heads,
       [{{"unknown", 1}, 100, hash(100)}, {@key, -1, hash(100)}, {@key, 100, "bad"}, :bad]}
    )

    send(b, {:local_heads, List.duplicate({@key, 100, hash(100)}, 65)})
    :sys.get_state(b)
    assert :ets.tab2list(:recovery_hints_b) == []
  end

  test "bounded pages eventually propagate more scopes than one batch" do
    local? = fn {profile, chain} -> profile == "recovery-test" and chain in 1..200 end
    worker(:a, local?)
    worker(:b, local?)

    for chain <- 1..200 do
      :ets.insert(:recovery_floors_a, {{"recovery-test", chain}, 100, hash(100), make_ref()})
    end

    eventually(fn -> :ets.info(:recovery_hints_b, :size) == 200 end)
    assert :ets.info(:recovery_floors_b, :size) == 0
  end

  test "same-height hash disagreement remains visible until a higher height arrives" do
    b = worker(:b)
    send(b, {:local_heads, [{@key, 100, hash(100)}, {@key, 100, hash(99)}]})
    :sys.get_state(b)
    assert HeadRecovery.read(@key, :recovery_hints_b) == %{height: 100, hash: nil}
    send(b, {:local_heads, [{@key, 100, hash(100)}]})
    :sys.get_state(b)
    assert HeadRecovery.read(@key, :recovery_hints_b).hash == nil
    send(b, {:local_heads, [{@key, 101, hash(101)}]})
    :sys.get_state(b)
    assert HeadRecovery.read(@key, :recovery_hints_b).hash == hash(101)
  end

  test "configuration churn and inactive floor rows cannot stop later repair" do
    local? = fn {profile, chain} -> profile == "recovery-test" and chain in 1..200 end
    a = worker(:a, local?)
    worker(:b, local?)

    for chain <- 1..300 do
      :ets.insert(:recovery_floors_a, {{"recovery-test", chain}, nil, nil, make_ref()})
      :ets.insert(:recovery_hints_a, {{"recovery-test", chain}, 100, hash(100), 0})
    end

    eventually(fn -> :ets.info(:recovery_hints_a, :size) == 200 end)
    :ets.delete_all_objects(:recovery_floors_a)
    :ets.insert(:recovery_floors_a, {@key, 101, hash(101), make_ref()})
    eventually(fn -> match?(%{height: 101}, HeadRecovery.read(@key, :recovery_hints_b)) end)
    assert Process.alive?(a)
  end

  test "repeated repair requests do not restart the scan ahead of later scopes" do
    local? = fn {profile, chain} -> profile == "recovery-test" and chain in 1..200 end

    for chain <- 1..200 do
      :ets.insert(:recovery_hints_a, {{"recovery-test", chain}, 100, hash(100), 0})
    end

    a = worker(:a, local?, 100_000)
    worker(:b, local?)

    for _ <- 1..8 do
      :sys.replace_state(a, &%{&1 | next_repair: System.monotonic_time(:millisecond) - 1})
      send(a, :repair_local_heads)
      send(a, :tick)
      :sys.get_state(a)
    end

    eventually(fn -> :ets.info(:recovery_hints_b, :size) == 200 end)
  end

  defp worker(which, local? \\ fn key -> key == @key end, interval \\ 10) do
    {name, floors, hints} =
      case which do
        :a -> {:recovery_worker_a, :recovery_floors_a, :recovery_hints_a}
        :b -> {:recovery_worker_b, :recovery_floors_b, :recovery_hints_b}
        :c -> {:recovery_worker_c, :recovery_floors_c, :recovery_hints_c}
      end

    start_supervised!(
      Supervisor.child_spec(
        {HeadRecovery,
         name: name,
         floors: floors,
         table: hints,
         pubsub: @pubsub,
         local?: local?,
         interval_ms: interval},
        id: name
      )
    )
  end

  defp hash(height), do: "0x" <> String.pad_leading(Integer.to_string(height, 16), 64, "0")

  defp eventually(fun, attempts \\ 150)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    unless fun.() do
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end
end
