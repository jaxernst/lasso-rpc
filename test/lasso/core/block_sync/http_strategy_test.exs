defmodule Lasso.BlockSync.Strategies.HttpStrategyTest do
  use ExUnit.Case, async: false

  alias Lasso.BlockSync.Strategies.HttpStrategy
  alias Lasso.BlockSync.Worker
  alias Lasso.Observations.HeadObservation
  alias Lasso.RPC.Response

  setup do
    Application.ensure_all_started(:lasso)
    instance_id = "http-owner-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      :ets.delete(:lasso_instance_state, {:health_block_sync, instance_id})
    end)

    {:ok, instance_id: instance_id}
  end

  test "canonical passthrough responses decode into block heights" do
    response = %Response.Success{
      id: "block-sync-request",
      jsonrpc: "2.0",
      raw_bytes: ~s({"jsonrpc":"2.0","id":"block-sync-request","result":"0x188fc2e"})
    }

    assert {:ok, 0x188FC2E} = HttpStrategy.decode_poll_response(response)
  end

  test "a round poll uses one unlinked owner and answers the round with its height", %{
    instance_id: instance_id
  } do
    test_pid = self()

    runner = fn plan ->
      send(test_pid, {:poll_started, self(), plan})

      receive do
        :release_poll -> {:ok, 42}
      end
    end

    {:ok, state} =
      HttpStrategy.start(1, instance_id,
        parent: self(),
        poll_interval_ms: 10_000,
        route_resolver: fn ^instance_id, 1 -> {:ok, "profile-b", "provider-b"} end,
        poll_runner: runner
      )

    round = make_ref()
    assert {:polling, state} = HttpStrategy.poll(state, {self(), round})
    assert_receive {:poll_started, owner_pid, plan}

    assert owner_pid == state.poll_owner_pid
    assert is_reference(state.poll_owner_ref)
    assert plan.profile == "profile-b"
    assert plan.provider_id == "provider-b"
    assert plan.caller_pid == self()
    assert plan.deadline_us - plan.started_at_us == 3_000_000
    refute owner_pid in elem(Process.info(self(), :links), 1)

    assert {:busy, unchanged} = HttpStrategy.poll(state)
    assert unchanged.poll_owner_pid == owner_pid

    state = HttpStrategy.set_poll_interval(state, 1_234)
    assert state.poll_interval_ms == 1_234
    assert state.poll_owner_pid == owner_pid

    earliest_observed_at_ms = System.system_time(:millisecond)
    send(owner_pid, :release_poll)

    assert_receive {:http_strategy, :poll_result, ^instance_id, owner_id, ^owner_pid,
                    %HttpStrategy.PollOutcome{
                      result: {:ok, 42},
                      completed_at_us: completed_at_us,
                      observed_at_ms: owner_observed_at_ms
                    } = outcome}

    assert owner_id == state.poll_owner_id
    assert completed_at_us >= plan.started_at_us
    assert owner_observed_at_ms >= earliest_observed_at_ms

    Process.sleep(30)

    assert {:ok, state} =
             HttpStrategy.handle_message(
               {:poll_result, owner_id, owner_pid, outcome},
               state
             )

    assert_receive {:head_observation,
                    %HeadObservation{
                      instance_id: ^instance_id,
                      height: 42,
                      latency_ms: latency_ms,
                      observed_at_ms: observed_at_ms
                    }}

    assert latency_ms >= 0
    assert observed_at_ms == owner_observed_at_ms
    assert latency_ms == max(div(completed_at_us - plan.started_at_us, 1_000), 0)
    assert state.last_poll_time == owner_observed_at_ms
    assert state.poll_owner_pid == nil
    assert_receive {:round_answer, ^round, ^instance_id, 1_234, {:ok, 42}}

    HttpStrategy.stop(state)
  end

  test "an owner crash is local and answers the round without a height", %{
    instance_id: instance_id
  } do
    test_pid = self()

    {:ok, state} =
      HttpStrategy.start(1, instance_id,
        parent: self(),
        poll_interval_ms: 10_000,
        route_resolver: fn ^instance_id, 1 -> {:ok, "profile-a", "provider-a"} end,
        poll_runner: fn _plan ->
          send(test_pid, {:poll_blocked, self()})
          receive do: (:never -> {:ok, 0})
        end
      )

    round = make_ref()
    assert {:polling, state} = HttpStrategy.poll(state, {self(), round})
    assert_receive {:poll_blocked, owner_pid}
    assert owner_pid == state.poll_owner_pid

    Process.exit(owner_pid, :kill)
    assert_receive {:DOWN, owner_ref, :process, ^owner_pid, :killed}
    assert owner_ref == state.poll_owner_ref

    assert {:ok, state} =
             HttpStrategy.handle_message(
               {:DOWN, owner_ref, :process, owner_pid, :killed},
               state
             )

    assert state.consecutive_failures == 1
    assert state.poll_owner_pid == nil
    assert_receive {:round_answer, ^round, ^instance_id, 10_000, :error}
    HttpStrategy.stop(state)
  end

  test "stopping the strategy terminates its disposable owner", %{instance_id: instance_id} do
    test_pid = self()

    {:ok, state} =
      HttpStrategy.start(1, instance_id,
        parent: self(),
        route_resolver: fn ^instance_id, 1 -> {:ok, "profile-a", "provider-a"} end,
        poll_runner: fn _plan ->
          send(test_pid, {:poll_blocked, self()})
          receive do: (:never -> {:ok, 0})
        end
      )

    assert {:polling, state} = HttpStrategy.poll(state)
    assert_receive {:poll_blocked, owner_pid}
    death_ref = Process.monitor(owner_pid)

    assert :ok = HttpStrategy.stop(state)
    assert_receive {:DOWN, ^death_ref, :process, ^owner_pid, :killed}
  end

  test "the worker remains responsive while its sole poll owner is blocked", %{
    instance_id: instance_id
  } do
    test_pid = self()

    {:ok, strategy} =
      HttpStrategy.start(1, instance_id,
        parent: self(),
        route_resolver: fn ^instance_id, 1 -> {:ok, "profile", "provider"} end,
        poll_runner: fn _plan ->
          send(test_pid, {:poll_blocked, self()})
          receive do: (:release -> {:ok, 1})
        end
      )

    worker = %Worker{
      chain_id: 1,
      instance_id: instance_id,
      mode: :http_only,
      http_strategy: strategy,
      ws_strategy: nil,
      config: %{},
      auth_scope: :system
    }

    assert {:noreply, worker} =
             Worker.handle_info({:block_sync_round, self(), make_ref(), 0}, worker)

    assert_receive {:poll_blocked, owner_pid}

    assert {:reply, {:ok, status}, ^worker} =
             Worker.handle_call(:get_status, {self(), make_ref()}, worker)

    assert status.http_status.poll_inflight
    assert worker.http_strategy.poll_owner_pid == owner_pid
    refute owner_pid in elem(Process.info(self(), :links), 1)

    round = make_ref()

    assert {:noreply, ^worker} =
             Worker.handle_info({:block_sync_round, self(), round, 0}, worker)

    assert_receive {:round_answer, ^round, ^instance_id, _interval_ms, :skipped}

    send(owner_pid, :release)
    HttpStrategy.stop(worker.http_strategy)
  end

  test "route changes apply to the next poll without mutating the active plan", %{
    instance_id: instance_id
  } do
    test_pid = self()
    Process.put(:route_version, 0)

    resolver = fn ^instance_id, 1 ->
      version = Process.get(:route_version, 0) + 1
      Process.put(:route_version, version)
      {:ok, "profile-#{version}", "provider-#{version}"}
    end

    runner = fn plan ->
      send(test_pid, {:captured_plan, self(), plan})
      receive do: (:release -> {:ok, 1})
    end

    {:ok, state} =
      HttpStrategy.start(1, instance_id,
        parent: self(),
        poll_interval_ms: 10_000,
        route_resolver: resolver,
        poll_runner: runner
      )

    assert {:polling, state} = HttpStrategy.poll(state)
    assert_receive {:captured_plan, first_owner, first_plan}
    assert {first_plan.profile, first_plan.provider_id} == {"profile-1", "provider-1"}

    send(first_owner, :release)

    assert_receive {:http_strategy, :poll_result, ^instance_id, first_owner_id, ^first_owner,
                    %HttpStrategy.PollOutcome{result: {:ok, 1}} = outcome}

    assert {:ok, state} =
             HttpStrategy.handle_message(
               {:poll_result, first_owner_id, first_owner, outcome},
               state
             )

    assert {:polling, state} = HttpStrategy.poll(state)
    assert_receive {:captured_plan, second_owner, second_plan}

    assert {second_plan.profile, second_plan.provider_id} == {"profile-2", "provider-2"}
    assert {first_plan.profile, first_plan.provider_id} == {"profile-1", "provider-1"}

    HttpStrategy.stop(state)
    refute Process.alive?(second_owner)
  end
end
