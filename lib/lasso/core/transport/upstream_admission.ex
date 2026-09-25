defmodule Lasso.Core.Transport.UpstreamAdmission do
  @moduledoc false

  @default_shards 32
  @default_node_limit 512
  @default_upstream_limit 192
  @default_response_byte_limit 128 * 1_024 * 1_024
  @default_response_limit 16 * 1_024 * 1_024
  @safe_max_shards 128
  @safe_max_node_limit 4_096
  @safe_max_upstream_limit 1_024
  @safe_max_response_byte_limit 512 * 1_024 * 1_024
  @safe_max_response_limit 64 * 1_024 * 1_024

  @node_inflight 1
  @response_bytes 2
  @accepted 3
  @node_rejected 4
  @upstream_rejected 5
  @response_rejected 6
  @byte_rejected 7
  @released 8
  @reclaimed 9
  @peak_node_inflight 10
  @peak_response_bytes 11

  defmodule Lease do
    @moduledoc false

    @enforce_keys [:admission, :worker_index, :token]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            admission: GenServer.name(),
            worker_index: non_neg_integer(),
            token: reference()
          }
  end

  @type rejection ::
          :admission_unavailable
          | :node_capacity
          | :upstream_capacity
          | :response_too_large
          | :response_byte_capacity
          | :unknown_lease

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    config = configuration_from_options(name, opts)

    worker_opts = [
      admission: name,
      counters: config.counters,
      node_limit: config.node_limit,
      per_shard_upstream_limit: div(config.upstream_limit, config.shard_count),
      recovery_markers: config.recovery_markers,
      response_byte_limit: config.response_byte_limit,
      response_limit: config.response_limit
    ]

    result =
      PartitionSupervisor.start_link(
        child_spec: {__MODULE__.Worker, worker_opts},
        name: name,
        partitions: config.shard_count,
        with_arguments: fn [worker_options], partition ->
          [Keyword.put(worker_options, :partition, partition)]
        end
      )

    if match?({:ok, _pid}, result), do: :persistent_term.put(persistent_key(name), config)
    result
  end

  @spec acquire(term(), String.t(), keyword()) :: {:ok, Lease.t()} | {:error, rejection()}
  def acquire(capacity_key, upstream_instance_id, opts \\ [])
      when is_binary(upstream_instance_id) do
    admission = Keyword.get(opts, :admission, __MODULE__)
    owner = Keyword.get(opts, :owner, self())

    with %{shard_count: shard_count} = config <- configuration(admission),
         true <- is_pid(owner) do
      start_index = rem(:erlang.unique_integer([:positive]), shard_count)

      message =
        {:acquire, capacity_key, upstream_instance_id, owner, Keyword.get(opts, :metadata, %{})}

      case acquire_from_worker(config, admission, start_index, 0, message) do
        {:ok, worker_index, token} ->
          {:ok, %Lease{admission: admission, worker_index: worker_index, token: token}}

        {:error, :upstream_capacity} = rejection ->
          increment(config.counters, @upstream_rejected)

          :telemetry.execute(
            [:lasso, :upstream_admission, :rejected],
            %{count: 1},
            Keyword.get(opts, :metadata, %{})
            |> Map.put(:reason, :upstream_capacity)
            |> Map.put(:upstream_instance_id, upstream_instance_id)
          )

          rejection

        {:error, reason} ->
          {:error, reason}
      end
    else
      _missing_or_invalid -> {:error, :admission_unavailable}
    end
  rescue
    ArgumentError -> {:error, :admission_unavailable}
  catch
    :exit, _reason -> {:error, :admission_unavailable}
  end

  @spec reserve_response(Lease.t(), non_neg_integer(), pos_integer()) ::
          :ok | {:error, rejection()}
  def reserve_response(%Lease{} = lease, logical_bytes, charge_multiplier \\ 1)
      when is_integer(logical_bytes) and logical_bytes >= 0 and is_integer(charge_multiplier) and
             charge_multiplier > 0 do
    call_lease(
      lease,
      {:reserve_response, lease.token, logical_bytes, logical_bytes * charge_multiplier}
    )
  end

  @spec reject_response(Lease.t(), atom()) :: :ok | {:error, rejection()}
  def reject_response(%Lease{} = lease, reason) when is_atom(reason) do
    call_lease(lease, {:reject_response, lease.token, reason})
  end

  @spec transfer(Lease.t(), pid()) :: :ok | {:error, rejection()}
  def transfer(%Lease{} = lease, owner) when is_pid(owner) do
    call_lease(lease, {:transfer, lease.token, owner})
  end

  @spec release(Lease.t(), atom()) :: :ok
  def release(%Lease{} = lease, reason \\ :completed) when is_atom(reason) do
    case call_lease(lease, {:release, lease.token, reason}) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  @spec stats(GenServer.name()) :: map()
  def stats(admission \\ __MODULE__) do
    case configuration(admission) do
      nil ->
        %{available?: false}

      config ->
        with true <- admission_available?(admission),
             per_worker <-
               Enum.map(0..(config.shard_count - 1), &safe_worker_stats(admission, &1)),
             true <- Enum.all?(per_worker, &is_map/1) do
          available_stats(config, per_worker)
        else
          _unavailable -> %{available?: false}
        end
    end
  end

  @spec response_limit(GenServer.name()) :: pos_integer()
  def response_limit(admission \\ __MODULE__) do
    case configuration(admission) do
      %{response_limit: limit} -> limit
      _missing -> @default_response_limit
    end
  end

  @doc "Stops a named admission supervisor and removes its published configuration."
  @spec stop(GenServer.name()) :: :ok
  def stop(admission) do
    :persistent_term.erase(persistent_key(admission))

    case GenServer.whereis(admission) do
      nil -> :ok
      _pid -> PartitionSupervisor.stop(admission)
    end
  end

  @spec reserve_counter(:atomics.atomics_ref(), pos_integer(), non_neg_integer(), pos_integer()) ::
          :ok | {:error, :capacity}
  def reserve_counter(counters, index, limit, peak_index) do
    case :atomics.get(counters, index) do
      current when current >= limit ->
        {:error, :capacity}

      current ->
        case :atomics.compare_exchange(counters, index, current, current + 1) do
          result when result in [:ok, current] ->
            update_peak(counters, peak_index, current + 1)
            :ok

          _changed ->
            reserve_counter(counters, index, limit, peak_index)
        end
    end
  end

  @spec reserve_bytes(:atomics.atomics_ref(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, :capacity}
  def reserve_bytes(counters, bytes, limit) when bytes >= 0 do
    case :atomics.get(counters, @response_bytes) do
      current when current + bytes > limit ->
        {:error, :capacity}

      current ->
        case :atomics.compare_exchange(counters, @response_bytes, current, current + bytes) do
          result when result in [:ok, current] ->
            update_peak(counters, @peak_response_bytes, current + bytes)
            :ok

          _changed ->
            reserve_bytes(counters, bytes, limit)
        end
    end
  end

  @spec release_count(:atomics.atomics_ref(), pos_integer(), pos_integer()) :: :ok
  def release_count(counters, index, amount) when amount > 0 do
    :atomics.sub_get(counters, index, amount)
    :ok
  end

  @spec increment(:atomics.atomics_ref(), pos_integer(), pos_integer()) :: :ok
  def increment(counters, index, amount \\ 1) do
    :atomics.add(counters, index, amount)
    :ok
  end

  defp configuration_from_options(name, opts) do
    shard_count =
      bounded_positive_option(
        opts,
        :shards,
        Application.get_env(:lasso, :upstream_admission_shards, @default_shards),
        @safe_max_shards
      )

    config = %{
      name: name,
      counters: :atomics.new(@peak_response_bytes, signed: false),
      recovery_markers: :atomics.new(shard_count, signed: false),
      shard_count: shard_count,
      node_limit:
        bounded_positive_option(
          opts,
          :node_limit,
          Application.get_env(:lasso, :upstream_inflight_node_limit, @default_node_limit),
          @safe_max_node_limit
        ),
      upstream_limit:
        bounded_positive_option(
          opts,
          :upstream_limit,
          Application.get_env(:lasso, :upstream_inflight_origin_limit, @default_upstream_limit),
          @safe_max_upstream_limit
        ),
      response_byte_limit:
        bounded_positive_option(
          opts,
          :response_byte_limit,
          Application.get_env(
            :lasso,
            :upstream_inflight_response_byte_limit,
            @default_response_byte_limit
          ),
          @safe_max_response_byte_limit
        ),
      response_limit:
        bounded_positive_option(
          opts,
          :response_limit,
          Application.get_env(:lasso, :upstream_response_byte_limit, @default_response_limit),
          @safe_max_response_limit
        )
    }

    validate_relationships!(config)
    config
  end

  defp acquire_from_worker(config, _admission, _index, attempts, _message)
       when attempts >= config.shard_count,
       do: {:error, :upstream_capacity}

  defp acquire_from_worker(config, admission, index, attempts, message) do
    case GenServer.call(via(admission, index), message) do
      {:ok, token} ->
        {:ok, index, token}

      {:error, :upstream_capacity} ->
        acquire_from_worker(
          config,
          admission,
          rem(index + 1, config.shard_count),
          attempts + 1,
          message
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call_lease(%Lease{admission: admission, worker_index: index}, message) do
    case configuration(admission) do
      nil -> {:error, :admission_unavailable}
      _config -> GenServer.call(via(admission, index), message)
    end
  rescue
    ArgumentError -> {:error, :admission_unavailable}
  catch
    :exit, _reason -> {:error, :admission_unavailable}
  end

  defp update_peak(counters, index, current) do
    case :atomics.get(counters, index) do
      peak when peak >= current ->
        :ok

      peak ->
        case :atomics.compare_exchange(counters, index, peak, current) do
          result when result in [:ok, peak] -> :ok
          _changed -> update_peak(counters, index, current)
        end
    end
  end

  defp safe_worker_stats(admission, index) do
    GenServer.call(via(admission, index), :stats)
  rescue
    ArgumentError -> :unavailable
  catch
    :exit, _reason -> :unavailable
  end

  defp admission_available?(admission) do
    match?(pid when is_pid(pid), GenServer.whereis(admission))
  rescue
    ArgumentError -> false
  catch
    :exit, _reason -> false
  end

  defp available_stats(config, per_worker) do
    %{
      available?: true,
      node_limit: config.node_limit,
      upstream_limit: config.upstream_limit,
      response_byte_limit: config.response_byte_limit,
      response_limit: config.response_limit,
      shard_count: config.shard_count,
      node_inflight: counter(config, @node_inflight),
      response_bytes: counter(config, @response_bytes),
      accepted: counter(config, @accepted),
      node_rejected: counter(config, @node_rejected),
      upstream_rejected: counter(config, @upstream_rejected),
      response_rejected: counter(config, @response_rejected),
      byte_rejected: counter(config, @byte_rejected),
      released: counter(config, @released),
      reclaimed: counter(config, @reclaimed),
      peak_node_inflight: counter(config, @peak_node_inflight),
      peak_response_bytes: counter(config, @peak_response_bytes),
      leases: Enum.sum(Enum.map(per_worker, & &1.leases)),
      retained_responses: Enum.sum(Enum.map(per_worker, & &1.retained_responses))
    }
  end

  defp via(admission, index), do: {:via, PartitionSupervisor, {admission, index}}

  defp counter(%{counters: counters}, index), do: counter(counters, index)
  defp counter(counters, index), do: :atomics.get(counters, index)

  defp configuration(admission), do: :persistent_term.get(persistent_key(admission), nil)
  defp persistent_key(admission), do: {__MODULE__, admission}

  defp bounded_positive_option(opts, key, fallback, maximum) do
    case Keyword.get(opts, key, fallback) do
      value when is_integer(value) and value > 0 and value <= maximum ->
        value

      _invalid ->
        raise ArgumentError, "#{key} must be a positive integer no greater than #{maximum}"
    end
  end

  defp validate_relationships!(config) do
    pool_config = Application.fetch_env!(:lasso, :http_pool)
    pool_capacity = Keyword.fetch!(pool_config, :size) * Keyword.fetch!(pool_config, :count)

    cond do
      config.shard_count > config.upstream_limit ->
        raise ArgumentError, "upstream admission shards cannot exceed the origin limit"

      config.upstream_limit > config.node_limit ->
        raise ArgumentError, "the origin limit cannot exceed the node limit"

      rem(config.upstream_limit, config.shard_count) != 0 ->
        raise ArgumentError, "the origin limit must be divisible by the admission shard count"

      config.upstream_limit > pool_capacity ->
        raise ArgumentError, "the origin limit cannot exceed Finch connection capacity"

      config.response_limit * 2 > config.response_byte_limit ->
        raise ArgumentError,
              "the response byte budget must cover the conservative maximum response charge"

      true ->
        :ok
    end
  end
end

defmodule Lasso.Core.Transport.UpstreamAdmission.Worker do
  @moduledoc false

  use GenServer

  alias Lasso.Core.Transport.UpstreamAdmission

  @node_inflight 1
  @response_bytes 2
  @accepted 3
  @node_rejected 4
  @response_rejected 6
  @byte_rejected 7
  @released 8
  @reclaimed 9
  @peak_node_inflight 10

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    partition = Keyword.fetch!(opts, :partition)
    recovery_markers = Keyword.fetch!(opts, :recovery_markers)

    state = %{
      admission: Keyword.fetch!(opts, :admission),
      counters: Keyword.fetch!(opts, :counters),
      dirty_restart?: false,
      node_limit: Keyword.fetch!(opts, :node_limit),
      partition: partition,
      per_shard_upstream_limit: Keyword.fetch!(opts, :per_shard_upstream_limit),
      recovery_markers: recovery_markers,
      response_byte_limit: Keyword.fetch!(opts, :response_byte_limit),
      response_limit: Keyword.fetch!(opts, :response_limit),
      leases: %{},
      monitors: %{},
      upstream_counts: %{}
    }

    case :atomics.compare_exchange(recovery_markers, partition + 1, 0, 1) do
      :ok -> {:ok, state}
      _dirty_restart -> {:ok, %{state | dirty_restart?: true}, {:continue, :restart_admission}}
    end
  end

  @impl true
  def handle_continue(:restart_admission, state) do
    state.admission
    |> GenServer.whereis()
    |> Process.exit(:kill)

    {:stop, :dirty_partition_restart, state}
  end

  @impl true
  def handle_call({:acquire, capacity_key, upstream_instance_id, owner, metadata}, _from, state) do
    upstream_count = Map.get(state.upstream_counts, capacity_key, 0)

    cond do
      state.per_shard_upstream_limit == 0 or
          upstream_count >= state.per_shard_upstream_limit ->
        {:reply, {:error, :upstream_capacity}, state}

      UpstreamAdmission.reserve_counter(
        state.counters,
        @node_inflight,
        state.node_limit,
        @peak_node_inflight
      ) != :ok ->
        UpstreamAdmission.increment(state.counters, @node_rejected)

        emit(
          :rejected,
          %{count: 1},
          Map.put(metadata, :reason, :node_capacity),
          upstream_instance_id
        )

        {:reply, {:error, :node_capacity}, state}

      true ->
        token = make_ref()
        monitor = Process.monitor(owner)

        lease = %{
          capacity_key: capacity_key,
          charged_bytes: 0,
          count_active?: true,
          logical_bytes: 0,
          metadata: metadata,
          monitor: monitor,
          upstream_instance_id: upstream_instance_id
        }

        UpstreamAdmission.increment(state.counters, @accepted)

        emit(
          :accepted,
          %{node_inflight: :atomics.get(state.counters, @node_inflight)},
          metadata,
          upstream_instance_id
        )

        {:reply, {:ok, token},
         %{
           state
           | leases: Map.put(state.leases, token, lease),
             monitors: Map.put(state.monitors, monitor, token),
             upstream_counts: Map.put(state.upstream_counts, capacity_key, upstream_count + 1)
         }}
    end
  end

  def handle_call({:reserve_response, token, logical_bytes, charged_bytes}, _from, state) do
    case Map.fetch(state.leases, token) do
      :error ->
        {:reply, {:error, :unknown_lease}, state}

      {:ok, lease} ->
        cond do
          lease.logical_bytes + logical_bytes > state.response_limit ->
            UpstreamAdmission.increment(state.counters, @response_rejected)

            emit(
              :rejected,
              %{count: 1},
              Map.put(lease.metadata, :reason, :response_too_large),
              lease.upstream_instance_id
            )

            {:reply, {:error, :response_too_large}, state}

          UpstreamAdmission.reserve_bytes(
            state.counters,
            charged_bytes,
            state.response_byte_limit
          ) != :ok ->
            UpstreamAdmission.increment(state.counters, @byte_rejected)

            emit(
              :rejected,
              %{count: 1},
              Map.put(lease.metadata, :reason, :response_byte_capacity),
              lease.upstream_instance_id
            )

            {:reply, {:error, :response_byte_capacity}, state}

          true ->
            lease = %{
              lease
              | charged_bytes: lease.charged_bytes + charged_bytes,
                logical_bytes: lease.logical_bytes + logical_bytes
            }

            {:reply, :ok, %{state | leases: Map.put(state.leases, token, lease)}}
        end
    end
  end

  def handle_call({:reject_response, token, reason}, _from, state) do
    case Map.fetch(state.leases, token) do
      :error ->
        {:reply, {:error, :unknown_lease}, state}

      {:ok, lease} ->
        UpstreamAdmission.increment(state.counters, @response_rejected)

        emit(
          :rejected,
          %{count: 1},
          Map.put(lease.metadata, :reason, reason),
          lease.upstream_instance_id
        )

        {:reply, :ok, state}
    end
  end

  def handle_call({:transfer, token, owner}, _from, state) do
    case Map.fetch(state.leases, token) do
      :error ->
        {:reply, {:error, :unknown_lease}, state}

      {:ok, lease} ->
        state = release_request_count(state, lease)
        Process.demonitor(lease.monitor, [:flush])
        monitor = Process.monitor(owner)

        retained = %{lease | count_active?: false, monitor: monitor}

        {:reply, :ok,
         %{
           state
           | leases: Map.put(state.leases, token, retained),
             monitors: state.monitors |> Map.delete(lease.monitor) |> Map.put(monitor, token)
         }}
    end
  end

  def handle_call({:release, token, reason}, _from, state) do
    {:reply, :ok, release_token(state, token, reason)}
  end

  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       leases: map_size(state.leases),
       retained_responses:
         Enum.count(state.leases, fn {_token, lease} -> not lease.count_active? end)
     }, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _owner, _reason}, state) do
    case Map.fetch(state.monitors, monitor) do
      {:ok, token} -> {:noreply, release_token(state, token, :owner_down)}
      :error -> {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.leases, fn {_token, lease} ->
      if lease.count_active?,
        do: UpstreamAdmission.release_count(state.counters, @node_inflight, 1)

      if lease.charged_bytes > 0,
        do: UpstreamAdmission.release_count(state.counters, @response_bytes, lease.charged_bytes)

      UpstreamAdmission.increment(state.counters, @reclaimed)
    end)

    unless state.dirty_restart? do
      :atomics.put(state.recovery_markers, state.partition + 1, 0)
    end

    :ok
  end

  defp release_token(state, token, reason) do
    case Map.pop(state.leases, token) do
      {nil, _leases} ->
        state

      {lease, leases} ->
        Process.demonitor(lease.monitor, [:flush])
        state = release_request_count(state, lease)

        if lease.charged_bytes > 0,
          do:
            UpstreamAdmission.release_count(state.counters, @response_bytes, lease.charged_bytes)

        stat = if reason == :owner_down, do: @reclaimed, else: @released
        UpstreamAdmission.increment(state.counters, stat)

        emit(
          :released,
          %{bytes: lease.logical_bytes, count: 1},
          lease.metadata
          |> Map.put(:reason, reason)
          |> Map.put(:retained?, not lease.count_active?),
          lease.upstream_instance_id
        )

        %{
          state
          | leases: leases,
            monitors: Map.delete(state.monitors, lease.monitor)
        }
    end
  end

  defp release_request_count(state, %{count_active?: false}), do: state

  defp release_request_count(state, lease) do
    UpstreamAdmission.release_count(state.counters, @node_inflight, 1)

    upstream_counts =
      case Map.get(state.upstream_counts, lease.capacity_key, 0) do
        count when count <= 1 -> Map.delete(state.upstream_counts, lease.capacity_key)
        count -> Map.put(state.upstream_counts, lease.capacity_key, count - 1)
      end

    %{state | upstream_counts: upstream_counts}
  end

  defp emit(event, measurements, metadata, upstream_instance_id) do
    :telemetry.execute(
      [:lasso, :upstream_admission, event],
      measurements,
      Map.put(metadata, :upstream_instance_id, upstream_instance_id)
    )
  end
end
