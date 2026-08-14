defmodule Lasso.RPC.Transport.WebSocket.TransportProtocolTest do
  use ExUnit.Case, async: false

  alias Lasso.Core.Request.RequestOwner
  alias Lasso.Core.Support.{CircuitBreaker, ErrorClassifier}
  alias Lasso.Core.Support.CircuitBreaker.{ControlRing, Snapshot}
  alias Lasso.Core.Transport.AttemptProtocol
  alias Lasso.Core.Transport.UpstreamResponse
  alias Lasso.Core.Transport.UpstreamResponse.Validated
  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.Providers.InstanceState
  alias Lasso.RPC.{AttemptIdentity, AttemptTerminal, PreparedRequest, Response}
  alias Lasso.RPC.Transport.WebSocket.{Connection, Endpoint, Handler}
  alias Lasso.RPC.Transports.WebSocket

  @config_keys [
    :protocol_ws_send_mode,
    :protocol_ws_test_owner,
    :ws_client_module,
    :ws_send_cleanup_ms,
    :ws_startup_jitter_ms,
    :ws_transport_pending_limit
  ]

  setup context do
    saved_config = Map.new(@config_keys, &{&1, Application.fetch_env(:lasso, &1)})

    Application.put_env(:lasso, :protocol_ws_send_mode, context[:send_mode] || :manual)
    Application.put_env(:lasso, :protocol_ws_test_owner, self())
    Application.put_env(:lasso, :ws_client_module, TestSupport.ProtocolWSClient)
    Application.put_env(:lasso, :ws_send_cleanup_ms, context[:send_cleanup_ms] || 10_000)
    Application.put_env(:lasso, :ws_startup_jitter_ms, 0)
    Application.put_env(:lasso, :ws_transport_pending_limit, context[:pending_limit] || 256)

    suffix = System.unique_integer([:positive, :monotonic])

    endpoint = %Endpoint{
      profile: "public",
      id: "protocol-ws-#{suffix}",
      name: "Protocol WebSocket #{suffix}",
      chain_id: suffix,
      chain_name: "protocol-ws-chain-#{suffix}",
      ws_url: "ws://protocol.test/#{suffix}",
      reconnect_interval: 1,
      heartbeat_interval: 60_000,
      max_reconnect_attempts: 3,
      stability_ms: 60_000
    }

    instance_id = "#{endpoint.chain_id}:#{endpoint.id}"
    breaker_id = {instance_id, :ws}

    {:ok, breaker_pid} =
      CircuitBreaker.start_link(
        {breaker_id, %{failure_threshold: 5, recovery_timeout: 200, success_threshold: 1}}
      )

    {:ok, connection_pid} = Connection.start_link(endpoint)

    assert_receive {:protocol_ws_connected, ws_pid, generation}
    assert eventually(fn -> Connection.status(instance_id).connected end)

    on_exit(fn ->
      stop_if_alive(connection_pid)
      stop_if_alive(breaker_pid)
      InstanceState.clear(instance_id)

      Enum.each(saved_config, fn
        {key, {:ok, value}} -> Application.put_env(:lasso, key, value)
        {key, :error} -> Application.delete_env(:lasso, key)
      end)
    end)

    channel = %{instance_id: instance_id, provider_id: endpoint.id}

    %{
      channel: channel,
      breaker_pid: breaker_pid,
      connection_pid: connection_pid,
      generation: generation,
      instance_id: instance_id,
      ws_pid: ws_pid
    }
  end

  @tag send_mode: :auto_success
  test "registers before an immediate response and replaces duplicate client ids", context do
    first = request_task(context.channel, "duplicate-client-id", 1_000)
    second = request_task(context.channel, "duplicate-client-id", 1_000)

    assert_receive {:protocol_ws_send, ws_pid, first_id, _payload}
    assert_receive {:protocol_ws_send, ^ws_pid, second_id, _payload}

    assert first_id != second_id
    assert String.starts_with?(first_id, "lasso-")
    assert String.starts_with?(second_id, "lasso-")

    assert {:ok, %Response.Success{id: "duplicate-client-id"}, _io_ms} = Task.await(first)
    assert {:ok, %Response.Success{id: "duplicate-client-id"}, _io_ms} = Task.await(second)

    assert %{pending_requests: 0, transport_pending_requests: 0} =
             Connection.status(context.instance_id)
  end

  @tag send_mode: :auto_success
  test "prepared request sends the existing bytes and restores an explicit null id", context do
    request = %{"jsonrpc" => "2.0", "id" => nil, "method" => "eth_blockNumber", "params" => []}
    assert {:ok, prepared} = PreparedRequest.new(request, "lasso-ws-prepared")

    task = Task.async(fn -> WebSocket.request_prepared(context.channel, prepared, 1_000) end)

    assert_receive {:protocol_ws_send, _ws_pid, "lasso-ws-prepared", payload}
    assert payload === prepared.encoded

    assert {:ok, %Response.Success{id: nil}, _io_ms} = Task.await(task)
  end

  @tag pending_limit: 1
  test "rejects pending-cap saturation before send while a send is blocked", context do
    first = request_task(context.channel, 1, 1_000)
    assert_receive {:protocol_ws_send, ws_pid, transport_id, _payload}

    assert %{connected: true, transport_pending_requests: 1, transport_pending_limit: 1} =
             Connection.status(context.instance_id)

    assert {:error, %JError{category: :local_capacity_rejection, data: %{reason: :capacity}},
            _io_ms} = WebSocket.request(context.channel, rpc_request(2), 1_000)

    refute_receive {:protocol_ws_send, ^ws_pid, _id, _payload}, 0
    assert Connection.status(context.instance_id).connected

    :ok =
      TestSupport.ProtocolWSClient.acknowledge(
        ws_pid,
        transport_id,
        success_response(transport_id, "0x1")
      )

    assert {:ok, %Response.Success{id: 1}, _io_ms} = Task.await(first)
    assert Connection.status(context.instance_id).transport_pending_requests == 0
  end

  test "post-write acknowledgement proves dispatch before the response", context do
    {task, attempt_ref} = observed_request_task(context.channel)

    assert_receive {:protocol_ws_send, ws_pid, transport_id, _payload}
    assert_observation(attempt_ref, :send_started)
    assert %{event_us: confirmed_at_us} = assert_observation(attempt_ref, :send_confirmed)
    assert is_integer(confirmed_at_us)

    :ok =
      TestSupport.ProtocolWSClient.acknowledge(
        ws_pid,
        transport_id,
        success_response(transport_id, "0x1")
      )

    assert_observation(attempt_ref, :response)
    assert {:ok, %Response.Success{id: "observed"}, _io_ms} = Task.await(task)
  end

  test "request ownership projects production WebSocket errors into canonical classes", context do
    cases = [
      {-32_602, "invalid params", :deterministic, :return_response, :none},
      {-32_005, "rate limited", :quota, :try_next_candidate, :none},
      {-32_601, "method not found", :capability, :try_next_candidate, :none},
      {-32_002, "provider unavailable", :provider_failure, :try_next_candidate, :failure}
    ]

    for {code, message, category, action, breaker_effect} <- cases do
      client_id = "owner-error-#{code}"

      task =
        Task.async(fn ->
          RequestOwner.execute(
            ws_attempt_identity(context, client_id),
            System.monotonic_time(:microsecond) + 1_000_000,
            fn -> WebSocket.request(context.channel, rpc_request(client_id), 1_000) end
          )
        end)

      assert_receive {:protocol_ws_send, ws_pid, transport_id, _payload}

      raw =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => transport_id,
          "error" => %{"code" => code, "message" => message}
        })

      :ok = TestSupport.ProtocolWSClient.acknowledge(ws_pid, transport_id, raw)
      outcome = Task.await(task, 1_000)

      assert %AttemptTerminal.Response{
               kind: :application_error,
               error_category: ^category
             } = outcome.fact

      assert outcome.projection.recommended_action == action
      assert outcome.projection.breaker_effect == breaker_effect
    end
  end

  test "a timeout after the post-write acknowledgement remains dispatched", context do
    {task, attempt_ref} = observed_request_task(context.channel, 100)

    assert_receive {:protocol_ws_send, _ws_pid, _transport_id, _payload}
    assert_observation(attempt_ref, :send_started)
    assert_observation(attempt_ref, :send_confirmed)

    assert %{certainty: :dispatched} =
             assert_observation(attempt_ref, :transport_failure)

    assert {:error, %JError{category: :timeout}, _io_ms} = Task.await(task, 1_000)
  end

  test "does not register or send at or after the absolute deadline", context do
    {:ok, snapshot = {_ws_pid, generation}} =
      Connection.transport_snapshot(context.instance_id, 1_000)

    deadline = System.monotonic_time(:microsecond)

    for {suffix, candidate_deadline} <- [
          {"at-deadline", deadline},
          {"after-deadline", deadline - 1}
        ] do
      assert {:error, :deadline} =
               Connection.register_transport(
                 context.instance_id,
                 snapshot,
                 transport_id(generation, suffix),
                 self(),
                 candidate_deadline,
                 1_000
               )
    end

    assert Connection.status(context.instance_id).transport_pending_requests == 0
    refute_receive {:protocol_ws_send, _ws_pid, _id, _payload}, 0
  end

  @tag pending_limit: 1
  test "an expired queued frame stays bounded and never sends after handler resume", context do
    :sys.suspend(context.ws_pid)
    on_exit(fn -> resume_if_alive(context.ws_pid) end)

    {task, attempt_ref} = observed_request_task(context.channel)

    assert eventually(fn ->
             state = :sys.get_state(context.connection_pid)

             match?(
               [{_id, %{send_state: :queued}}],
               Map.to_list(state.transport_pending)
             )
           end)

    assert_observation(attempt_ref, :send_started)
    assert {:message_queue_len, queued} = Process.info(context.ws_pid, :message_queue_len)
    assert queued <= 1

    {transport_id, pending} = only_transport_pending(context.connection_pid)
    expire_transport(context.connection_pid, transport_id, pending)

    assert {:error, %JError{category: :timeout}, _io_ms} = Task.await(task)

    assert %{transport_pending_requests: 1, transport_tombstones: 1} =
             Connection.status(context.instance_id)

    send(
      context.connection_pid,
      {:transport_timeout, transport_id, pending.generation, pending.token}
    )

    assert %{connected: true, transport_tombstones: 1} =
             Connection.status(context.instance_id)

    assert {:error, %JError{category: :local_capacity_rejection}, _io_ms} =
             WebSocket.request(context.channel, rpc_request("capacity"), 100)

    :sys.resume(context.ws_pid)
    refute_receive {:protocol_ws_send, _ws_pid, _id, _payload}, 0

    assert eventually(fn ->
             Connection.status(context.instance_id).transport_pending_requests == 0
           end)
  end

  @tag send_mode: :pause_before_write
  test "timeout retains an accepted send until its post-write acknowledgement", context do
    {task, attempt_ref} = observed_request_task(context.channel, 100)

    assert_receive {:protocol_ws_accepted_before_write, ws_pid, transport_id, _payload}
    assert_observation(attempt_ref, :send_started)

    assert eventually(fn ->
             match?(
               %{send_state: :accepted},
               transport_pending(context.connection_pid, transport_id)
             )
           end)

    assert {:error, %JError{category: :timeout}, _io_ms} = Task.await(task, 1_000)

    assert %{transport_pending_requests: 1, transport_tombstones: 1} =
             Connection.status(context.instance_id)

    refute_receive {:protocol_ws_send, ^ws_pid, ^transport_id, _payload}, 0
    send(ws_pid, :resume_protocol_ws_write)
    assert_receive {:protocol_ws_send, ^ws_pid, ^transport_id, _payload}

    assert eventually(fn ->
             Connection.status(context.instance_id).transport_pending_requests == 0
           end)

    refute_confirmed(attempt_ref)
  end

  @tag send_mode: :pause_before_write
  @tag pending_limit: 1
  test "owner death after acceptance kills the exact generation at cleanup expiry", context do
    task = request_task(context.channel, "accepted-owner-death", 5_000)

    assert_receive {:protocol_ws_accepted_before_write, ws_pid, transport_id, _payload}

    assert eventually(fn ->
             match?(
               %{send_state: :accepted},
               transport_pending(context.connection_pid, transport_id)
             )
           end)

    Process.unlink(task.pid)
    task_monitor = Process.monitor(task.pid)
    Process.exit(task.pid, :kill)
    assert_receive {:DOWN, ^task_monitor, :process, _pid, :killed}

    assert eventually(fn ->
             match?(
               %{transport_pending_requests: 1, transport_tombstones: 1},
               Connection.status(context.instance_id)
             )
           end)

    pending = transport_pending(context.connection_pid, transport_id)
    cleanup_expiry_us = expire_send_cleanup(context.connection_pid, transport_id, pending)
    ws_monitor = Process.monitor(ws_pid)

    send(
      context.connection_pid,
      {:send_cleanup_expired, pending.connection, pending.generation, {:transport, transport_id},
       pending.token, cleanup_expiry_us}
    )

    assert_receive {:DOWN, ^ws_monitor, :process, ^ws_pid, :killed}
    refute_receive {:protocol_ws_send, ^ws_pid, ^transport_id, _payload}, 0

    assert_receive {:protocol_ws_connected, new_ws_pid, new_generation}
    assert new_ws_pid != ws_pid
    assert new_generation != context.generation

    assert eventually(fn ->
             Connection.status(context.instance_id).transport_pending_requests == 0
           end)
  end

  test "does not send when the request owner is already down", context do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    owner_monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}

    task =
      Task.async(fn ->
        attempt_context =
          AttemptProtocol.new_context(
            owner,
            make_ref(),
            System.monotonic_time(:microsecond) + 1_000_000
          )

        :ok = AttemptProtocol.install_context(attempt_context)
        WebSocket.request(context.channel, rpc_request("owner-down"), 1_000)
      end)

    assert {:error, %JError{category: :cancelled, breaker_penalty?: false}, _io_ms} =
             Task.await(task)

    refute_receive {:protocol_ws_send, _ws_pid, _id, _payload}, 0

    assert eventually(fn ->
             Connection.status(context.instance_id).transport_pending_requests == 0
           end)
  end

  test "uses tokenized timers and preserves a response stamped before the deadline", context do
    {:ok, snapshot = {ws_pid, generation}} =
      Connection.transport_snapshot(context.instance_id, 1_000)

    before_deadline_id = transport_id(generation, "d-minus-one")
    initial_deadline = System.monotonic_time(:microsecond) + 5_000_000

    assert {:ok, before_token} =
             Connection.register_transport(
               context.instance_id,
               snapshot,
               before_deadline_id,
               self(),
               initial_deadline,
               1_000
             )

    send(
      context.connection_pid,
      {:transport_timeout, before_deadline_id, generation, before_token}
    )

    assert Connection.status(context.instance_id).transport_pending_requests == 1

    before_deadline = replace_deadline(context.connection_pid, before_deadline_id)
    raw = success_response(before_deadline_id, "0x1")

    :sys.suspend(context.connection_pid)

    send(
      context.connection_pid,
      {:transport_timeout, before_deadline_id, generation, before_token}
    )

    send_parsed_frame(
      context.connection_pid,
      ws_pid,
      generation,
      raw,
      before_deadline - 1,
      before_deadline - 1
    )

    :sys.resume(context.connection_pid)

    assert_receive {:ws_transport_response, ^before_token, ^generation, ^ws_pid,
                    {:ok, %Validated{id: ^before_deadline_id}}, ^raw, received_at, validated_at}

    assert received_at == before_deadline - 1
    assert validated_at == before_deadline - 1
    assert Connection.status(context.instance_id).transport_pending_requests == 0

    at_deadline_id = transport_id(generation, "at-deadline")

    assert {:ok, at_token} =
             Connection.register_transport(
               context.instance_id,
               snapshot,
               at_deadline_id,
               self(),
               initial_deadline,
               1_000
             )

    at_deadline = replace_deadline(context.connection_pid, at_deadline_id)
    at_raw = success_response(at_deadline_id, "0x2")

    :sys.suspend(context.connection_pid)

    send(context.connection_pid, {:transport_timeout, at_deadline_id, generation, at_token})

    send_parsed_frame(
      context.connection_pid,
      ws_pid,
      generation,
      at_raw,
      at_deadline,
      at_deadline
    )

    :sys.resume(context.connection_pid)

    assert_receive {:ws_transport_timeout, ^at_token, ^generation}

    refute_receive {:ws_transport_response, ^at_token, ^generation, _pid, _validation, _raw,
                    _received, _validated},
                   0

    status = Connection.status(context.instance_id)
    assert status.transport_pending_requests == 0
    assert status.transport_diagnostics.late_or_uncorrelated_response == 1

    after_deadline_id = transport_id(generation, "after-deadline")

    assert {:ok, after_token} =
             Connection.register_transport(
               context.instance_id,
               snapshot,
               after_deadline_id,
               self(),
               initial_deadline,
               1_000
             )

    after_deadline = replace_deadline(context.connection_pid, after_deadline_id)
    after_raw = success_response(after_deadline_id, "0x3")

    :sys.suspend(context.connection_pid)

    send(
      context.connection_pid,
      {:transport_timeout, after_deadline_id, generation, after_token}
    )

    send_parsed_frame(
      context.connection_pid,
      ws_pid,
      generation,
      after_raw,
      after_deadline + 1,
      after_deadline + 1
    )

    :sys.resume(context.connection_pid)

    assert_receive {:ws_transport_timeout, ^after_token, ^generation}

    refute_receive {:ws_transport_response, ^after_token, ^generation, _pid, _validation, _raw,
                    _received, _validated},
                   0

    status = Connection.status(context.instance_id)
    assert status.transport_pending_requests == 0
    assert status.transport_diagnostics.late_or_uncorrelated_response == 2
  end

  test "deadline drain accepts only an already-observed D-1 frame", context do
    {:ok, snapshot = {ws_pid, generation}} =
      Connection.transport_snapshot(context.instance_id, 1_000)

    for iteration <- 1..10,
        {label, offset, expected} <- [
          {:d_minus_one, -1, :response},
          {:d, 0, :timeout},
          {:d_plus_one, 1, :timeout}
        ] do
      id = transport_id(generation, "#{label}-#{iteration}")
      initial_deadline = System.monotonic_time(:microsecond) + 5_000_000

      assert {:ok, token} =
               Connection.register_transport(
                 context.instance_id,
                 snapshot,
                 id,
                 self(),
                 initial_deadline,
                 1_000
               )

      deadline_us = System.monotonic_time(:microsecond) - 1_000
      force_transport_deadline(context.connection_pid, id, deadline_us)

      raw = success_response(id, "0x1")
      validated_at_us = deadline_us + offset

      :sys.suspend(context.connection_pid)

      send(
        context.connection_pid,
        {:transport_timeout, id, generation, token}
      )

      send_parsed_frame(
        context.connection_pid,
        ws_pid,
        generation,
        raw,
        validated_at_us,
        validated_at_us
      )

      :sys.resume(context.connection_pid)

      case expected do
        :response ->
          assert_receive {:ws_transport_response, ^token, ^generation, ^ws_pid,
                          {:ok, %Validated{id: ^id}}, ^raw, ^validated_at_us, ^validated_at_us}

          refute_receive {:ws_transport_timeout, ^token, ^generation}, 0

        :timeout ->
          assert_receive {:ws_transport_timeout, ^token, ^generation}

          refute_receive {:ws_transport_response, ^token, ^generation, _pid, _validation, _raw,
                          _received, _validated},
                         0
      end

      assert Connection.status(context.instance_id).transport_pending_requests == 0
    end
  end

  test "a D-1 frame delivered after deadline closure remains late", context do
    {:ok, snapshot = {ws_pid, generation}} =
      Connection.transport_snapshot(context.instance_id, 1_000)

    id = transport_id(generation, "late-d-minus-one")
    initial_deadline = System.monotonic_time(:microsecond) + 5_000_000

    assert {:ok, token} =
             Connection.register_transport(
               context.instance_id,
               snapshot,
               id,
               self(),
               initial_deadline,
               1_000
             )

    deadline_us = System.monotonic_time(:microsecond) - 1_000
    force_transport_deadline(context.connection_pid, id, deadline_us)
    send(context.connection_pid, {:transport_timeout, id, generation, token})
    assert_receive {:ws_transport_timeout, ^token, ^generation}

    raw = success_response(id, "0x1")

    send_parsed_frame(
      context.connection_pid,
      ws_pid,
      generation,
      raw,
      deadline_us - 1,
      deadline_us - 1
    )

    refute_receive {:ws_transport_response, ^token, ^generation, _pid, _validation, _raw,
                    _received, _validated},
                   0

    assert eventually(fn ->
             diagnostics = Connection.status(context.instance_id).transport_diagnostics
             Map.get(diagnostics, :late_or_uncorrelated_response, 0) == 1
           end)
  end

  test "ABA-safe cancellation ignores stale timers and late responses", context do
    {:ok, snapshot = {ws_pid, generation}} =
      Connection.transport_snapshot(context.instance_id, 1_000)

    id = transport_id(generation, "cancelled")
    deadline = System.monotonic_time(:microsecond) + 5_000_000

    assert {:ok, token} =
             Connection.register_transport(
               context.instance_id,
               snapshot,
               id,
               self(),
               deadline,
               1_000
             )

    Connection.cancel_transport(context.instance_id, id, generation, token)
    assert Connection.status(context.instance_id).transport_pending_requests == 0

    send(context.connection_pid, {:transport_timeout, id, generation, token})
    assert Connection.status(context.instance_id).transport_pending_requests == 0

    :ok = TestSupport.ProtocolWSClient.emit_raw(ws_pid, success_response(id, "late"))

    status = Connection.status(context.instance_id)
    assert status.transport_pending_requests == 0
    assert status.transport_diagnostics.late_or_uncorrelated_response == 1

    refute_receive {:ws_transport_response, ^token, ^generation, _pid, _validation, _raw,
                    _received, _validated},
                   0
  end

  test "rejects duplicate registrations and snapshots from an old generation", context do
    {:ok, snapshot = {ws_pid, generation}} =
      Connection.transport_snapshot(context.instance_id, 1_000)

    id = transport_id(generation, "duplicate-registration")
    deadline = System.monotonic_time(:microsecond) + 5_000_000

    assert {:ok, token} =
             Connection.register_transport(
               context.instance_id,
               snapshot,
               id,
               self(),
               deadline,
               1_000
             )

    assert {:error, :duplicate_transport_id} =
             Connection.register_transport(
               context.instance_id,
               snapshot,
               id,
               self(),
               deadline,
               1_000
             )

    Connection.cancel_transport(context.instance_id, id, generation, token)
    assert Connection.status(context.instance_id).transport_pending_requests == 0

    :ok = TestSupport.ProtocolWSClient.disconnect(ws_pid, :closed)
    assert_receive {:protocol_ws_connected, new_ws_pid, new_generation}
    assert new_ws_pid != ws_pid
    assert new_generation != generation

    assert eventually(fn ->
             match?(
               {:ok, {^new_ws_pid, ^new_generation}},
               Connection.transport_snapshot(context.instance_id, 1_000)
             )
           end)

    assert {:error, :stale_connection} =
             Connection.register_transport(
               context.instance_id,
               snapshot,
               transport_id(generation, "stale-snapshot"),
               self(),
               deadline,
               1_000
             )
  end

  test "owner death removes pending registration without waiting for its deadline", context do
    {:ok, snapshot = {_ws_pid, generation}} =
      Connection.transport_snapshot(context.instance_id, 1_000)

    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    id = transport_id(generation, "owner-death")
    deadline = System.monotonic_time(:microsecond) + 5_000_000

    assert {:ok, _token} =
             Connection.register_transport(
               context.instance_id,
               snapshot,
               id,
               owner,
               deadline,
               1_000
             )

    assert Connection.status(context.instance_id).transport_pending_requests == 1
    Process.exit(owner, :kill)

    assert eventually(fn ->
             Connection.status(context.instance_id).transport_pending_requests == 0
           end)
  end

  test "stale connection generations cannot complete a new pending attempt", context do
    {:ok, snapshot = {ws_pid, generation}} =
      Connection.transport_snapshot(context.instance_id, 1_000)

    id = transport_id(generation, "stale-generation")
    deadline = System.monotonic_time(:microsecond) + 5_000_000

    assert {:ok, token} =
             Connection.register_transport(
               context.instance_id,
               snapshot,
               id,
               self(),
               deadline,
               1_000
             )

    raw = success_response(id, "0x1")

    send_parsed_frame(
      context.connection_pid,
      self(),
      generation <> "-stale",
      raw,
      System.monotonic_time(:microsecond),
      System.monotonic_time(:microsecond)
    )

    status = Connection.status(context.instance_id)
    assert status.transport_pending_requests == 1
    assert status.transport_diagnostics.stale_generation == 1

    refute_receive {:ws_transport_response, ^token, ^generation, _pid, _validation, _raw,
                    _received, _validated},
                   0

    :ok = TestSupport.ProtocolWSClient.emit_raw(ws_pid, raw)

    assert_receive {:ws_transport_response, ^token, ^generation, ^ws_pid,
                    {:ok, %Validated{id: ^id}}, ^raw, _received_at, _validated_at}
  end

  test "only attributable invalid envelopes terminate a multiplexed attempt", context do
    task = request_task(context.channel, "client-id", 1_000)
    assert_receive {:protocol_ws_send, ws_pid, transport_id, _payload}

    :ok = TestSupport.ProtocolWSClient.emit_raw(ws_pid, "not-json")

    :ok =
      TestSupport.ProtocolWSClient.emit_raw(
        ws_pid,
        success_response(transport_id(context.generation, "unrelated"), "wrong-id")
      )

    status = Connection.status(context.instance_id)
    assert status.transport_pending_requests == 1
    assert status.transport_diagnostics.unattributable_frame == 1
    assert status.transport_diagnostics.late_or_uncorrelated_response == 1
    refute Task.yield(task, 0)

    invalid_batch =
      Jason.encode!([%{"jsonrpc" => "2.0", "id" => transport_id, "result" => "0x1"}])

    :ok = TestSupport.ProtocolWSClient.emit_raw(ws_pid, invalid_batch)
    assert Connection.status(context.instance_id).transport_pending_requests == 1
    refute Task.yield(task, 0)

    nested_id =
      ~s({"jsonrpc":"2.0","id":"client","result":{"id":"#{transport_id}"}})

    duplicate_id =
      ~s({"jsonrpc":"2.0","id":"#{transport_id}","id":"#{transport_id}","result":1})

    :ok = TestSupport.ProtocolWSClient.emit_raw(ws_pid, nested_id)
    :ok = TestSupport.ProtocolWSClient.emit_raw(ws_pid, duplicate_id)
    assert Connection.status(context.instance_id).transport_pending_requests == 1

    attributable_invalid =
      Jason.encode!(%{"jsonrpc" => "1.0", "id" => transport_id, "result" => "0x1"})

    :ok = TestSupport.ProtocolWSClient.acknowledge(ws_pid, transport_id, attributable_invalid)

    assert {:error, %JError{data: %{reason: :unsupported_version}}, _io_ms} = Task.await(task)
    assert Connection.status(context.instance_id).transport_pending_requests == 0

    trailing_task = request_task(context.channel, "client-id", 1_000)
    assert_receive {:protocol_ws_send, ^ws_pid, trailing_id, _payload}

    invalid_trailing = ~s({"jsonrpc":"1.0","id":"#{trailing_id}","result":"0x1"} trailing)
    :ok = TestSupport.ProtocolWSClient.acknowledge(ws_pid, trailing_id, invalid_trailing)

    assert {:error, %JError{data: %{reason: :invalid_json}}, _io_ms} =
             Task.await(trailing_task)

    invalid_vectors = [
      {:unsupported_version,
       fn id ->
         Jason.encode!(%{"jsonrpc" => "1.0", "id" => id, "result" => "0x1"})
       end},
      {:unexpected_notification,
       fn id ->
         Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => "notice"})
       end},
      {:invalid_envelope,
       fn id ->
         Jason.encode!(%{
           "jsonrpc" => "2.0",
           "id" => id,
           "result" => "0x1",
           "error" => %{"code" => -32_000, "message" => "both"}
         })
       end}
    ]

    Enum.each(invalid_vectors, fn {expected_reason, invalid_response} ->
      vector_task = request_task(context.channel, "client-id", 1_000)
      assert_receive {:protocol_ws_send, ^ws_pid, vector_id, _payload}

      :ok =
        TestSupport.ProtocolWSClient.acknowledge(
          ws_pid,
          vector_id,
          invalid_response.(vector_id)
        )

      assert {:error, %JError{data: %{reason: ^expected_reason}}, _io_ms} =
               Task.await(vector_task)
    end)

    error_task = request_task(context.channel, "error-client", 1_000)
    assert_receive {:protocol_ws_send, ^ws_pid, error_transport_id, _payload}
    error_data = %{"retry_after" => 75, "scope" => "provider"}

    raw_error =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => error_transport_id,
        "error" => %{"code" => -32_005, "message" => "rate limited", "data" => error_data}
      })

    :ok = TestSupport.ProtocolWSClient.acknowledge(ws_pid, error_transport_id, raw_error)

    expected_classification =
      ErrorClassifier.classify(-32_005, "rate limited",
        data: error_data,
        provider_id: context.channel.provider_id
      )

    assert {:error, %JError{} = classified_error, _io_ms} = Task.await(error_task)
    assert classified_error.data == error_data
    assert classified_error.category == expected_classification.category
    assert classified_error.retriable? == expected_classification.retriable?
    assert classified_error.breaker_penalty? == expected_classification.breaker_penalty?

    assert Connection.status(context.instance_id).transport_pending_requests == 0
  end

  test "uses validation completion for eligibility and receipt time only for I/O duration",
       context do
    {task, attempt_ref} = observed_request_task(context.channel)
    assert_receive {:protocol_ws_send, ws_pid, transport_id, _payload}

    received_at = System.monotonic_time(:microsecond)
    raw = success_response(transport_id, "0x1")

    send_parsed_frame(
      context.connection_pid,
      ws_pid,
      context.generation,
      raw,
      received_at,
      System.monotonic_time(:microsecond)
    )

    assert Connection.status(context.instance_id).transport_pending_requests == 0
    :ok = TestSupport.ProtocolWSClient.acknowledge(ws_pid, transport_id)

    assert_observation(attempt_ref, :send_started)
    assert_observation(attempt_ref, :send_confirmed)

    assert %{event_us: event_us, io_duration_us: io_duration_us} =
             assert_observation(attempt_ref, :response)

    assert event_us >= received_at
    assert io_duration_us >= 0
    assert {:ok, %Response.Success{id: "observed"}, _io_ms} = Task.await(task)
  end

  test "parses an attributed transport frame exactly once in the WebSockex process", context do
    mfa = {:json, :decode, 3}
    tracer = self()
    {:module, :json} = :code.ensure_loaded(:json)
    1 = :erlang.trace_pattern(mfa, true, [{:meta, tracer}])

    on_exit(fn ->
      :erlang.trace_pattern(mfa, false, [{:meta, tracer}])
    end)

    task = request_task(context.channel, "single-parse", 1_000)
    task_pid = task.pid

    assert_receive {:protocol_ws_send, ws_pid, transport_id, _payload}
    raw = success_response(transport_id, %{"payload" => String.duplicate("x", 32_000)})
    :ok = TestSupport.ProtocolWSClient.acknowledge(ws_pid, transport_id, raw)

    assert_receive {:trace_ts, ^ws_pid, :call, {:json, :decode, [^raw, _acc, _decoders]}, _ts},
                   1_000

    refute_receive {:trace_ts, ^ws_pid, :call, {:json, :decode, [_raw, _acc, _decoders]}, _ts},
                   0

    refute_receive {:trace_ts, ^task_pid, :call, {:json, :decode, [_raw, _acc, _decoders]}, _ts},
                   0

    assert {:ok, %Response.Success{id: "single-parse"}, _io_ms} = Task.await(task)
  end

  test "uses one bounded Connection authorization call on the unary hot path", context do
    traced_mfas = [
      {Connection, :authorize_transport, 6},
      {Connection, :transport_snapshot, 2},
      {Connection, :register_transport, 6},
      {Connection, :queue_transport, 6}
    ]

    Enum.each(traced_mfas, &:erlang.trace_pattern(&1, true, [:local]))

    on_exit(fn ->
      Enum.each(traced_mfas, &:erlang.trace_pattern(&1, false, [:local]))
    end)

    {task, release_request} = gated_request_task(context.channel, "one-authorization", 1_000)
    task_pid = task.pid
    :erlang.trace(task_pid, true, [:call])
    release_request.()

    assert_receive {:protocol_ws_send, ws_pid, transport_id, _payload}

    :ok =
      TestSupport.ProtocolWSClient.acknowledge(
        ws_pid,
        transport_id,
        success_response(transport_id, "0x1")
      )

    assert_receive {:trace, ^task_pid, :call, {Connection, :authorize_transport, _arguments}}

    for function <- [:transport_snapshot, :register_transport, :queue_transport] do
      refute_receive {:trace, ^task_pid, :call, {Connection, ^function, _arguments}}, 0
    end

    assert {:ok, %Response.Success{id: "one-authorization"}, _io_ms} = Task.await(task)
  end

  test "a D-1 response already in the task mailbox remains eligible after D",
       context do
    deadline_us = System.monotonic_time(:microsecond) + 500_000

    {task, attempt_ref} =
      observed_request_task_at(
        context.channel,
        "validation-deadline",
        5_000,
        deadline_us
      )

    assert_receive {:protocol_ws_send, ws_pid, transport_id, _payload}
    pending = transport_pending(context.connection_pid, transport_id)
    assert pending.deadline_us == deadline_us

    true = :erlang.suspend_process(task.pid)
    on_exit(fn -> if Process.alive?(task.pid), do: :erlang.resume_process(task.pid) end)

    raw = success_response(transport_id, "0x1")

    send_parsed_frame(
      context.connection_pid,
      ws_pid,
      context.generation,
      raw,
      deadline_us - 1,
      deadline_us - 1
    )

    assert Connection.status(context.instance_id).transport_pending_requests == 0
    wait_for_monotonic_deadline(deadline_us)
    true = :erlang.resume_process(task.pid)

    assert_observation(attempt_ref, :send_started)

    assert %{event_us: event_us} = assert_observation(attempt_ref, :response)

    assert event_us < deadline_us
    assert {:ok, %Response.Success{id: "validation-deadline"}, _io_ms} = Task.await(task)
  end

  test "handler maps live, deadline, cancellation, and generation decisions", context do
    state = %{
      parent: self(),
      connection_generation: context.generation,
      endpoint: %{id: "test"}
    }

    live_latch = :atomics.new(1, signed: false)
    live_key = {:control, make_ref()}

    assert {:reply, :ping, ^state} =
             Handler.handle_cast(
               {:send_if_live, context.generation, live_key,
                System.monotonic_time(:microsecond) + 1_000_000, live_latch, :ping},
               state
             )

    assert_receive {:ws_send_decision, _pid, generation, ^live_key, :accepted, _at}
    assert generation == context.generation

    assert_receive {:lasso_ws_send_written, ^generation, ^live_key} = written
    assert {:ok, ^state} = Handler.handle_info(written, state)
    assert_receive {:ws_send_written, _pid, ^generation, ^live_key, written_at_us}
    assert is_integer(written_at_us)

    for {generation, deadline, initial_latch, expected} <- [
          {context.generation <> "-stale", System.monotonic_time(:microsecond) + 1_000_000, 0,
           :stale_generation},
          {context.generation, System.monotonic_time(:microsecond), 0, :deadline},
          {context.generation, System.monotonic_time(:microsecond) + 1_000_000, 1, :cancelled}
        ] do
      latch = :atomics.new(1, signed: false)
      :atomics.put(latch, 1, initial_latch)
      key = {:control, make_ref()}

      assert {:ok, ^state} =
               Handler.handle_cast(
                 {:send_if_live, generation, key, deadline, latch, :ping},
                 state
               )

      assert_receive {:ws_send_decision, _pid, _generation, ^key, {:rejected, ^expected}, _at}
    end
  end

  test "task death during a blocked send releases the pending slot", context do
    task = request_task(context.channel, "caller-died", 5_000)
    assert_receive {:protocol_ws_send, ws_pid, transport_id, _payload}
    assert Connection.status(context.instance_id).transport_pending_requests == 1

    Process.unlink(task.pid)
    task_monitor = Process.monitor(task.pid)
    Process.exit(task.pid, :kill)
    assert_receive {:DOWN, ^task_monitor, :process, _pid, :killed}

    assert eventually(fn ->
             Connection.status(context.instance_id).transport_pending_requests == 0
           end)

    :ok = TestSupport.ProtocolWSClient.acknowledge(ws_pid, transport_id)
  end

  @tag pending_limit: 1
  test "queued cancellation expiry kills only its stuck connection generation",
       context do
    :sys.suspend(context.ws_pid)
    on_exit(fn -> resume_if_alive(context.ws_pid) end)

    task = request_task(context.channel, "cancelled-owner", 5_000)

    assert eventually(fn ->
             state = :sys.get_state(context.connection_pid)

             match?(
               [{_id, %{send_state: :queued}}],
               Map.to_list(state.transport_pending)
             )
           end)

    Process.unlink(task.pid)
    monitor = Process.monitor(task.pid)
    Process.exit(task.pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, _pid, :killed}

    assert eventually(fn ->
             match?(
               %{transport_pending_requests: 1, transport_tombstones: 1},
               Connection.status(context.instance_id)
             )
           end)

    assert {:error, %JError{category: :local_capacity_rejection}, _io_ms} =
             WebSocket.request(context.channel, rpc_request("capacity"), 100)

    assert {:message_queue_len, queued} = Process.info(context.ws_pid, :message_queue_len)
    assert queued <= 1

    send(context.connection_pid, {:heartbeat})

    assert %{pending_requests: 1, queued_control_sends: 0} =
             Connection.status(context.instance_id)

    {transport_id, pending} = only_transport_pending(context.connection_pid)
    cleanup_expiry_us = expire_send_cleanup(context.connection_pid, transport_id, pending)
    ws_monitor = Process.monitor(context.ws_pid)

    send(
      context.connection_pid,
      {:send_cleanup_expired, pending.connection, pending.generation, {:transport, transport_id},
       pending.token, cleanup_expiry_us}
    )

    assert_receive {:DOWN, ^ws_monitor, :process, ws_pid, :killed}
    assert ws_pid == context.ws_pid
    refute_receive {:protocol_ws_send, _ws_pid, _id, _payload}, 0

    assert_receive {:protocol_ws_connected, new_ws_pid, new_generation}
    assert new_ws_pid != context.ws_pid
    assert new_generation != context.generation

    assert eventually(fn ->
             match?(
               %{transport_pending_requests: 0, pending_requests: 0},
               Connection.status(context.instance_id)
             )
           end)
  end

  @tag pending_limit: 2
  test "a blocked subscription send cannot head-of-line block unary registration", context do
    :sys.suspend(context.ws_pid)
    on_exit(fn -> resume_if_alive(context.ws_pid) end)

    subscription =
      Task.async(fn ->
        Connection.request(
          context.instance_id,
          "eth_subscribe",
          ["newHeads"],
          5_000,
          "subscription-client"
        )
      end)

    assert eventually(fn ->
             Connection.status(context.instance_id).legacy_pending_requests == 1
           end)

    unary = request_task(context.channel, "unary-client", 5_000)

    assert eventually(fn ->
             match?(
               %{legacy_pending_requests: 1, transport_pending_requests: 1},
               Connection.status(context.instance_id)
             )
           end)

    assert {:message_queue_len, queued} = Process.info(context.ws_pid, :message_queue_len)
    assert queued <= 2

    :sys.resume(context.ws_pid)

    assert_receive {:protocol_ws_send, ws_pid, first_id, _payload}
    assert_receive {:protocol_ws_send, ^ws_pid, second_id, _payload}

    for id <- [first_id, second_id] do
      :ok =
        TestSupport.ProtocolWSClient.acknowledge(
          ws_pid,
          id,
          success_response(id, "0x1")
        )
    end

    assert {:ok, %Response.Success{id: "subscription-client"}} = Task.await(subscription)
    assert {:ok, %Response.Success{id: "unary-client"}, _io_ms} = Task.await(unary)
  end

  @tag send_mode: :pause_before_write
  test "WebSockex death before the accepted send is written remains indeterminate", context do
    {task, attempt_ref} = observed_request_task(context.channel)
    assert_receive {:protocol_ws_accepted_before_write, ws_pid, _transport_id, _payload}

    Process.exit(ws_pid, :kill)
    assert_observation(attempt_ref, :send_started)

    assert %{certainty: :indeterminate} =
             assert_observation(attempt_ref, :transport_failure)

    assert {:error, %JError{}, _io_ms} = Task.await(task)

    assert eventually(fn ->
             Connection.status(context.instance_id).transport_pending_requests == 0
           end)

    assert_receive {:protocol_ws_connected, new_ws_pid, new_generation}
    assert new_ws_pid != ws_pid
    assert new_generation != context.generation
  end

  @tag send_mode: :pause_before_write
  test "socket write failure after acceptance stays indeterminate and reconnects", context do
    {task, attempt_ref} = observed_request_task(context.channel)

    assert_receive {:protocol_ws_accepted_before_write, ws_pid, transport_id, _payload}
    assert_observation(attempt_ref, :send_started)
    ws_monitor = Process.monitor(ws_pid)

    send(ws_pid, {:fail_protocol_ws_write, :econnreset})

    assert_receive {:protocol_ws_write_failed, ^ws_pid, ^transport_id, :econnreset}
    assert_receive {:DOWN, ^ws_monitor, :process, ^ws_pid, {:socket_write_error, :econnreset}}

    refute_confirmed(attempt_ref)

    assert %{certainty: :indeterminate} =
             assert_observation(attempt_ref, :transport_failure)

    assert {:error, %JError{}, _io_ms} = Task.await(task)

    assert_receive {:protocol_ws_connected, new_ws_pid, new_generation}
    assert new_ws_pid != ws_pid
    assert new_generation != context.generation

    assert eventually(fn ->
             match?(
               %{transport_pending_requests: 0, transport_tombstones: 0},
               Connection.status(context.instance_id)
             )
           end)

    refute_confirmed(attempt_ref)
  end

  test "a disconnect after write confirmation remains dispatched and cannot be replayed",
       context do
    {task, attempt_ref} = observed_request_task(context.channel)
    assert_receive {:protocol_ws_send, ws_pid, transport_id, _payload}
    assert_observation(attempt_ref, :send_started)
    assert_observation(attempt_ref, :send_confirmed)

    :ok = TestSupport.ProtocolWSClient.disconnect(ws_pid, :closed)
    :ok = TestSupport.ProtocolWSClient.acknowledge(ws_pid, transport_id)

    assert %{certainty: :dispatched} =
             assert_observation(attempt_ref, :transport_failure)

    assert {:error, %JError{}, _io_ms} = Task.await(task)

    assert_receive {:protocol_ws_connected, new_ws_pid, new_generation}
    assert new_ws_pid != ws_pid
    assert new_generation != context.generation

    :ok = TestSupport.ProtocolWSClient.emit_raw(ws_pid, success_response(transport_id, "late"))

    status = Connection.status(context.instance_id)
    assert status.transport_pending_requests == 0
    assert status.transport_diagnostics.stale_generation == 1
  end

  test "a saturated suspended breaker cannot block disconnect handling", context do
    :sys.suspend(context.breaker_pid)

    on_exit(fn ->
      if Process.alive?(context.breaker_pid), do: :sys.resume(context.breaker_pid)
    end)

    %{capacity: capacity} = ControlRing.stats({context.instance_id, :ws})

    for _index <- 1..capacity do
      assert :ok =
               CircuitBreaker.report_external_bounded(
                 {context.instance_id, :ws},
                 {:error, :disconnect_flood}
               )
    end

    assert {:error, :saturated} =
             CircuitBreaker.report_external_bounded(
               {context.instance_id, :ws},
               {:error, :disconnect_flood}
             )

    disconnect = Task.async(fn -> TestSupport.ProtocolWSClient.disconnect(context.ws_pid) end)
    assert :ok = Task.await(disconnect, 1_000)

    assert %{connected: false} = Connection.status(context.instance_id)

    {:messages, queued_messages} = Process.info(context.breaker_pid, :messages)

    assert Enum.all?(queued_messages, fn
             {:breaker_control_ready, _breaker_id, _generation, _epoch} -> true
             :breaker_control_audit -> true
             _other -> false
           end)

    assert length(queued_messages) <= 2

    assert {:ok, %Snapshot{control_health: :degraded}} =
             Snapshot.lookup({context.instance_id, :ws})

    :sys.resume(context.breaker_pid)
  end

  defp request_task(channel, client_id, timeout) do
    Task.async(fn -> WebSocket.request(channel, rpc_request(client_id), timeout) end)
  end

  defp gated_request_task(channel, client_id, timeout) do
    parent = self()

    task =
      Task.async(fn ->
        receive do
          {:begin_request, ^parent} ->
            WebSocket.request(channel, rpc_request(client_id), timeout)
        end
      end)

    {task, fn -> send(task.pid, {:begin_request, parent}) end}
  end

  defp observed_request_task(channel, timeout \\ 5_000) do
    observed_request_task_at(
      channel,
      "observed",
      timeout,
      System.monotonic_time(:microsecond) + timeout * 1_000
    )
  end

  defp observed_request_task_at(channel, client_id, timeout, deadline_us) do
    owner = self()
    attempt_ref = make_ref()

    task =
      Task.async(fn ->
        attempt_context =
          AttemptProtocol.new_context(self(), attempt_ref, deadline_us)

        :ok = AttemptProtocol.install_context(attempt_context)
        send(owner, {:attempt_context, attempt_ref, attempt_context})

        result = WebSocket.request(channel, rpc_request(client_id), timeout)
        candidate = AttemptProtocol.take_terminal_candidate(attempt_context)
        snapshot = AttemptProtocol.close(attempt_context)
        send(owner, {:attempt_finished, attempt_ref, candidate, snapshot})
        result
      end)

    assert_receive {:attempt_context, ^attempt_ref, attempt_context}
    {task, %{ref: attempt_ref, context: attempt_context}}
  end

  defp ws_attempt_identity(context, request_id) do
    AttemptIdentity.new(
      request_id: request_id,
      attempt_id: "#{request_id}-attempt",
      profile: "public",
      chain_id: 1,
      upstream_instance_id: context.instance_id,
      transport: :ws,
      route_generation: 1,
      circuit_scope: :broad,
      circuit_epoch: 1,
      execution_safety: :replay_safe,
      routing_intent: "default",
      workload_key: "eth_blockNumber",
      request_budget_ms: 1_000,
      candidate_admission_count: 1,
      dispatch_count: 1
    )
  end

  defp assert_observation(%{context: %{gate: gate}}, :send_started) do
    assert eventually(fn -> :atomics.get(gate, 2) != unset_timestamp() end)
    %{kind: :send_started, event_us: :atomics.get(gate, 2)}
  end

  defp assert_observation(%{context: %{gate: gate}}, :send_confirmed) do
    assert eventually(fn -> :atomics.get(gate, 3) != unset_timestamp() end)
    %{kind: :send_confirmed, event_us: :atomics.get(gate, 3)}
  end

  defp assert_observation(%{ref: attempt_ref}, kind) do
    assert_receive {:attempt_finished, ^attempt_ref, {:ok, %{kind: ^kind} = observation},
                    _snapshot},
                   1_000

    observation
  end

  defp refute_confirmed(%{context: %{gate: gate}}) do
    assert :atomics.get(gate, 3) == unset_timestamp()
  end

  defp unset_timestamp, do: -9_223_372_036_854_775_808

  defp rpc_request(id) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => "eth_blockNumber", "params" => []}
  end

  defp success_response(transport_id, result) do
    Jason.encode!(%{"jsonrpc" => "2.0", "id" => transport_id, "result" => result})
  end

  defp transport_id(generation, suffix), do: "lasso-#{generation}-#{suffix}"

  defp send_parsed_frame(
         connection_pid,
         ws_pid,
         generation,
         raw_bytes,
         received_at,
         validated_at
       ) do
    parsed = UpstreamResponse.parse_ws_frame(raw_bytes)

    send(
      connection_pid,
      {:ws_message, ws_pid, generation, parsed, raw_bytes, received_at, validated_at}
    )
  end

  defp replace_deadline(connection_pid, transport_id) do
    deadline = System.monotonic_time(:microsecond)

    :sys.replace_state(connection_pid, fn state ->
      pending = Map.fetch!(state.transport_pending, transport_id)
      Process.cancel_timer(pending.timer)

      put_in(
        state,
        [:transport_pending, transport_id],
        %{
          pending
          | deadline_us: deadline,
            timer: make_ref()
        }
      )
    end)

    deadline
  end

  defp only_transport_pending(connection_pid) do
    connection_pid
    |> :sys.get_state()
    |> Map.fetch!(:transport_pending)
    |> Map.to_list()
    |> then(fn [pending] -> pending end)
  end

  defp transport_pending(connection_pid, transport_id) do
    connection_pid
    |> :sys.get_state()
    |> Map.fetch!(:transport_pending)
    |> Map.get(transport_id)
  end

  defp expire_transport(connection_pid, transport_id, pending) do
    deadline = System.monotonic_time(:microsecond)
    Process.cancel_timer(pending.timer)

    :sys.replace_state(connection_pid, fn state ->
      put_in(
        state,
        [:transport_pending, transport_id],
        %{
          pending
          | deadline_us: deadline,
            timer: make_ref()
        }
      )
    end)

    send(
      connection_pid,
      {:transport_timeout, transport_id, pending.generation, pending.token}
    )
  end

  defp force_transport_deadline(connection_pid, transport_id, deadline_us) do
    :sys.replace_state(connection_pid, fn state ->
      pending = Map.fetch!(state.transport_pending, transport_id)
      Process.cancel_timer(pending.timer)

      put_in(
        state,
        [:transport_pending, transport_id],
        %{
          pending
          | deadline_us: deadline_us,
            timer: make_ref()
        }
      )
    end)
  end

  defp expire_send_cleanup(connection_pid, transport_id, pending) do
    cleanup_expiry_us = System.monotonic_time(:microsecond)
    Process.cancel_timer(pending.timer)

    :sys.replace_state(connection_pid, fn state ->
      put_in(
        state,
        [:transport_pending, transport_id],
        %{pending | cleanup_expiry_us: cleanup_expiry_us, timer: make_ref()}
      )
    end)

    cleanup_expiry_us
  end

  defp eventually(fun, deadline_us \\ System.monotonic_time(:microsecond) + 1_000_000) do
    if fun.() do
      true
    else
      if System.monotonic_time(:microsecond) >= deadline_us do
        false
      else
        receive do
        after
          0 -> eventually(fun, deadline_us)
        end
      end
    end
  end

  defp wait_for_monotonic_deadline(deadline_us) do
    remaining_us = deadline_us - System.monotonic_time(:microsecond)

    if remaining_us > 0 do
      marker = make_ref()
      Process.send_after(self(), {:deadline_marker, marker}, div(remaining_us + 999, 1_000))

      receive do
        {:deadline_marker, ^marker} -> :ok
      after
        1_000 -> flunk("monotonic deadline marker was not delivered")
      end

      wait_for_monotonic_deadline(deadline_us)
    end
  end

  defp stop_if_alive(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
  catch
    :exit, _reason -> :ok
  end

  defp resume_if_alive(pid) do
    if Process.alive?(pid), do: :sys.resume(pid)
  catch
    :exit, _reason -> :ok
  end
end
