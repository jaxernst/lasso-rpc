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

  @tag timeout: 60_000
  test "a replacement head announced during its backfill reaches the client while HTTP trails it" do
    w = run(:newHeads, lag: 0, follow: &announce_during_backfill/1)

    assert w.closed == nil
    assert numbers(w) == Enum.to_list(101..(@delivered + 2))
    assert Enum.all?(w.events, &(&1["hash"] == hash(:main, number(&1))))
    assert linked?(w.events)
  end

  test "a replacement that announces every second head while HTTP catches up recovers once" do
    w = run(:newHeads, lag: 0, delivered: 102, follow: &announce_even_heads/1)

    assert w.closed == nil
    assert numbers(w) == Enum.to_list(101..115)
    assert Enum.all?(w.events, &(&1["hash"] == hash(:main, number(&1))))
    assert linked?(w.events)
  end

  test "a log emitted before the replacement subscribed is replayed once HTTP reaches it" do
    w = replay_logs(live: [log_at(:main, 104)])
    assert additions(w) == main_logs(101..105)
  end

  test "replay covers the whole block a replacement's first live log is part of" do
    w = replay_logs(live: [log_at(:main, 104, 1)], block_logs: %{{:main, 104} => [0, 1]})
    assert additions(w) == main_logs(101..104) ++ [log_at(:main, 104, 1), log_at(:main, 105)]
  end

  test "a replacement's delayed removal below replay does not mark where its logs began" do
    w = replay_logs(live: [removed(log_at(:fork, 102)), log_at(:main, 104)], a_fork: 102)
    assert additions(w) == [log_at(:main, 101), log_at(:fork, 102) | main_logs(102..105)]
  end

  test "a replacement's late log at the replayed head does not mark where its logs began" do
    w = replay_logs(live: [log_at(:main, 102), log_at(:main, 104)])
    assert additions(w) == main_logs(101..105)
  end

  test "a replacement's delayed removal above replay owes the blocks below it" do
    w = replay_logs(live: [removed(log_at(:fork, 104))])
    assert additions(w) == main_logs(101..105)
  end

  test "a reorg while the replacement's socket is down replays a log new to its block" do
    live = [log_at(:main, 104), removed(log_at(:other, 106))]

    w =
      run(:logs,
        lag: 0,
        delivered: 102,
        block_logs: %{{:main, 103} => []},
        follow: &reorg_while_socket_down(&1, live)
      )

    assert w.closed == nil
    assert Enum.take(additions(w), 2) == main_logs(101..102)

    assert Enum.filter(additions(w), &(&1["blockHash"] != hash(:main, height(&1)))) ==
             Enum.map(103..107, &log_at(:fork, &1))
  end

  test "logs continue without a gap or duplicate on a replacement 2 blocks behind" do
    w = run(:logs, lag: 2)
    blocks = Enum.map(w.events, &hex(&1["blockNumber"]))

    assert w.closed == nil
    assert blocks == Enum.to_list(101..(@delivered - 2 + @ticks))
    assert Enum.all?(w.events, &(&1["blockHash"] == hash(:main, hex(&1["blockNumber"]))))
  end

  defp assert_contiguous(w, lag) do
    assert {lag, w.closed} == {lag, nil}
    assert {lag, numbers(w)} == {lag, Enum.to_list(101..(@delivered - lag + @ticks))}
    assert Enum.all?(w.events, &(&1["hash"] == hash(:main, number(&1))))
    assert linked?(w.events)
  end

  defp run(kind, opts) do
    lag = Keyword.fetch!(opts, :lag)
    delivered = Keyword.get(opts, :delivered, @delivered)

    {:ok, chain} =
      Agent.start_link(fn ->
        %{
          a: @start,
          b: @start - lag,
          a_dead: false,
          fork_at: opts[:fork_at],
          a_fork: opts[:a_fork],
          block_logs: Keyword.get(opts, :block_logs, %{}),
          hold: false
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
      holds: [],
      upgrades: [],
      closed: nil,
      killed_at: nil
    }

    try do
      params = if kind == :logs, do: ["logs", %{"address" => @address}], else: ["newHeads"]
      Rpc.send!(wire, "eth_subscribe", params, 1)

      w =
        await(w, &(&1.client_sub != nil and &1.subs.a != []), "client and upstream subscriptions")

      w =
        Enum.reduce((@start + 1)..delivered, w, fn n, w ->
          Agent.update(chain, &%{&1 | a: n, b: n - lag})
          notify(w, :a, n)
          notify(w, :b, n - lag)
          await(w, &(length(&1.events) == n - @start), "head #{n} from the first upstream")
        end)

      case opts[:follow] do
        nil -> w |> fail_first() |> follow(lag, opts)
        scripted -> w |> hold_heads() |> fail_first() |> scripted.()
      end
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

  # The replacement's head over HTTP trails its WebSocket by one block. Its head is announced
  # while the backfill's head request is held, so recovery buffers it before replay returns.
  defp announce_during_backfill(w) do
    w = await_head_request(w)
    notify(w, :b, @delivered + 1)
    w = serve_head(w, @delivered)
    w = await(w, &reached?(&1, @delivered + 1), "head #{@delivered + 1}", 35_000)
    Agent.update(w.chain, &%{&1 | b: @delivered + 1})
    notify(w, :b, @delivered + 2)
    await(w, &reached?(&1, @delivered + 2), "head #{@delivered + 2}")
  end

  # Each round the replacement announces the next even head while a head request is held, and
  # HTTP answers it at the previous announcement; HTTP reaches 114 once the announcements stop.
  defp announce_even_heads(w) do
    w =
      Enum.reduce(104..114//2, await_head_request(w), fn n, w ->
        w = await(w, &(&1.holds != [] or reached?(&1, n - 2)), "round #{n}")
        notify(w, :b, n)
        answer_head(w, n - 2, n)
      end)

    w = serve_head(w, 114)
    w = await(w, &reached?(&1, 114), "heads through 114")
    w = advance_b(w, 115)
    await(w, &reached?(&1, 115), "head 115")
  end

  # The replacement subscribed after block 103's logs, so it never pushes them. It buffers
  # `live` while replay reaches only 102, and HTTP then serves 103 before 104.
  defp replay_logs(opts) do
    {live, opts} = Keyword.pop!(opts, :live)
    w = run(:logs, [lag: 0, delivered: 102, follow: &buffer_logs_above_replay(&1, live)] ++ opts)
    assert w.closed == nil
    w
  end

  defp buffer_logs_above_replay(w, live) do
    w = await_head_request(w)
    for event <- live, report <- w.subs.b, logs?(report), do: Fleet.notify(report, event)
    w = w |> answer_head(102, 104) |> answer_head(103, 104) |> serve_head(104)
    w = await(w, &reached?(&1, 104), "logs through 104")
    w = advance_b(w, 105)
    await(w, &reached?(&1, 105), "log 105")
  end

  # Block 103 has no matching log on the first branch. While replay owes 106 for the held
  # removal, the replacement's socket goes down with its reconnects held, and the chain reorgs
  # from 103 onto a branch whose block 103 has a matching log; HTTP then serves that branch.
  defp reorg_while_socket_down(w, live) do
    w = await_head_request(w)
    for event <- live, report <- w.subs.b, logs?(report), do: Fleet.notify(report, event)
    w = w |> answer_head(102, 104) |> answer_head(104, 106) |> await_head_request()

    Fleet.script(w.fleets.b, "fixture_upgrade", [], {:respond, fn _ -> {:hold, make_ref()} end})
    for report <- w.subs.b, do: send(report.connection, :fixture_disconnect)
    Agent.update(w.chain, &%{&1 | fork_at: 103})
    w = serve_head(w, 106)
    w = await(w, &reached?(&1, 106), "logs through 106")

    Fleet.script(w.fleets.b, "fixture_upgrade", [], {:answer, true})
    for token <- w.upgrades, do: Fleet.release(w.fleets.b, token, {:answer, true})
    w = await(w, &(Enum.count(&1.subs.b, fn report -> logs?(report) end) > 1), "resubscription")
    w = advance_b(%{w | upgrades: []}, 107)
    await(w, &reached?(&1, 107), "log 107")
  end

  defp logs?(report), do: match?(["logs" | _], report.request["params"])
  defp additions(w), do: Enum.reject(w.events, & &1["removed"])
  defp main_logs(range), do: Enum.map(range, &log_at(:main, &1))
  defp removed(log), do: %{log | "removed" => true}

  defp hold_heads(w) do
    Agent.update(w.chain, &%{&1 | hold: true})
    w
  end

  defp await_head_request(w),
    do: await(w, &(&1.holds != []), "a held HTTP head request on the replacement")

  # Answers the replacement's next head request at `head`, unless recovery has already
  # delivered the announced height without asking again.
  defp answer_head(w, head, announced) do
    w = await(w, &(&1.holds != [] or reached?(&1, announced)), "head request at #{head}")
    Agent.update(w.chain, &%{&1 | b: head})

    case w.holds do
      [token | rest] ->
        :ok = Fleet.release(w.fleets.b, token, {:answer, hex(head)})
        %{w | holds: rest}

      [] ->
        w
    end
  end

  # Answers held and later head requests at `head` without holding them.
  defp serve_head(w, head) do
    Agent.update(w.chain, &%{&1 | b: head, hold: false})
    for token <- w.holds, do: :ok = Fleet.release(w.fleets.b, token, {:answer, hex(head)})
    %{w | holds: []}
  end

  defp reached?(w, n), do: Enum.any?(w.events, &(height(&1) >= n))
  defp height(event), do: hex(event["number"] || event["blockNumber"])

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
        ["logs" | _] -> Fleet.notify(report, log(id, n, state))
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

  defp track(w, %{request: %{"method" => "fixture_upgrade"}, action: {:hold, token}}),
    do: %{w | upgrades: w.upgrades ++ [token]}

  defp track(w, %{transport: :http, action: {:hold, token}}),
    do: %{w | holds: w.holds ++ [token]}

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

    Fleet.script(
      fleet,
      "eth_blockNumber",
      [],
      respond.(fn _, s ->
        if id == :b and s.hold, do: {:hold, make_ref()}, else: {:answer, hex(s[id])}
      end)
    )

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

        logs =
          Enum.flat_map(range, fn n ->
            branch = branch(id, n, s)
            for index <- Map.get(s.block_logs, {branch, n}, [0]), do: log_at(branch, n, index)
          end)

        {:answer, logs}
      end)
    )

    Fleet.script(
      fleet,
      "eth_subscribe",
      [],
      respond.(fn _, _ -> {:answer, "0x#{id}#{System.unique_integer([:positive])}"} end)
    )
  end

  defp branch(:a, n, %{a_fork: n}), do: :fork
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

  defp log(id, n, state), do: log_at(branch(id, n, state), n)

  defp log_at(branch, n, index \\ 0) do
    %{
      "address" => @address,
      "topics" => [hash(:topic, 0)],
      "data" => "0x",
      "blockNumber" => hex(n),
      "blockHash" => hash(branch, n),
      "transactionHash" => hash("tx#{index}", n),
      "transactionIndex" => hex(index),
      "logIndex" => hex(index),
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
