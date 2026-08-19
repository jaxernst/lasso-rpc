defmodule Lasso.Core.Request.ByteBudgetTest do
  use ExUnit.Case, async: false

  alias Lasso.Core.Request.ByteBudget

  setup do
    Application.ensure_all_started(:lasso)
    await_empty()
    :ok
  end

  test "reservations charge a fixed minimum and release exactly once" do
    before = ByteBudget.stats()
    assert {:ok, reservation} = ByteBudget.reserve(10)

    during = ByteBudget.stats()
    assert during.used_bytes == before.used_bytes + during.minimum_charge_bytes
    assert during.reservations == before.reservations + 1

    assert :ok = ByteBudget.release(reservation)
    assert :ok = ByteBudget.release(reservation)

    after_release = ByteBudget.stats()
    assert after_release.used_bytes == before.used_bytes
    assert after_release.reservations == before.reservations
  end

  test "a request larger than any fixed bucket is rejected without residue" do
    before = ByteBudget.stats()

    assert {:error, :byte_capacity} = ByteBudget.reserve(before.max_reservation_bytes + 1)

    after_rejection = ByteBudget.stats()
    assert after_rejection.used_bytes == before.used_bytes
    assert after_rejection.reservations == before.reservations
    assert after_rejection.rejected == before.rejected + 1
  end

  test "the bounded audit reclaims reservations owned by dead processes" do
    test_pid = self()

    owner =
      spawn(fn ->
        assert {:ok, reservation} = ByteBudget.reserve(8_192)
        send(test_pid, {:reserved, reservation})
      end)

    monitor = Process.monitor(owner)
    assert_receive {:reserved, _reservation}
    assert_receive {:DOWN, ^monitor, :process, ^owner, reason}
    assert reason in [:normal, :noproc]

    send(ByteBudget, :audit)
    await_empty()
    assert ByteBudget.stats().reclaimed >= 1
  end

  test "parallel reservations preserve the configured aggregate bound" do
    stats = ByteBudget.stats()
    charge = stats.minimum_charge_bytes

    results =
      1..256
      |> Task.async_stream(
        fn _index ->
          case ByteBudget.reserve(charge) do
            {:ok, reservation} ->
              ByteBudget.release(reservation)
              :ok

            {:error, :contention} ->
              :contention
          end
        end,
        max_concurrency: 64,
        timeout: 5_000,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &(&1 in [:ok, :contention]))
    await_empty()
    assert ByteBudget.stats().used_bytes <= stats.limit_bytes
  end

  defp await_empty(attempts \\ 100)

  defp await_empty(0), do: flunk("byte budget did not return to zero")

  defp await_empty(attempts) do
    case ByteBudget.stats() do
      %{used_bytes: 0, reservations: 0} ->
        :ok

      _busy ->
        Process.sleep(10)
        await_empty(attempts - 1)
    end
  end
end
