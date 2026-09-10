defmodule Lasso.BlockPublication.Runtime do
  @moduledoc """
  Background journal reconciliation and regional preparation. PubSub carries
  invalidations; only the durable journal can authorize a serving grant.
  """
  use GenServer
  require Logger
  alias Lasso.BlockPublication.{Block, Gate, Probe}
  alias Lasso.Config.ConfigStore
  alias Lasso.RPC.HeadPolicy

  @topic "block_publications"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec configured?() :: boolean()
  def configured?,
    do: Application.get_env(:lasso, :block_publication, [])[:members] not in [nil, []]

  @spec quiesce(pos_integer()) :: :ok | {:error, term()}
  def quiesce(timeout \\ 30_000) when is_integer(timeout) and timeout > 0 do
    Gate.retire()
    deadline = System.monotonic_time(:millisecond) + timeout
    GenServer.call(__MODULE__, {:quiesce, deadline}, timeout + 1_000)
  end

  @impl true
  def init(opts) do
    config = Keyword.merge(Application.get_env(:lasso, :block_publication, []), opts)
    members = Keyword.get(config, :members, [])

    state = %{
      members: members,
      member: Lasso.Cluster.Topology.self_node_id(),
      journal: Keyword.get(config, :journal),
      probe: Keyword.get(config, :probe, Probe),
      interval: Keyword.get(config, :interval_ms, 1_000),
      tasks: %{},
      closure_tasks: %{},
      snapshots: %{},
      timer: nil,
      next_probe: %{},
      retired: Gate.retired?(),
      urgent: false
    }

    if members == [] and is_nil(state.journal) do
      Gate.bootstrapped()
      {:ok, state}
    else
      unless is_atom(state.journal) and not is_nil(state.journal),
        do: raise(ArgumentError, "block publication requires a durable journal adapter")

      Phoenix.PubSub.subscribe(Lasso.PubSub, @topic)
      send(self(), :reconcile)
      {:ok, state}
    end
  end

  @impl true
  def handle_call({:quiesce, deadline}, _from, state) when is_integer(deadline) do
    Gate.retire()

    Enum.each(Map.merge(state.tasks, state.closure_tasks), fn {ref, _} ->
      Process.demonitor(ref, [:flush])
    end)

    state = %{state | retired: true}

    result = fence_before_deadline(state, deadline)

    {:reply, result, state}
  end

  defp fence_before_deadline(%{journal: nil}, _deadline), do: :ok

  # Elixir 1.18/OTP 28 infers the supervisor's task reference as a plain reference
  # instead of the opaque Task.ref() accepted by Task.yield/2.
  @dialyzer {:no_opaque, fence_before_deadline: 2}
  defp fence_before_deadline(state, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining == 0 do
      {:error, :shutdown_timeout}
    else
      task =
        Task.Supervisor.async_nolink(Lasso.TaskSupervisor, fn -> fence_serving_boots(state) end)

      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      case Task.yield(task, remaining) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        {:exit, _} -> {:error, :journal_unavailable}
        nil -> {:error, :shutdown_timeout}
      end
    end
  end

  defp fence_serving_boots(state) do
    for {key, publication} <- state.snapshots,
        publication["members"][state.member] == Gate.boot(),
        do: fence_boot(state, key)

    # Retry failed snapshot fences and discover bindings after a worker restart.
    with {:ok, publications} <- state.journal.list() do
      publications =
        Enum.sort_by(publications, fn {_, publication} -> publication["phase"] == "disabled" end)

      results =
        for {key, p} <- publications,
            p["members"][state.member] == Gate.boot(),
            do: fence_boot(state, key)

      if Enum.all?(results, &match?({:ok, _}, &1)),
        do: :ok,
        else: {:error, :journal_unavailable}
    end
  end

  defp fence_boot(state, key) do
    state.journal.command(
      key,
      {:fence, state.member, Gate.boot(), "Runtime permanently closed its serving gate"}
    )
  end

  @impl true
  def handle_info(:reconcile, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    state = reconcile(state)

    {:noreply,
     %{state | timer: Process.send_after(self(), :reconcile, state.interval), urgent: false}}
  end

  def handle_info(:publication_changed, state) do
    # Coalesce bursts of journal updates into one local reconciliation.
    if state.urgent do
      {:noreply, state}
    else
      if state.timer, do: Process.cancel_timer(state.timer)
      {:noreply, %{state | timer: Process.send_after(self(), :reconcile, 10), urgent: true}}
    end
  end

  def handle_info({ref, {key, result}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    state = finish_task(state, ref)

    state =
      case result do
        {:ok, publication} ->
          install(state, key, publication)

        {:error, :stale_revision} ->
          send(self(), :publication_changed)
          state

        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, state) do
    if reason != :normal,
      do: Logger.warning("Block publication background task failed: #{inspect(reason)}")

    {:noreply, finish_task(state, ref)}
  end

  defp reconcile(state) do
    ensure_configured_scopes(state)

    revisions =
      Map.new(state.snapshots, fn {key, publication} -> {key, publication["revision"]} end)

    case state.journal.changes(revisions) do
      {:ok, publications} ->
        state =
          Enum.reduce(publications, state, fn {key, publication}, acc ->
            install(acc, key, publication)
          end)

        state =
          state.snapshots
          |> Enum.sort_by(fn {key, _} ->
            case Map.fetch(state.next_probe, key) do
              :error -> {0, 0, key}
              {:ok, next_probe} -> {1, next_probe, key}
            end
          end)
          |> Enum.reduce(state, fn {key, publication}, acc ->
            progress(acc, key, publication)
          end)

        Gate.bootstrapped()
        state

      {:error, _} ->
        state
    end
  end

  defp ensure_configured_scopes(state) do
    for profile <- ConfigStore.list_profiles(),
        state.members != [],
        chain_id <- ConfigStore.list_chains_for_profile(profile),
        {:ok, %{head_policy: "global"} = chain} <- [ConfigStore.get_chain(profile, chain_id)],
        not Gate.managed?({profile, chain_id}) do
      state.journal.ensure({profile, chain_id}, state.members, max_age(chain.block_time_ms))
    end
  end

  defp install(state, key, publication) do
    if publication["revision"] < Gate.revision(key) do
      state
    else
      Gate.install(key, publication, state.member)

      if publication["phase"] == "disabled" do
        HeadPolicy.release_local(key, publication["published"])

        %{
          state
          | snapshots: Map.delete(state.snapshots, key),
            next_probe: Map.delete(state.next_probe, key)
        }
      else
        %{state | snapshots: Map.put(state.snapshots, key, publication)}
      end
    end
  end

  defp progress(state, key, publication) do
    boot = Gate.boot()
    member = state.member
    worker = %{journal: state.journal, probe: state.probe}

    cond do
      state.retired ->
        state

      publication["phase"] == "disabled" ->
        state

      not Map.has_key?(publication["members"], member) ->
        state

      publication["members"][member] == nil ->
        floor = HeadPolicy.fence_local(key)
        command(state, key, {:join, member, boot, floor})

      publication["members"][member] != boot ->
        state

      publication["phase"] in ["closing", "disabling"] and publication["closed"][member] != boot ->
        # install/3 has synchronously closed the gate before this durable ACK.
        acknowledge_closure(state, key, {:closed, publication["epoch"], member, boot})

      map_size(state.tasks) >= 4 or key in Map.values(state.tasks) ->
        state

      Map.get(state.next_probe, key, System.monotonic_time(:millisecond)) >
          System.monotonic_time(:millisecond) ->
        state

      publication["phase"] == "preparing" ->
        floor = HeadPolicy.fence_local(key)

        task(state, key, fn ->
          candidate = publication["candidate"]

          if Block.fresh?(
               candidate["timestamp_ms"],
               System.system_time(:millisecond),
               publication["max_age_ms"]
             ) == :ok do
            with {:ok, evidence} <-
                   worker.probe.prepare(
                     key,
                     candidate,
                     publication["published"],
                     publication["max_age_ms"]
                   ) do
              evidence = Map.put(evidence, "minimum_height", floor || 0)
              publish_command(worker, key, {:ready, publication["epoch"], member, boot, evidence})
            end
          else
            publish_command(worker, key, {:abort, publication["epoch"]})
          end
        end)

      publication["phase"] == "active" ->
        task(state, key, fn ->
          candidate =
            if not is_nil(publication["published"]) and
                 publication["active_members"] != publication["members"] and
                 publication["published"]["height"] >= publication["minimum_height"] and
                 Block.fresh?(
                   publication["published"]["timestamp_ms"],
                   System.system_time(:millisecond),
                   publication["max_age_ms"]
                 ) == :ok,
               do: {:ok, publication["published"], nil},
               else: worker.probe.latest(key, publication["max_age_ms"])

          with {:ok, block, _} <- candidate do
            publish_command(worker, key, {:propose, member, boot, block})
          end
        end)

      true ->
        state
    end
  end

  # Closure writes have independent slots so provider probes cannot delay the barrier.
  defp acknowledge_closure(state, key, command) do
    if map_size(state.closure_tasks) >= 4 or key in Map.values(state.closure_tasks) do
      state
    else
      journal = state.journal
      snapshot = Map.fetch!(state.snapshots, key)

      task =
        Task.Supervisor.async_nolink(Lasso.TaskSupervisor, fn ->
          {key, apply_command(journal, key, snapshot, command)}
        end)

      %{state | closure_tasks: Map.put(state.closure_tasks, task.ref, key)}
    end
  end

  defp finish_task(state, ref) do
    %{
      state
      | tasks: Map.delete(state.tasks, ref),
        closure_tasks: Map.delete(state.closure_tasks, ref)
    }
  end

  defp command(state, key, cmd) do
    case apply_command(state.journal, key, Map.fetch!(state.snapshots, key), cmd) do
      {:ok, publication} ->
        install(state, key, publication)

      {:error, :stale_revision} ->
        send(self(), :publication_changed)
        state

      _ ->
        state
    end
  end

  defp apply_command(journal, key, snapshot, command) do
    result =
      if function_exported?(journal, :compare_and_apply, 3),
        do: journal.compare_and_apply(key, snapshot, command),
        else: journal.command(key, command)

    if match?({:ok, _}, result),
      do: Phoenix.PubSub.broadcast(Lasso.PubSub, @topic, :publication_changed)

    result
  end

  defp publish_command(state, key, cmd) do
    result = state.journal.command(key, cmd)

    if match?({:ok, _}, result),
      do: Phoenix.PubSub.broadcast(Lasso.PubSub, @topic, :publication_changed)

    result
  end

  defp task(state, key, fun) do
    task = Task.Supervisor.async_nolink(Lasso.TaskSupervisor, fn -> {key, fun.()} end)

    %{
      state
      | tasks: Map.put(state.tasks, task.ref, key),
        next_probe:
          Map.put(state.next_probe, key, System.monotonic_time(:millisecond) + state.interval)
    }
  end

  @spec max_age(term()) :: pos_integer()
  def max_age(block_time) when is_integer(block_time) and block_time > 0,
    do: max(60_000, 4 * block_time)

  def max_age(_), do: 60_000
end
