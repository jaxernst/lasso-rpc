defmodule Lasso.BlockPublication.PublicationTest do
  use ExUnit.Case, async: false
  alias Lasso.BlockPublication.{Block, Gate, Publication}

  @members ["a", "b", "c"]
  @tables [:publication_a, :publication_b, :publication_c]
  @key {"customer", 1}
  @now 1_800_000_000_000

  setup do
    for table <- @tables do
      Gate.create_table!(table)
      Gate.bootstrapped(table)
    end

    boots =
      Map.new(Enum.zip(@members, @tables), fn {member, table} -> {member, Gate.boot(table)} end)

    state =
      Enum.reduce(@members, Publication.new(@members, 60_000), fn m, s ->
        apply!(s, {:join, m, boots[m], nil})
      end)

    %{state: state, boots: boots}
  end

  test "retained replies, closure barrier, lost commits, stale messages and stale blocks", c do
    s = publish(c.state, c.boots, block(100))
    install_all(s)
    assert heights() == [100, 100, 100]
    assert heights(@now + 60_001) == [:error, :error, :error]

    closing = prepare(s, c.boots, block(101))
    Gate.install(@key, closing, "a", :publication_a)
    a = apply!(closing, {:closed, closing["epoch"], "a", c.boots["a"]})
    assert a["published"]["height"] == 100
    assert heights() == [:error, 100, 100]
    Gate.install(@key, closing, "b", :publication_b)
    ab = apply!(a, {:closed, closing["epoch"], "b", c.boots["b"]})
    assert ab["phase"] == "closing"
    assert heights() == [:error, :error, 100]

    Gate.install(@key, ab, "c", :publication_c)
    committed = apply!(ab, {:closed, closing["epoch"], "c", c.boots["c"]})
    Gate.install(@key, committed, "a", :publication_a)
    assert heights() == [101, :error, :error]
    install_all(s)
    assert heights() == [101, :error, :error]
    install_all(committed)
    assert heights() == [101, 101, 101]

    assert {:error, :stale_command} =
             Publication.apply(committed, {:closed, closing["epoch"], "a", c.boots["a"]})

    assert {:error, :ineligible_candidate} =
             Publication.apply(committed, {:propose, "b", c.boots["b"], block(100)})
  end

  test "a new boot cannot inherit a grant or replace a partitioned boot", c do
    s = publish(c.state, c.boots, block(101))
    install_all(s)
    :ets.delete(:publication_b)
    Gate.create_table!(:publication_b)
    Gate.bootstrapped(:publication_b)
    Gate.install(@key, s, "b", :publication_b)
    assert heights() == [101, :error, 101]
    new_boot = Gate.boot(:publication_b)

    assert {:error, :previous_boot_requires_fence} =
             Publication.apply(s, {:join, "b", new_boot, nil})

    fenced = apply!(s, {:fence, "b", c.boots["b"], "VM externally stopped"})
    assert {:error, :boot_fenced} = Publication.apply(fenced, {:join, "b", c.boots["b"], nil})
    joined = apply!(fenced, {:join, "b", new_boot, nil})
    boots = Map.put(c.boots, "b", new_boot)
    rejoined = publish(joined, boots, block(101))
    install_all(rejoined)
    assert heights() == [101, 101, 101]
    assert rejoined["fences"] != []
  end

  test "reactivation requested during disable waits for every closure and fresh admission", c do
    original = publish(c.state, c.boots, block(101))
    install_all(original)
    disabling = apply!(original, :disable)
    resumed = apply!(disabling, :enable)
    assert resumed["phase"] == "disabling"
    install_all(resumed)
    assert heights() == [:error, :error, :error]

    partial = apply!(resumed, {:closed, resumed["epoch"], "a", c.boots["a"]})
    assert partial["phase"] == "disabling"
    assert apply!(partial, :disable)["resume_after_close"] == false

    closed = close(partial, c.boots)
    assert closed["phase"] == "active"
    assert closed["active_members"] == %{}
    assert closed["minimum_height"] == 101
    install_all(closed)
    assert heights() == [:error, :error, :error]
    install_all(publish(closed, c.boots, block(101)))
    assert heights() == [101, 101, 101]
  end

  test "local floors seed the durable minimum and scopes remain independent", c do
    s = Publication.new(@members, 60_000)
    s = Enum.reduce(@members, s, fn m, s -> apply!(s, {:join, m, c.boots[m], 105}) end)

    assert {:error, :ineligible_candidate} =
             Publication.apply(s, {:propose, "a", c.boots["a"], block(104)})

    install_all(publish(s, c.boots, block(105)))
    assert :unmanaged = Gate.read({"other-customer", 1}, @now, :publication_a)
    assert :unmanaged = Gate.read({"customer", 2}, @now, :publication_a)
  end

  test "disable before the first publication does not wait for an unjoined member", c do
    state =
      Publication.new(@members, 60_000)
      |> apply!({:join, "a", c.boots["a"], 105})
      |> apply!(:disable)

    assert state["phase"] == "disabled"
    assert state["minimum_height"] == 105
    assert state["members"]["b"] == nil
    install_all(state)
    assert :unmanaged == Gate.read(@key, @now, :publication_a)
  end

  test "disable closes admitted boots without waiting for a newly configured member", c do
    original = publish(c.state, c.boots, block(101))
    install_all(original)
    disabling = original |> apply!({:add_member, "d"}) |> apply!(:disable)
    assert disabling["phase"] == "disabling"
    assert disabling["members"]["d"] == nil

    Gate.install(@key, disabling, "a", :publication_a)
    partial = apply!(disabling, {:closed, disabling["epoch"], "a", c.boots["a"]})
    assert partial["phase"] == "disabling"
    assert heights() == [:error, 101, 101]

    install_all(partial)
    disabled = close(partial, c.boots)
    assert disabled["phase"] == "disabled"
    assert disabled["minimum_height"] == 101
    install_all(disabled)
    assert :unmanaged == Gate.read(@key, @now, :publication_a)
    assert apply!(disabled, :enable)["phase"] == "joining"
  end

  test "disabled roster edits keep grants closed and preserve the floor and boot fences", c do
    published = publish(c.state, c.boots, block(101))
    disabling = apply!(published, :disable)
    assert {:error, :stale_command} = Publication.apply(disabling, {:add_member, "d"})
    assert {:error, :stale_command} = Publication.apply(disabling, {:remove_fenced_member, "b"})
    disabled = close(disabling, c.boots)

    assert {:error, :member_requires_fence} =
             Publication.apply(disabled, {:remove_fenced_member, "b"})

    edited =
      disabled
      |> apply!({:fence, "b", c.boots["b"], "VM externally stopped"})
      |> apply!({:remove_fenced_member, "b"})
      |> apply!({:add_member, "d"})

    assert edited["phase"] == "disabled"
    assert edited["minimum_height"] == 101
    assert edited["published"] == published["published"]
    assert edited["fenced_boots"][c.boots["b"]] == "b"
    assert {:error, :boot_fenced} = Publication.apply(edited, {:join, "d", c.boots["b"], 0})
    install_all(edited)
    assert :unmanaged == Gate.read(@key, @now, :publication_a)
    assert :unmanaged == Gate.read(@key, @now, :publication_c)
    assert apply!(edited, :enable)["phase"] == "joining"
  end

  test "external fencing during disable preserves closure acknowledgments", c do
    original = publish(c.state, c.boots, block(101))
    disabling = apply!(original, :disable)
    install_all(disabling)
    a_closed = apply!(disabling, {:closed, disabling["epoch"], "a", c.boots["a"]})
    fenced = apply!(a_closed, {:fence, "b", c.boots["b"], "VM externally stopped"})
    assert fenced["closed"]["a"] == c.boots["a"]
    assert fenced["phase"] == "disabling"

    disabled = apply!(fenced, {:closed, fenced["epoch"], "c", c.boots["c"]})
    assert disabled["phase"] == "disabled"
    assert disabled["active_members"] == %{}
    assert disabled["minimum_height"] == 101
    install_all(disabled)
    assert :unmanaged == Gate.read(@key, @now, :publication_a)
    assert {:error, :member_fenced} == Gate.read(@key, @now, :publication_b)
  end

  test "reactivation after fencing waits for replacement admission", c do
    disabling = c.state |> publish(c.boots, block(101)) |> apply!(:disable) |> apply!(:enable)
    a_closed = apply!(disabling, {:closed, disabling["epoch"], "a", c.boots["a"]})
    fenced = apply!(a_closed, {:fence, "b", c.boots["b"], "VM externally stopped"})
    resumed = apply!(fenced, {:closed, fenced["epoch"], "c", c.boots["c"]})
    assert resumed["phase"] == "joining"
    assert resumed["active_members"] == %{}
    assert resumed["minimum_height"] == 101
    install_all(resumed)
    assert heights() == [:error, :error, :error]
  end

  test "disagreement does not close grants; common anchor changes remain explicit evidence", c do
    s = publish(c.state, c.boots, block(100))
    s = apply!(s, {:propose, "a", c.boots["a"], block(101)})
    s = apply!(s, {:ready, s["epoch"], "a", c.boots["a"], evidence(block(101), hash(900))})
    s = apply!(s, {:ready, s["epoch"], "b", c.boots["b"], evidence(block(101), hash(100))})
    s = apply!(s, {:ready, s["epoch"], "c", c.boots["c"], evidence(block(101), hash(900))})
    assert s["phase"] == "preparing"
    s = apply!(s, {:ready, s["epoch"], "b", c.boots["b"], evidence(block(101), hash(900))})
    assert s["phase"] == "closing"
    s = close(s, c.boots)
    assert s["chain_change"]["kind"] == "anchor_hash_changed"
    assert s["chain_change"]["previous_hash"] == hash(100)
    assert s["chain_change"]["observed_hash"] == hash(900)
  end

  test "retirement is permanent for the boot even when newer snapshots arrive", c do
    s = publish(c.state, c.boots, block(100))
    install_all(s)
    Gate.retire(:publication_b)
    s = publish(s, c.boots, block(101))
    install_all(s)
    assert heights() == [101, :error, 101]
  end

  test "an externally fenced runtime cannot serve or reclaim the slot", c do
    s = publish(c.state, c.boots, block(100))
    install_all(s)
    fenced = apply!(s, {:fence, "b", c.boots["b"], "Ingress permanently excluded this boot"})
    install_all(fenced)
    assert heights() == [100, :error, 100]
    assert {:error, :boot_fenced} = Publication.apply(fenced, {:join, "b", c.boots["b"], nil})
  end

  test "disable closes all grants and re-enable retains the durable floor", c do
    s = publish(c.state, c.boots, block(101))
    install_all(s)
    disabling = apply!(s, :disable)
    Gate.install(@key, disabling, "a", :publication_a)
    a = apply!(disabling, {:closed, disabling["epoch"], "a", c.boots["a"]})
    assert a["phase"] == "disabling"
    assert heights() == [:error, 101, 101]
    install_all(a)
    disabled = close(a, c.boots)
    install_all(disabled)
    assert Enum.all?(@tables, &(Gate.read(@key, @now, &1) == :unmanaged))
    assert disabled["minimum_height"] == 101
    enabled = apply!(disabled, :enable)
    install_all(enabled)
    assert heights() == [:error, :error, :error]

    assert {:error, :ineligible_candidate} =
             Publication.apply(enabled, {:propose, "a", c.boots["a"], block(100)})

    altered_timestamp = block(101) |> Map.put("timestamp_ms", @now + 10_000)
    republished = publish(enabled, c.boots, altered_timestamp)
    assert republished["published"]["timestamp_ms"] == @now
    install_all(republished)
    assert heights() == [101, 101, 101]
  end

  test "a local floor found during re-enrollment rejects a lower candidate", c do
    s = publish(c.state, c.boots, block(100))
    s = s |> apply!(:disable) |> close(c.boots) |> apply!(:enable)
    s = apply!(s, {:propose, "a", c.boots["a"], block(100)})
    proof = evidence(block(100), hash(100)) |> Map.put("minimum_height", 105)
    s = apply!(s, {:ready, s["epoch"], "a", c.boots["a"], proof})
    assert s["phase"] == "active"
    assert s["candidate"] == nil
    assert s["minimum_height"] == 105

    assert {:error, :ineligible_candidate} =
             Publication.apply(s, {:propose, "b", c.boots["b"], block(104)})
  end

  test "malformed, oversized, stale and future evidence is rejected" do
    header = block(100)["header"]
    assert {:error, :invalid_block} = Block.decode(Map.delete(header, "hash"), @now, 60_000)

    assert {:error, :invalid_block} =
             Block.decode(Map.put(header, "transactions", [%{}]), @now, 60_000)

    assert {:error, :invalid_block} =
             Block.decode(
               Map.put(header, "extra", String.duplicate("x", 1_048_576)),
               @now,
               60_000
             )

    assert {:error, :block_stale} = Block.decode(header, @now + 60_001, 60_000)
    assert {:error, :block_in_future} = Block.decode(header, @now - 15_001, 60_000)
  end

  defp publish(s, boots, block), do: s |> prepare(boots, block) |> close(boots)

  defp prepare(s, boots, block) do
    s = apply!(s, {:propose, "a", boots["a"], block})

    Enum.reduce(@members, s, fn m, s ->
      apply!(
        s,
        {:ready, s["epoch"], m, boots[m],
         evidence(block, s["published"] && s["published"]["hash"])}
      )
    end)
  end

  defp close(s, boots),
    do: Enum.reduce(@members, s, fn m, s -> apply!(s, {:closed, s["epoch"], m, boots[m]}) end)

  defp apply!(s, cmd) do
    assert {:ok, next} = Publication.apply(s, cmd)
    next
  end

  defp install_all(s),
    do: Enum.each(Enum.zip(@members, @tables), fn {m, t} -> Gate.install(@key, s, m, t) end)

  defp heights(now \\ @now),
    do:
      Enum.map(@tables, fn table ->
        case Gate.read(@key, now, table) do
          {:ok, grant} -> grant.block["height"]
          _ -> :error
        end
      end)

  defp evidence(block, anchor), do: %{"block_hash" => block["hash"], "anchor_hash" => anchor}

  defp block(n) do
    header = %{
      "number" => Lasso.JSONRPC.Quantity.encode(n),
      "hash" => hash(n),
      "parentHash" => hash(n - 1),
      "timestamp" => Lasso.JSONRPC.Quantity.encode(div(@now, 1_000)),
      "transactions" => []
    }

    {:ok, block} = Block.decode(header, @now, 60_000)
    block
  end

  defp hash(n),
    do: ("0x" <> String.pad_leading(Integer.to_string(n, 16), 64, "0")) |> String.downcase()
end
