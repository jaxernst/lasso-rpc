defmodule Lasso.Test.Harness.Settle do
  @moduledoc "Named surface deadlines and operation-scoped fleet accounting."
  import ExUnit.Assertions

  def listen(event) do
    owner = self()
    ref = make_ref()

    :ok =
      :telemetry.attach(
        ref,
        event,
        &__MODULE__.forward/4,
        {owner, ref}
      )

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(ref) end)
    %{id: ref, event: event}
  end

  @doc false
  def forward(event, measurements, metadata, {owner, ref}) do
    send(owner, {:surface, ref, event, measurements, metadata})
  end

  def unlisten(%{id: ref}), do: :telemetry.detach(ref)

  def await(name, predicate, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    check(name, predicate, deadline)
  end

  defp check(name, predicate, deadline) do
    case predicate.() do
      {:ok, result} ->
        result

      other ->
        remaining = deadline - System.monotonic_time(:millisecond)
        assert remaining > 0, "settle deadline: #{name}; last surface: #{inspect(other)}"
        # A bounded wait between surface requests; never reads private state.
        receive do
          {:settle_wakeup, ^name} -> :ok
        after
          min(10, remaining) -> :ok
        end

        check(name, predicate, deadline)
    end
  end

  def event(%{id: ref, event: signal}, match, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    receive_event(ref, signal, match, deadline)
  end

  defp receive_event(ref, signal, match, deadline) do
    receive do
      {:surface, ^ref, event, measurements, metadata} ->
        if match.(metadata),
          do: {event, measurements, metadata},
          else: receive_event(ref, signal, match, deadline)
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        flunk("settle deadline: telemetry #{inspect(signal)}")
    end
  end

  @doc """
  Counts scoped sends between fleet cursors around a completed operation.

  The callback must return only after its correlated closing marker. Callers own
  the fleets and quiesce other matching producers. This does not cover future
  background traffic, other nodes, or response delivery by held handlers.
  """
  def closed(marker, fleets, scope) do
    # The router rewrites wire IDs. A test owns these fleets, has one operation
    # in flight, and accounts for every matching wire request between cursors.
    cursors = Enum.map(fleets, &length(Lasso.Test.Harness.Fleet.drain(&1)))
    result = marker.()

    reports =
      Enum.zip(fleets, cursors)
      |> Enum.flat_map(fn {fleet, cursor} ->
        fleet |> Lasso.Test.Harness.Fleet.drain() |> Enum.drop(cursor)
      end)

    reports =
      Enum.filter(reports, fn report ->
        report.request["method"] == scope.method and report.request["params"] == scope.params
      end)

    {result, reports}
  end
end
