defmodule Lasso.Harness.SubscriptionLaggingFailoverTest do
  use ExUnit.Case, async: false
  alias Lasso.Test.Harness.{Fleet, Rpc, Tenant}
  @moduletag :harness
  @moduletag feature: ["core-websocket-6"]

  # Two upstreams serve one chain. The client receives heads 101 to 105 from the first,
  # which then dies; the replacement trails it by `lag` blocks and advances one block per tick.
  @start 100
  @delivered 105
  @ticks 8
  @tick_ms 250
  @address "0x00000000000000000000000000000000000000aa"

  test "newHeads continues contiguously on a replacement 1, 2 or 3 blocks behind" do
    for lag <- 1..3, do: assert_contiguous(run(:newHeads, lag: lag), lag)
  end

  test "newHeads continues contiguously on a replacement at the delivered head" do
    assert_contiguous(run(:newHeads, lag: 0), 0)
  end

  test "a replacement behind on another branch at the delivered head is replayed as a reorg" do
    for lag <- [0, 2] do
      w = run(:newHeads, lag: lag, fork_at: @delivered)
      last = @delivered - lag + @ticks

      assert {lag, w.closed} == {lag, nil}
      # The client sees the competing block at the delivered height before any child of it.
      assert {lag, numbers(w)} ==
               {lag, Enum.to_list(101..@delivered) ++ Enum.to_list(@delivered..last)}

      assert {lag, Enum.map(Enum.drop(w.events, @delivered - @start), & &1["hash"])} ==
               {lag, Enum.map(@delivered..last, &hash(:fork, &1))}

      assert linked?(w.events)
    end
  end

  @tag timeout: 90_000
  test "a replacement that never reaches the delivered head closes at the recovery deadline" do
    w = run(:newHeads, lag: 2, frozen: true, wait_ms: 36_000)

    assert {:remote, 1011, _} = w.closed.reason
    assert w.closed.at_ms in 29_000..33_000
    assert numbers(w) == Enum.to_list(101..@delivered)
  end

  test "logs continue without a gap or duplicate on a replacement 2 blocks behind" do
    w = run(:logs, lag: 2)
    blocks = Enum.map(w.events, &hex(&1["blockNumber"]))

    assert w.closed == nil
    assert blocks == Enum.to_list(101..(@delivered - 2 + @ticks))
    assert Enum.all?(w.events, &(&1["blockHash"] == hash(:main, hex(&1["blockNumber"]))))
  end

  test "a replacement catching up does not deliver logs from below the first delivered log" do
    w = run(:logs, lag: 2, first: @delivered)

    assert w.closed == nil

    assert Enum.map(w.events, &hex(&1["blockNumber"])) ==
             Enum.to_list(@delivered..(@delivered - 2 + @ticks))
  end

  test "a reorg below the delivered log during recovery delivers its removals and new-chain logs" do
    fork = @delivered - 1
    last = @delivered - 2 + @ticks
    # The main chain has no log at the fork height, so only replay from the fork reaches it.
    w = run(:logs, lag: 2, fork_at: fork, no_log: fork)

    assert w.closed == nil

    assert Enum.map(w.events, &{hex(&1["blockNumber"]), &1["removed"], &1["blockHash"]}) ==
             Enum.map([101, 102, 103, @delivered], &{&1, false, hash(:main, &1)}) ++
               [{@delivered, true, hash(:main, @delivered)}] ++
               Enum.map(fork..last, &{&1, false, hash(:fork, &1)})
  end

  defp assert_contiguous(w, lag) do
    assert {lag, w.closed} == {lag, nil}
    assert {lag, numbers(w)} == {lag, Enum.to_list(101..(@delivered - lag + @ticks))}
    assert Enum.all?(w.events, &(&1["hash"] == hash(:main, number(&1))))
    assert linked?(w.events)
  end

  defp run(kind, opts) do
    lag = Keyword.fetch!(opts, :lag)
    first = Keyword.get(opts, :first, @start + 1)

    {:ok, chain} =
      Agent.start_link(fn ->
        %{
          a: @start,
          b: @start - lag,
          a_dead: false,
          fork_at: opts[:fork_at],
          no_log: opts[:no_log]
        }
      end)

    suffix = System.unique_integer([:positive])
    a = Fleet.start!(self(), "lagging-a-#{suffix}")
    b = Fleet.start!(self(), "lagging-b-#{suffix}")
    script(a, :a, chain)
    script(b, :b, chain)

    providers =
      Map.new([a, b], &{&1.name, %{"ws_url" => &1.ws_url, "subscribe_new_heads" => true}})

    tenant = Tenant.open!([a, b], providers: providers)

    url = %{
      URI.parse(tenant.rpc_url)
      | scheme: "ws",
        path: "/ws" <> URI.parse(tenant.rpc_url).path
    }

    wire = Rpc.wire!(URI.to_string(url))

    w = %{
      kind: kind,
      chain: chain,
      fleets: %{a: a, b: b},
      ref: wire.reference,
      client_sub: nil,
      subs: %{a: [], b: []},
      events: [],
      closed: nil,
      killed_at: nil
    }

    try do
      params = if kind == :logs, do: ["logs", %{"address" => @address}], else: ["newHeads"]
      Rpc.send!(wire, "eth_subscribe", params, 1)

      w =
        await(w, &(&1.client_sub != nil and &1.subs.a != []), "client and upstream subscriptions")

      w =
        Enum.reduce((@start + 1)..@delivered, w, fn n, w ->
          Agent.update(chain, &%{&1 | a: n, b: n - lag})
          if n >= first, do: notify(w, :a, n)
          notify(w, :b, n - lag)

          await(
            w,
            &(length(&1.events) == Enum.count(first..n//1, fn m -> m != opts[:no_log] end)),
            "head #{n} from the first upstream"
          )
        end)

      fail_first(w) |> follow(lag, opts)
    after
      close_client(wire)
      Tenant.close!(tenant)
      Fleet.resume_listener(a)
      Fleet.stop(a)
      Fleet.stop(b)
      Agent.stop(chain)
    end
  end

  # The client process exits once Lasso closes its socket.
  defp close_client(wire) do
    Rpc.close!(wire)
  catch
    :exit, _reason -> :ok
  end

  defp fail_first(w) do
    Agent.update(w.chain, &%{&1 | a_dead: true})
    :ok = Fleet.suspend_listener(w.fleets.a)
    for report <- w.subs.a, do: send(report.connection, :fixture_disconnect)
    %{w | killed_at: now()}
  end

  defp follow(w, lag, opts) do
    w =
      Enum.reduce_while(1..@ticks, w, fn tick, w ->
        w = pump(w, w.killed_at + tick * @tick_ms)

        cond do
          w.closed -> {:halt, w}
          opts[:frozen] -> {:cont, w}
          true -> {:cont, advance_b(w, @delivered - lag + tick)}
        end
      end)

    cond do
      w.closed -> w
      opts[:frozen] -> pump(w, w.killed_at + Keyword.fetch!(opts, :wait_ms))
      true -> pump(w, now() + 1_000)
    end
  end

  defp advance_b(w, n) do
    Agent.update(w.chain, &%{&1 | b: n})
    notify(w, :b, n)
    w
  end

  defp notify(w, id, n) do
    state = Agent.get(w.chain, & &1)

    for report <- w.subs[id] do
      case report.request["params"] do
        ["newHeads" | _] -> Fleet.notify(report, block(id, n, state))
        ["logs" | _] -> if log = log(id, n, state), do: Fleet.notify(report, log)
      end
    end
  end

  defp await(w, done?, name, timeout \\ 5_000) do
    deadline = now() + timeout

    Stream.iterate(w, &pump(&1, min(now() + 20, deadline)))
    |> Enum.find(&(done?.(&1) or &1.closed != nil or now() >= deadline))
    |> tap(&assert(done?.(&1), "#{name}: #{inspect(Map.take(&1, [:closed, :events]))}"))
  end

  defp pump(w, until) do
    ref = w.ref

    receive do
      {:rpc_frame, ^ref, {:text, bytes}} ->
        w |> frame(Jason.decode!(bytes)) |> pump(until)

      {:rpc_disconnect, ^ref, %{reason: reason}} ->
        %{w | closed: %{reason: reason, at_ms: now() - w.killed_at}}

      {:fleet, _pid, report} ->
        w |> track(report) |> pump(until)
    after
      max(until - now(), 0) -> w
    end
  end

  defp frame(w, %{"id" => 1, "result" => sub}), do: %{w | client_sub: sub}

  defp frame(%{client_sub: sub} = w, %{"params" => %{"subscription" => sub, "result" => r}}),
    do: %{w | events: w.events ++ [r]}

  defp frame(w, _other), do: w

  defp track(
         w,
         %{transport: :ws, request: %{"method" => "eth_subscribe"}, action: {:answer, _}} = r
       ),
       do: update_in(w.subs[id(w, r)], &(&1 ++ [r]))

  defp track(w, %{request: %{"method" => "eth_unsubscribe", "params" => [sub | _]}} = r),
    do:
      update_in(w.subs[id(w, r)], fn subs -> Enum.reject(subs, &(&1.action == {:answer, sub})) end)

  defp track(w, _report), do: w

  defp id(w, report), do: if(report.fleet == w.fleets.a.name, do: :a, else: :b)

  defp script(fleet, id, chain) do
    respond = fn handler ->
      {:respond,
       fn request ->
         state = Agent.get(chain, & &1)
         if id == :a and state.a_dead, do: {:disconnect, 1011}, else: handler.(request, state)
       end}
    end

    Fleet.script(fleet, "eth_chainId", [], respond.(fn _, _ -> {:answer, "0x7a69"} end))
    Fleet.script(fleet, "eth_blockNumber", [], respond.(fn _, s -> {:answer, hex(s[id])} end))

    Fleet.script(
      fleet,
      "eth_getBlockByNumber",
      [],
      respond.(fn %{"params" => [tag | _]}, s ->
        n = if String.starts_with?(tag, "0x"), do: hex(tag), else: s[id]
        {:answer, if(n <= s[id], do: block(id, n, s))}
      end)
    )

    Fleet.script(
      fleet,
      "eth_getLogs",
      [],
      respond.(fn %{"params" => [filter | _]}, s ->
        range = hex(filter["fromBlock"])..min(hex(filter["toBlock"]), s[id])//1
        {:answer, range |> Enum.map(&log(id, &1, s)) |> Enum.reject(&is_nil/1)}
      end)
    )

    Fleet.script(
      fleet,
      "eth_subscribe",
      [],
      respond.(fn _, _ -> {:answer, "0x#{id}#{System.unique_integer([:positive])}"} end)
    )
  end

  defp branch(:b, n, %{fork_at: fork_at}) when is_integer(fork_at) and n >= fork_at, do: :fork
  defp branch(_id, _n, _state), do: :main

  defp block(id, n, state) do
    parent = if branch(id, n, state) == :fork and n > state.fork_at, do: :fork, else: :main

    %{
      "number" => hex(n),
      "hash" => hash(branch(id, n, state), n),
      "parentHash" => hash(parent, n - 1),
      "timestamp" => hex(1_700_000_000 + n),
      "miner" => "0x" <> String.duplicate("0", 40),
      "gasLimit" => "0x1c9c380",
      "gasUsed" => "0x0"
    }
  end

  defp log(id, n, %{no_log: n} = state) when id == :a or n < state.fork_at, do: nil

  defp log(id, n, state) do
    %{
      "address" => @address,
      "topics" => [hash(:topic, 0)],
      "data" => "0x",
      "blockNumber" => hex(n),
      "blockHash" => hash(branch(id, n, state), n),
      "transactionHash" => hash(:tx, n),
      "transactionIndex" => "0x0",
      "logIndex" => "0x0",
      "removed" => false
    }
  end

  defp hash(branch, n),
    do: "0x" <> Base.encode16(:crypto.hash(:sha256, "lagging-#{branch}-#{n}"), case: :lower)

  defp linked?(events) do
    events
    |> Enum.reduce_while(%{}, fn head, seen ->
      n = number(head)

      if map_size(seen) == 0 or seen[n - 1] == head["parentHash"],
        do: {:cont, Map.put(seen, n, head["hash"])},
        else: {:halt, :unlinked}
    end)
    |> is_map()
  end

  defp numbers(w), do: Enum.map(w.events, &number/1)
  defp number(head), do: hex(head["number"])
  defp now, do: System.monotonic_time(:millisecond)
  defp hex("0x" <> digits), do: String.to_integer(digits, 16)
  defp hex(n) when is_integer(n), do: "0x" <> Integer.to_string(n, 16)
end
