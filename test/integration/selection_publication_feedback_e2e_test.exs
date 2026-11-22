defmodule Lasso.RPC.SelectionPublicationFeedbackE2ETest do
  use Lasso.Test.LassoIntegrationCase

  alias Lasso.BlockSync.Strategies.HttpStrategy
  alias Lasso.Config.ConfigStore
  alias Lasso.Core.Request.RequestOwner
  alias Lasso.Core.Support.CircuitBreaker
  alias Lasso.Core.Support.CircuitBreaker.Snapshot
  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.Providers.{Catalog, ChainIdentity, InstanceState}

  alias Lasso.RPC.{
    AttemptIdentity,
    AttemptProjection,
    Channel,
    RequestOptions,
    RequestPipeline,
    Response,
    TransportRegistry
  }

  alias Lasso.Testing.MockHTTPProvider

  test "published-generation quota feedback survives replacement preparation", %{chain: chain} do
    parent = self()

    quotas =
      for n <- 1..3 do
        id = "quota-#{n}"

        %{
          id: id,
          priority: n,
          background_observations: false,
          behavior:
            {:conditional,
             fn _, _, _ ->
               send(parent, {:quota_attempt, id})

               {:error,
                %JError{
                  code: -32_005,
                  message: "Quota exceeded",
                  category: :rate_limit,
                  retriable?: true,
                  breaker_penalty?: false,
                  data: %{"retry_after_ms" => 60_000}
                }}
             end}
        }
      end

    setup_providers(quotas ++ [%{id: "healthy", priority: 100, background_observations: false}])
    snapshot = Catalog.snapshot()
    ahead = advance_config(snapshot.generation)
    {task, owner, ref} = hold_replacement(ahead)
    learning = learning_rows(chain)

    assert {:error, %{code: -32_005}, first} = request(chain)
    assert first.execution_envelope.dispatch_count == 3

    for %{id: id} <- quotas do
      assert_receive {:quota_attempt, ^id}
      instance = Catalog.lookup_instance_id("public", chain, id)
      assert %{rate_limited: true} = InstanceState.read_rate_limit(instance, :http)
    end

    assert {:ok, response, next} = request(chain)
    assert {:ok, _} = Response.Success.decode_result(response)
    assert next.executed_channel.provider_id == "healthy"
    assert next.executed_channel.route_generation == snapshot.generation
    assert next.execution_envelope.dispatch_count == 1
    refute_receive {:quota_attempt, _}, 0
    assert learning_rows(chain) == learning

    send(owner, {:catalog_publication_continue, ref, :after_control_populate})
    assert_receive {:catalog_publication_phase, ^owner, ^ref, :before_pointer_swap, ^ahead}, 5000
    send(owner, {:catalog_publication_continue, ref, :before_pointer_swap})
    assert :ok = Task.await(task)

    assert {:ok, _, published} = request(chain)
    assert published.executed_channel.provider_id == "healthy"
    assert published.executed_channel.route_generation == ahead
    assert published.execution_envelope.dispatch_count == 1
    refute_receive {:quota_attempt, _}, 0
  end

  test "published identity and pinned HTTP health polling remain valid while config is ahead", %{
    chain: chain
  } do
    setup_providers([%{id: "identity", priority: 1, background_observations: false}])
    snapshot = Catalog.snapshot()
    instance = Catalog.lookup_instance_id("public", chain, "identity")
    _ahead = advance_config(snapshot.generation)

    ChainIdentity.record(ChainIdentity.capture(instance, snapshot), :rejected)
    assert {:error, _, denied} = request(chain, "identity")
    assert denied.execution_envelope.dispatch_count == 0
    ChainIdentity.record(ChainIdentity.capture(instance, snapshot), :verified)

    assert {:ok, poller} =
             HttpStrategy.start(chain, instance, parent: self(), poll_interval_ms: 600_000)

    assert {:polling, active} = HttpStrategy.poll(poller)
    on_exit(fn -> HttpStrategy.stop(active) end)
    assert active.poll_plan.provider_id == "identity"

    assert_receive {:http_strategy, :poll_result, ^instance, owner_id, owner_pid, outcome},
                   5000

    assert {:ok, completed} =
             HttpStrategy.handle_message({:poll_result, owner_id, owner_pid, outcome}, active)

    on_exit(fn -> HttpStrategy.stop(completed) end)
    assert is_integer(completed.last_height)
    assert completed.consecutive_failures == 0

    assert [{_, %{http_status: :healthy}}] =
             :ets.lookup(:lasso_instance_state, {:health_block_sync, instance})

    assert {:ok, _, allowed} = request(chain, "identity")
    assert allowed.executed_channel.route_generation == snapshot.generation
    assert allowed.execution_envelope.dispatch_count == 1
  end

  test "a paused quota attempt cannot cool down a retired and re-added instance", %{chain: chain} do
    quota = %JError{
      code: -32_005,
      message: "Quota exceeded",
      category: :rate_limit,
      retriable?: true,
      breaker_penalty?: false
    }

    setup_providers([
      %{
        id: "lifecycle",
        background_observations: false,
        behavior: {:conditional, fn _, _, _ -> {:error, quota} end}
      }
    ])

    instance = Catalog.lookup_instance_id("public", chain, "lifecycle")
    assert {:ok, original} = Snapshot.lookup({instance, :http})
    assert {:ok, channel} = TransportRegistry.get_channel("public", chain, "lifecycle", :http)
    deadline = System.monotonic_time(:microsecond) + 5_000_000
    assert {:ok, receipt} = CircuitBreaker.admit({instance, :http}, deadline)

    identity =
      AttemptIdentity.new(
        request_id: "retired-quota",
        attempt_id: "retired-attempt",
        profile: "public",
        chain_id: chain,
        upstream_instance_id: instance,
        transport: :http,
        route_generation: channel.route_generation,
        circuit_scope: :broad,
        circuit_epoch: receipt.epoch,
        execution_safety: :replay_safe,
        routing_intent: "priority",
        workload_key: "client",
        request_budget_ms: 5_000,
        candidate_admission_count: 1,
        dispatch_count: 1
      )

    parent = self()
    ref = make_ref()

    attempt =
      Task.async(fn ->
        outcome =
          RequestOwner.execute(
            identity,
            deadline,
            fn ->
              Channel.request(
                channel,
                %{"jsonrpc" => "2.0", "id" => 1, "method" => "eth_blockNumber", "params" => []},
                5_000
              )
            end,
            test_before_restore: fn ->
              send(parent, {:before_projection, self(), ref})

              receive do
                ^ref -> :ok
              after
                5_000 -> raise "projection barrier timed out"
              end
            end
          )

        event = AttemptProjection.new(outcome.fact, "lifecycle", "eth_blockNumber")
        result = AttemptProjection.process(event, Lasso.ExecutionProjectionDispatcher, instance)
        {outcome.fact, result}
      end)

    on_exit(fn -> send(attempt.pid, ref) end)
    assert_receive {:before_projection, producer, ^ref}, 5_000
    assert producer == attempt.pid
    assert :ok = MockHTTPProvider.stop_mock(chain, "lifecycle")
    assert Catalog.lookup_instance_id("public", chain, "lifecycle") == nil

    case GenServer.whereis(CircuitBreaker.via_name({instance, :http})) do
      pid when is_pid(pid) -> GenServer.stop(pid)
      nil -> :ok
    end

    setup_providers([%{id: "lifecycle", background_observations: false}])
    assert Catalog.lookup_instance_id("public", chain, "lifecycle") == instance
    assert {:ok, fresh} = Snapshot.lookup({instance, :http})
    assert fresh.epoch > original.epoch
    send(producer, ref)

    assert {%{error_category: :quota, identity: %{circuit_epoch: epoch}}, {:stale, _}} =
             Task.await(attempt)

    assert epoch == original.epoch
    assert :ets.lookup(:lasso_instance_state, {:rate_limit, instance, :http}) == []
    assert %{rate_limited: false} = InstanceState.read_rate_limit(instance, :http)
    assert {:ok, _, served} = request(chain)
    assert served.execution_envelope.dispatch_count == 1

    # Also cover retirement between the writer's epoch check and ETS insertion.
    :ets.insert(
      :lasso_instance_state,
      {{:rate_limit, instance, :http},
       %{
         expiry_ms: System.monotonic_time(:millisecond) + 30_000,
         retry_after_ms: 30_000,
         circuit_epoch: original.epoch
       }}
    )

    assert %{rate_limited: false} = InstanceState.read_rate_limit(instance, :http)
    assert {:ok, _, still_served} = request(chain)
    assert still_served.execution_envelope.dispatch_count == 1
    assert :ok = InstanceState.record_rate_limit(instance, :http, 1_000, fresh.epoch)
    row = :ets.lookup(:lasso_instance_state, {:rate_limit, instance, :http})

    assert %{rate_limited: true, remaining_ms: remaining} =
             InstanceState.read_rate_limit(instance, :http)

    assert remaining <= 1_000
    assert :ok = InstanceState.record_rate_limit(instance, :http, 30_000, original.epoch)
    assert :ets.lookup(:lasso_instance_state, {:rate_limit, instance, :http}) == row
  end

  test "failed catalog candidates retain the owner, routing table and serving path", %{
    chain: chain
  } do
    setup_providers([%{id: "stable", background_observations: false}])
    original = :persistent_term.get(:lasso_config_store_active)
    {table, generation} = original
    snapshot = Catalog.snapshot()
    owner = Process.whereis(Lasso.Providers.Catalog.Owner)
    config_owner = Process.whereis(ConfigStore)
    candidate = :ets.new(:rejected_config, [:public, :set])
    :ets.insert(candidate, :ets.tab2list(table))
    :ets.insert(candidate, {{:profile, "public", :chains}, %{chain => %{providers: nil}}})
    :persistent_term.put(:lasso_config_store_active, {candidate, generation + 1})
    on_exit(fn -> :persistent_term.put(:lasso_config_store_active, original) end)

    assert_raise Protocol.UndefinedError, fn -> Catalog.build_from_config() end
    assert Catalog.snapshot() == snapshot
    assert Process.whereis(Lasso.Providers.Catalog.Owner) == owner
    assert Process.whereis(ConfigStore) == config_owner

    :persistent_term.put(:lasso_config_store_active, original)

    conn =
      Plug.Test.conn(
        :post,
        "/rpc/profile/public/provider/stable/#{chain}",
        Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "eth_blockNumber", params: []})
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> LassoWeb.Endpoint.call([])

    assert conn.status == 200
    assert Map.has_key?(Jason.decode!(conn.resp_body), "result")
    assert (Plug.Test.conn(:get, "/api/health") |> LassoWeb.Endpoint.call([])).status == 200
    :persistent_term.put(:lasso_config_store_active, original)
  end

  test "selection exhaustion carries bounded gate observations without provider endpoints", %{
    chain: chain
  } do
    setup_providers([%{id: "closed-route", background_observations: false}])
    instance = Catalog.lookup_instance_id("public", chain, "closed-route")
    CircuitBreaker.open({instance, :http})
    observer = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:lasso, :routing, :selection_exhausted],
      fn _, _, metadata, _ -> send(observer, {:exhausted, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    terminal_handler = {handler, :terminal}

    :telemetry.attach(
      terminal_handler,
      [:lasso, :rpc, :request, :terminal],
      fn _, _, metadata, _ ->
        if metadata.chain_id == chain, do: send(observer, {:terminal_cause, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(terminal_handler) end)
    assert {:error, error, ctx} = request(chain)
    assert ctx.execution_envelope.dispatch_count == 0
    assert_receive {:terminal_cause, %{exhaustion_cause: :no_candidates}}, 5_000

    assert %Lasso.RPC.RequestTerminal.OrdinaryExhaustion{reason: :providers_exhausted} =
             RequestPipeline.build_request_terminal(:error, error, ctx)

    assert_receive {:exhausted, evidence}

    assert [%{provider_id: "closed-route", transport: :http, reason: :circuit_open}] =
             evidence.recorded_rejections

    refute Jason.encode!(evidence) =~ "mock-closed-route.test"
    assert byte_size(Jason.encode!(evidence)) <= 6_000
  end

  test "unavailable catalog capture keeps its bounded phase evidence", %{chain: chain} do
    setup_providers([%{id: "capture", background_observations: false}])
    snapshot = Catalog.snapshot()
    key = Catalog.persistent_term_key()
    :persistent_term.erase(key)
    on_exit(fn -> :persistent_term.put(key, snapshot) end)
    observer = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:lasso, :routing, :selection_exhausted],
      fn _, _, metadata, _ -> send(observer, {:capture_failed, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert {:error, _, ctx} = request(chain)
    assert ctx.execution_envelope.dispatch_count == 0
    assert_receive {:capture_failed, evidence}
    assert %{catalog_status: :unavailable, catalog_generation: nil} = evidence.capture_failure
    assert is_integer(evidence.capture_failure.config_generation)
    :persistent_term.put(key, snapshot)
  end

  defp request(chain, provider_override \\ nil) do
    RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [], %RequestOptions{
      profile: "public",
      provider_override: provider_override,
      strategy: :priority,
      transport: :http,
      timeout_ms: 5000
    })
  end

  defp advance_config(generation) do
    chain = 1_800_000_000 + System.unique_integer([:positive])
    assert :ok = ConfigStore.register_chain_runtime("public", chain, %{providers: []})
    on_exit(fn -> ConfigStore.unregister_chain_runtime("public", chain) end)
    assert ConfigStore.route_generation() == generation + 1
    generation + 1
  end

  defp hold_replacement(generation) do
    owner = Process.whereis(Lasso.Providers.Catalog.Owner)
    ref = make_ref()
    prior = Application.get_env(:lasso, :catalog_publication_barrier)
    Application.put_env(:lasso, :catalog_publication_barrier, {self(), ref})

    on_exit(fn ->
      for phase <- [:after_catalog_populate, :after_control_populate, :before_pointer_swap],
          do: send(owner, {:catalog_publication_continue, ref, phase})

      if prior,
        do: Application.put_env(:lasso, :catalog_publication_barrier, prior),
        else: Application.delete_env(:lasso, :catalog_publication_barrier)
    end)

    task = Task.async(fn -> Catalog.build_from_config() end)

    assert_receive {:catalog_publication_phase, ^owner, ^ref, :after_catalog_populate,
                    ^generation},
                   5000

    send(owner, {:catalog_publication_continue, ref, :after_catalog_populate})

    assert_receive {:catalog_publication_phase, ^owner, ^ref, :after_control_populate,
                    ^generation},
                   5000

    {task, owner, ref}
  end

  # The shared table also holds wider rows, such as chain identity verdicts.
  defp learning_rows(chain) do
    for {key, _} = row <- :ets.tab2list(:lasso_instance_state),
        elem(key, 0) in [
          :routing_control_scope,
          :routing_control,
          :routing_system_prior,
          :routing_fastest_winner,
          :routing_family,
          :routing_system_family,
          :routing_fastest_family
        ],
        chain in Tuple.to_list(key) do
      row
    end
    |> Enum.sort()
  end
end
