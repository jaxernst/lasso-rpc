defmodule Lasso.Core.Support.CircuitBreaker.Admission do
  @moduledoc false

  alias Lasso.Core.Support.CircuitBreaker.{AdmissionReceipt, Snapshot}

  @type rejection ::
          :admission_unavailable | :circuit_open | :half_open_busy | :admission_timeout

  @spec check({String.t(), :http | :ws}, integer(), integer()) ::
          {:ok, AdmissionReceipt.t()} | {:exceptional, Snapshot.t()} | {:error, rejection()}
  def check(breaker_id, deadline_us, now_us \\ System.monotonic_time(:microsecond))
      when is_integer(deadline_us) and is_integer(now_us) do
    result =
      case Snapshot.lookup(breaker_id) do
        {:ok, snapshot} -> classify(snapshot, deadline_us, now_us)
        :missing -> {:error, :admission_unavailable}
      end

    :telemetry.execute(
      [:lasso, :circuit_breaker, :snapshot_admission],
      %{snapshot_lookups: 1, synchronous_owner_calls: 0},
      %{breaker_id: breaker_id, decision: decision(result)}
    )

    result
  rescue
    ArgumentError -> {:error, :admission_unavailable}
  end

  defp classify(%Snapshot{ready?: false}, _deadline_us, _now_us),
    do: {:error, :admission_unavailable}

  defp classify(%Snapshot{owner_pid: owner_pid}, _deadline_us, _now_us)
       when not is_pid(owner_pid),
       do: {:error, :admission_unavailable}

  defp classify(%Snapshot{owner_pid: owner_pid} = snapshot, deadline_us, now_us) do
    if Process.alive?(owner_pid),
      do: classify_live(snapshot, deadline_us, now_us),
      else: {:error, :admission_unavailable}
  end

  defp classify_live(%Snapshot{state: :closed} = snapshot, _deadline_us, _now_us) do
    {:ok,
     %AdmissionReceipt{
       breaker_id: snapshot.breaker_id,
       kind: :closed,
       generation: snapshot.generation,
       epoch: snapshot.epoch,
       owner_pid: snapshot.owner_pid
     }}
  end

  defp classify_live(
         %Snapshot{state: :open, recovery_deadline_us: recovery_deadline_us},
         _deadline_us,
         now_us
       )
       when is_integer(recovery_deadline_us) and now_us < recovery_deadline_us,
       do: {:error, :circuit_open}

  defp classify_live(%Snapshot{state: state} = snapshot, deadline_us, now_us)
       when state in [:open, :half_open] do
    if now_us >= deadline_us,
      do: {:error, :admission_timeout},
      else: {:exceptional, snapshot}
  end

  defp classify_live(%Snapshot{}, _deadline_us, _now_us),
    do: {:error, :admission_unavailable}

  defp decision({:ok, _receipt}), do: :allow
  defp decision({:exceptional, _snapshot}), do: :exceptional
  defp decision({:error, reason}), do: reason
end
