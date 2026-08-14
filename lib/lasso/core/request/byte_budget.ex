defmodule Lasso.Core.Request.ByteBudget do
  @moduledoc false

  use GenServer

  @table :lasso_request_byte_budget
  @persistent_key {__MODULE__, :configuration}
  @default_limit_bytes 128 * 1_024 * 1_024
  @default_small_bucket_count 256
  @large_bucket_count 4
  @default_minimum_charge_bytes 4_096
  @audit_interval_ms 1_000
  @cas_retries 8

  defmodule Reservation do
    @moduledoc false

    @enforce_keys [:reference, :bucket, :generation, :bytes, :charge_bytes]
    defstruct @enforce_keys

    @type bucket :: {:small | :large, non_neg_integer()}

    @type t :: %__MODULE__{
            reference: reference(),
            bucket: bucket(),
            generation: reference(),
            bytes: non_neg_integer(),
            charge_bytes: pos_integer()
          }
  end

  @type rejection :: :byte_capacity | :budget_unavailable | :contention

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec reserve(non_neg_integer(), pid()) :: {:ok, Reservation.t()} | {:error, rejection()}
  def reserve(bytes, owner_pid \\ self())
      when is_integer(bytes) and bytes >= 0 and is_pid(owner_pid) do
    case configuration() do
      %{generation: generation} = config ->
        reference = make_ref()
        charge_bytes = max(bytes, config.minimum_charge_bytes)

        case candidate_buckets(config, reference, charge_bytes) do
          [] ->
            bucket = {:large, :erlang.phash2(reference, config.large_bucket_count)}
            increment_stat(config.table, bucket, 2, 1)
            {:error, :byte_capacity}

          buckets ->
            reserve_candidates(
              config,
              reference,
              generation,
              bytes,
              charge_bytes,
              owner_pid,
              buckets
            )
        end

      _missing ->
        {:error, :budget_unavailable}
    end
  end

  @spec release(Reservation.t()) :: :ok
  def release(%Reservation{} = reservation) do
    case configuration() do
      %{generation: generation} = config when generation == reservation.generation ->
        case release_bucket(config, reservation, @cas_retries) do
          :defer -> send(config.owner, {:deferred_release, reservation})
          :ok -> :ok
        end

        :ok

      _stale_or_missing ->
        :ok
    end
  end

  @spec stats() :: map()
  def stats do
    case configuration() do
      nil ->
        %{available?: false, limit_bytes: 0, used_bytes: 0, reservations: 0}

      config ->
        totals =
          Enum.reduce(config.bucket_ids, empty_stats(), fn bucket, acc ->
            Map.merge(acc, bucket_stats(config, bucket), fn _key, left, right -> left + right end)
          end)

        Map.merge(totals, %{
          available?: true,
          limit_bytes: config.limit_bytes,
          bucket_count: length(config.bucket_ids),
          small_bucket_count: config.small_bucket_count,
          large_bucket_count: config.large_bucket_count,
          small_bucket_limit_bytes: config.small_bucket_limit_bytes,
          large_bucket_limit_bytes: config.large_bucket_limit_bytes,
          max_reservation_bytes: config.large_bucket_limit_bytes,
          minimum_charge_bytes: config.minimum_charge_bytes
        })
    end
  end

  @impl true
  def init(opts) do
    limit_bytes =
      Keyword.get(
        opts,
        :limit_bytes,
        Application.get_env(:lasso, :inflight_request_byte_limit, @default_limit_bytes)
      )

    small_bucket_count =
      Keyword.get(
        opts,
        :bucket_count,
        Application.get_env(
          :lasso,
          :inflight_request_byte_budget_buckets,
          @default_small_bucket_count
        )
      )

    minimum_charge_bytes =
      Keyword.get(
        opts,
        :minimum_charge_bytes,
        Application.get_env(
          :lasso,
          :inflight_request_minimum_charge_bytes,
          @default_minimum_charge_bytes
        )
      )

    validate_configuration!(limit_bytes, small_bucket_count, minimum_charge_bytes)

    table =
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

    generation = make_ref()
    small_capacity_bytes = div(limit_bytes, 2)
    large_capacity_bytes = limit_bytes - small_capacity_bytes
    small_bucket_limit_bytes = div(small_capacity_bytes, small_bucket_count)
    large_bucket_limit_bytes = div(large_capacity_bytes, @large_bucket_count)

    if small_bucket_limit_bytes < minimum_charge_bytes do
      raise ArgumentError, "in-flight request byte budget has insufficient small-bucket capacity"
    end

    bucket_specs =
      Enum.map(0..(small_bucket_count - 1), &{{:small, &1}, small_bucket_limit_bytes}) ++
        Enum.map(0..(@large_bucket_count - 1), &{{:large, &1}, large_bucket_limit_bytes})

    Enum.each(bucket_specs, fn {bucket, bucket_limit_bytes} ->
      :ets.insert(table, {bucket, generation, bucket_limit_bytes, 0, %{}})
      :ets.insert(table, {{:stats, bucket}, 0, 0, 0, 0, 0})
    end)

    config = %{
      owner: self(),
      table: table,
      generation: generation,
      limit_bytes: limit_bytes,
      bucket_ids: Enum.map(bucket_specs, &elem(&1, 0)),
      small_bucket_count: small_bucket_count,
      large_bucket_count: @large_bucket_count,
      small_bucket_limit_bytes: small_bucket_limit_bytes,
      large_bucket_limit_bytes: large_bucket_limit_bytes,
      minimum_charge_bytes: minimum_charge_bytes
    }

    :persistent_term.put(@persistent_key, config)
    schedule_audit()
    {:ok, config}
  end

  @impl true
  def handle_info(:audit, state) do
    Enum.each(state.bucket_ids, &audit_bucket(state, &1, @cas_retries))
    schedule_audit()
    {:noreply, state}
  end

  def handle_info({:deferred_release, %Reservation{} = reservation}, state) do
    case release_bucket(state, reservation, @cas_retries) do
      :defer -> Process.send_after(self(), {:deferred_release, reservation}, 1)
      :ok -> :ok
    end

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    case configuration() do
      %{generation: generation} when generation == state.generation ->
        :persistent_term.erase(@persistent_key)

      _other ->
        :ok
    end

    :ok
  end

  defp candidate_buckets(config, reference, charge_bytes) do
    cond do
      charge_bytes <= config.small_bucket_limit_bytes ->
        two_choices(:small, reference, config.small_bucket_count)

      charge_bytes <= config.large_bucket_limit_bytes ->
        two_choices(:large, reference, config.large_bucket_count)

      true ->
        []
    end
  end

  defp two_choices(class, reference, count) do
    first = :erlang.phash2(reference, count)
    second = :erlang.phash2({reference, :alternate}, count)
    second = if second == first, do: rem(first + 1, count), else: second
    [{class, first}, {class, second}]
  end

  defp reserve_candidates(
         config,
         reference,
         generation,
         bytes,
         charge_bytes,
         owner_pid,
         buckets
       ) do
    result =
      Enum.reduce_while(buckets, :full, fn bucket, _last_result ->
        reservation = %Reservation{
          reference: reference,
          bucket: bucket,
          generation: generation,
          bytes: bytes,
          charge_bytes: charge_bytes
        }

        case reserve_bucket(config, reservation, owner_pid, @cas_retries) do
          {:ok, _reservation} = accepted -> {:halt, accepted}
          rejection -> {:cont, rejection}
        end
      end)

    case result do
      {:ok, _reservation} = accepted ->
        accepted

      :contention ->
        increment_stat(config.table, hd(buckets), 5, 1)
        {:error, :contention}

      _full_or_unavailable ->
        increment_stat(config.table, hd(buckets), 2, 1)
        {:error, :byte_capacity}
    end
  end

  defp reserve_bucket(_config, _reservation, _owner_pid, 0), do: :contention

  defp reserve_bucket(config, reservation, owner_pid, retries) do
    case :ets.lookup(config.table, reservation.bucket) do
      [row = {bucket, generation, limit, used, reservations}]
      when generation == reservation.generation ->
        if used + reservation.charge_bytes <= limit do
          next =
            {bucket, generation, limit, used + reservation.charge_bytes,
             Map.put(reservations, reservation.reference, {
               owner_pid,
               reservation.bytes,
               reservation.charge_bytes
             })}

          if replace_row(config.table, row, next) do
            increment_stat(config.table, bucket, 1, 1)
            {:ok, reservation}
          else
            reserve_bucket(config, reservation, owner_pid, retries - 1)
          end
        else
          :full
        end

      _missing_or_stale ->
        :unavailable
    end
  end

  defp release_bucket(_config, _reservation, 0), do: :defer

  defp release_bucket(config, reservation, retries) do
    case :ets.lookup(config.table, reservation.bucket) do
      [row = {bucket, generation, limit, used, reservations}]
      when generation == reservation.generation ->
        case Map.pop(reservations, reservation.reference) do
          {nil, _unchanged} ->
            :ok

          {{_owner_pid, _bytes, charge_bytes}, remaining} ->
            next = {bucket, generation, limit, max(used - charge_bytes, 0), remaining}

            if replace_row(config.table, row, next) do
              increment_stat(config.table, bucket, 3, 1)
              :ok
            else
              release_bucket(config, reservation, retries - 1)
            end
        end

      _missing_or_stale ->
        :ok
    end
  end

  defp audit_bucket(_config, _bucket, 0), do: :ok

  defp audit_bucket(config, bucket, retries) do
    case :ets.lookup(config.table, bucket) do
      [row = {^bucket, generation, limit, used, reservations}]
      when generation == config.generation ->
        {remaining, reclaimed_bytes, reclaimed_count} = reclaim_dead(reservations)

        if reclaimed_count == 0 do
          :ok
        else
          next = {bucket, generation, limit, max(used - reclaimed_bytes, 0), remaining}

          if replace_row(config.table, row, next) do
            increment_stat(config.table, bucket, 4, reclaimed_count)
          else
            audit_bucket(config, bucket, retries - 1)
          end
        end

      _missing_or_stale ->
        :ok
    end
  end

  defp reclaim_dead(reservations) do
    Enum.reduce(reservations, {%{}, 0, 0}, fn
      {reference, {owner_pid, bytes, charge_bytes}}, {remaining, reclaimed_bytes, count} ->
        if Process.alive?(owner_pid) do
          {Map.put(remaining, reference, {owner_pid, bytes, charge_bytes}), reclaimed_bytes,
           count}
        else
          {remaining, reclaimed_bytes + charge_bytes, count + 1}
        end
    end)
  end

  defp replace_row(table, old_row, new_row) do
    :ets.select_replace(table, [{old_row, [], [{:const, new_row}]}]) == 1
  end

  defp increment_stat(table, bucket, position, amount) do
    :ets.update_counter(table, {:stats, bucket}, {position + 1, amount})
  end

  defp bucket_stats(config, bucket) do
    {used_bytes, reservations} =
      case :ets.lookup(config.table, bucket) do
        [{^bucket, generation, _limit, used, entries}] when generation == config.generation ->
          {used, map_size(entries)}

        _missing ->
          {0, 0}
      end

    {accepted, rejected, released, reclaimed, contended} =
      case :ets.lookup(config.table, {:stats, bucket}) do
        [{{:stats, ^bucket}, a, r, rel, rec, con}] -> {a, r, rel, rec, con}
        _missing -> {0, 0, 0, 0, 0}
      end

    %{
      used_bytes: used_bytes,
      reservations: reservations,
      accepted: accepted,
      rejected: rejected,
      released: released,
      reclaimed: reclaimed,
      contended: contended
    }
  end

  defp empty_stats do
    %{
      used_bytes: 0,
      reservations: 0,
      accepted: 0,
      rejected: 0,
      released: 0,
      reclaimed: 0,
      contended: 0
    }
  end

  defp configuration do
    :persistent_term.get(@persistent_key, nil)
  end

  defp schedule_audit do
    Process.send_after(self(), :audit, @audit_interval_ms)
  end

  defp validate_configuration!(limit_bytes, bucket_count, minimum_charge_bytes)
       when is_integer(limit_bytes) and limit_bytes > 0 and is_integer(bucket_count) and
              bucket_count > 1 and is_integer(minimum_charge_bytes) and
              minimum_charge_bytes > 0,
       do: :ok

  defp validate_configuration!(_limit_bytes, _bucket_count, _minimum_charge_bytes) do
    raise ArgumentError, "invalid in-flight request byte budget configuration"
  end
end
