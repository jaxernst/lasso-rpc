defmodule Lasso.RPC.ReadExplorationTest do
  use Lasso.Test.LassoIntegrationCase

  @moduletag :integration

  alias Lasso.Config.ConfigStore
  alias Lasso.Core.Support.CircuitBreaker.Snapshot
  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.Providers.Catalog

  alias Lasso.RPC.{
    AttemptIdentity,
    AttemptProjection,
    AttemptTerminal,
    RequestOptions,
    RequestPipeline
  }

  alias Lasso.Testing.MockProviderBehavior

  setup %{chain: chain} do
    original = Application.get_env(:lasso, :routing_exploration)

    Application.put_env(:lasso, :routing_exploration,
      enabled: true,
      sample_every: 1,
      disabled_profiles: []
    )

    on_exit(fn -> Application.put_env(:lasso, :routing_exploration, original) end)

    setup_providers([
      %{id: "proven", priority: 1, behavior: :healthy, background_observations: false},
      %{id: "unproven", priority: 2, behavior: :healthy, background_observations: false}
    ])

    seed_qualified(chain, "proven")
    observer = self()
    handler = "exploration-#{chain}"

    :telemetry.attach_many(
      handler,
      [
        [:lasso, :routing, :exploration, :selected],
        [:lasso, :routing, :exploration, :completed],
        [:lasso, :routing, :exploration, :skipped]
      ],
      fn event, measurements, metadata, pid ->
        send(pid, {:exploration, List.last(event), measurements, metadata})
      end,
      observer
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  test "without operator opt-in a read uses the proven route", %{chain: chain} do
    Application.delete_env(:lasso, :routing_exploration)

    assert {:ok, _response, ctx} = request(chain)
    assert ctx.executed_channel.provider_id == "proven"
    assert ctx.execution_envelope.dispatch_count == 1
    assert ctx.terminal_attempt_fact.identity.attempt_kind == :ordinary
    refute_received {:exploration, :selected, _, _}
    assert exploration_rows(chain) == []
  end

  test "a real read samples an under-observed route within one dispatch", %{chain: chain} do
    assert {:ok, _response, ctx} = request(chain)
    assert ctx.executed_channel.provider_id == "unproven"
    assert ctx.execution_envelope.dispatch_count == 1
    assert ctx.terminal_attempt_fact.identity.attempt_kind == :exploration
    assert_receive {:exploration, :selected, _, _}
    assert_receive {:exploration, :completed, _, %{success: true}}
    assert [{_, %{active: nil}}] = exploration_rows(chain)

    assert {:ok, _response, next_ctx} = request(chain)
    assert next_ctx.executed_channel.provider_id == "proven"
    assert next_ctx.execution_envelope.dispatch_count == 1
    assert_receive {:exploration, :skipped, _, %{reason: :no_candidate_or_capacity}}
  end

  test "a slow exploratory read returns to the proven route within the original deadline", %{
    chain: chain
  } do
    observer = self()

    set_behavior(
      "unproven",
      {:conditional,
       fn method, params, _state ->
         send(observer, :exploration_dispatched)
         Process.sleep(350)
         MockProviderBehavior.execute_behavior(:healthy, method, params, %{})
       end}
    )

    instance = Catalog.lookup_instance_id("public", chain, "unproven")
    assert {:ok, before} = Snapshot.lookup({instance, :http})
    started = System.monotonic_time(:millisecond)
    assert {:ok, _response, ctx} = request(chain)
    elapsed = System.monotonic_time(:millisecond) - started
    assert_receive :exploration_dispatched
    assert ctx.executed_channel.provider_id == "proven"
    assert ctx.execution_envelope.dispatch_count == 2
    assert ctx.execution_envelope.original_timeout_ms == 1_000
    assert elapsed < 500
    assert_receive {:exploration, :completed, _, %{success: false, outcome: outcome}}
    assert outcome in [:deadline, :transport_failure]
    assert {:ok, after_snapshot} = Snapshot.lookup({instance, :http})
    assert after_snapshot.state == :closed
    assert after_snapshot.failure_count == before.failure_count
    assert [{_, %{active: nil}}] = exploration_rows(chain)
  end

  test "failed exploration cools down while preserving provider failure attribution", %{
    chain: chain
  } do
    set_behavior("unproven", :always_fail)
    instance = Catalog.lookup_instance_id("public", chain, "unproven")
    assert {:ok, before} = Snapshot.lookup({instance, :http})

    assert {:ok, _response, ctx} = request(chain)
    assert ctx.executed_channel.provider_id == "proven"
    assert ctx.execution_envelope.dispatch_count == 2
    assert_receive {:exploration, :completed, _, %{success: false}}

    assert {:ok, after_snapshot} = Snapshot.lookup({instance, :http})
    assert after_snapshot.failure_count == before.failure_count + 1

    assert {:ok, _response, next_ctx} = request(chain)
    assert next_ctx.executed_channel.provider_id == "proven"
    assert next_ctx.execution_envelope.dispatch_count == 1
    assert_receive {:exploration, :skipped, _, %{reason: :no_candidate_or_capacity}}
  end

  test "concurrent reads admit only one exploratory request in the family", %{chain: chain} do
    observer = self()

    set_behavior(
      "unproven",
      {:conditional,
       fn method, params, _state ->
         send(observer, :exploration_in_flight)
         Process.sleep(150)
         MockProviderBehavior.execute_behavior(:healthy, method, params, %{})
       end}
    )

    first = Task.async(fn -> request(chain) end)
    assert_receive :exploration_in_flight

    assert {:ok, _response, second_ctx} = request(chain)
    assert second_ctx.executed_channel.provider_id == "proven"
    assert second_ctx.terminal_attempt_fact.identity.attempt_kind == :ordinary

    assert {:ok, _response, first_ctx} = Task.await(first)
    assert first_ctx.executed_channel.provider_id == "proven"
    assert first_ctx.execution_envelope.dispatch_count == 2
    assert [{_, %{active: nil}}] = exploration_rows(chain)
  end

  test "retired route ownership prevents exploratory dispatch and uses the fallback", %{
    chain: chain
  } do
    observer = self()
    instance = Catalog.lookup_instance_id("public", chain, "unproven")

    set_behavior(
      "unproven",
      {:conditional,
       fn method, params, _state ->
         send(observer, :retired_dispatch)
         MockProviderBehavior.execute_behavior(:healthy, method, params, %{})
       end}
    )

    handler = "retire-exploration-#{chain}"

    :telemetry.attach(
      handler,
      [:lasso, :routing, :exploration, :selected],
      fn _, _, %{upstream_instance_id: selected}, _ ->
        if selected == instance,
          do:
            :ets.delete(
              :lasso_instance_state,
              {:routing_control, "public", chain, instance, :http, "client"}
            )
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, _response, ctx} = request(chain)
    assert ctx.executed_channel.provider_id == "proven"
    assert ctx.execution_envelope.dispatch_count == 1
    refute_receive :retired_dispatch
    assert exploration_rows(chain) == []
  end

  test "direct provider routing and system reads never reserve exploration", %{chain: chain} do
    assert {:ok, _response, direct_ctx} =
             RequestPipeline.execute_via_channels(
               chain,
               "eth_blockNumber",
               [],
               %{options() | provider_override: "unproven"}
             )

    assert direct_ctx.terminal_attempt_fact.identity.attempt_kind == :ordinary
    assert_receive {:exploration, :skipped, _, %{reason: :ineligible}}

    assert {:ok, _response, system_ctx} =
             RequestPipeline.execute_via_channels(
               chain,
               "eth_blockNumber",
               [],
               %{options() | request_origin: :system}
             )

    assert system_ctx.terminal_attempt_fact.identity.attempt_kind == :ordinary
    assert_receive {:exploration, :skipped, _, %{reason: :ineligible}}
    refute_received {:exploration, :selected, _, _}
    assert exploration_rows(chain) == []
  end

  test "disabled profile and unsafe request do not reserve exploration", %{chain: chain} do
    Application.put_env(:lasso, :routing_exploration,
      enabled: true,
      sample_every: 1,
      disabled_profiles: ["public"]
    )

    assert {:ok, _response, ctx} = request(chain)
    assert ctx.executed_channel.provider_id == "proven"
    assert_receive {:exploration, :skipped, _, %{reason: :ineligible}}

    Application.put_env(:lasso, :routing_exploration,
      enabled: true,
      sample_every: 1,
      disabled_profiles: []
    )

    assert {:ok, _response, unsafe_ctx} =
             RequestPipeline.execute_via_channels(
               chain,
               "eth_sendRawTransaction",
               ["0x1234"],
               options()
             )

    assert unsafe_ctx.execution_envelope.dispatch_count == 1
    assert unsafe_ctx.terminal_attempt_fact.identity.attempt_kind == :ordinary
    assert_receive {:exploration, :skipped, _, %{reason: :ineligible}}
    assert exploration_rows(chain) == []
  end

  test "new routing generation retires exploration cooldown state", %{chain: chain} do
    assert {:ok, _response, _ctx} = request(chain)
    assert [{_, %{active: nil}}] = exploration_rows(chain)
    generation = ConfigStore.route_generation()

    setup_providers([
      %{id: "new-route", priority: 3, behavior: :healthy, background_observations: false}
    ])

    assert ConfigStore.route_generation() > generation
    assert exploration_rows(chain) == []
  end

  for {category, code} <- [{:unclassified_server_error, -32_000}, {:unknown_error, 35}] do
    @tag ambiguous_category: category, ambiguous_code: code
    test "#{category} falls back on safe reads without penalizing health", %{
      chain: chain,
      ambiguous_category: category,
      ambiguous_code: code
    } do
      failure =
        {:error,
         JError.new(code, "unfamiliar upstream failure",
           category: category,
           data: %{"detail" => "original upstream data"},
           retriable?: false,
           breaker_penalty?: false
         )}

      set_behavior("unproven", failure)
      instance = Catalog.lookup_instance_id("public", chain, "unproven")
      assert {:ok, before} = Snapshot.lookup({instance, :http})

      assert {:ok, _response, ctx} = request(chain)
      assert ctx.executed_channel.provider_id == "proven"
      assert ctx.execution_envelope.dispatch_count == 2
      assert {:ok, after_snapshot} = Snapshot.lookup({instance, :http})
      assert after_snapshot.failure_count == before.failure_count

      ordinary_opts = %{options() | provider_override: "unproven", failover_on_override: true}

      assert {:ok, _response, ordinary_ctx} =
               RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [], ordinary_opts)

      assert ordinary_ctx.executed_channel.provider_id == "proven"
      assert ordinary_ctx.execution_envelope.dispatch_count == 2

      assert {:error, %JError{code: ^code}, unsafe_ctx} =
               RequestPipeline.execute_via_channels(
                 chain,
                 "eth_sendRawTransaction",
                 ["0x1234"],
                 ordinary_opts
               )

      assert unsafe_ctx.execution_envelope.dispatch_count == 1
      assert unsafe_ctx.retries == 0
    end
  end

  defp request(chain),
    do: RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [], options())

  defp options,
    do: %RequestOptions{
      profile: "public",
      strategy: :fastest,
      transport: :http,
      timeout_ms: 1_000
    }

  defp exploration_rows(chain),
    do:
      :ets.match_object(:lasso_instance_state, {{:routing_exploration, "public", chain, :_}, :_})

  defp set_behavior(provider, behavior) do
    [{pid, _}] = Registry.lookup(Lasso.Registry, {:http_provider, provider})
    :sys.replace_state(pid, &%{&1 | behavior: behavior})
  end

  defp seed_qualified(chain, provider) do
    instance = Catalog.lookup_instance_id("public", chain, provider)

    for n <- 1..3 do
      identity =
        AttemptIdentity.new(
          request_id: "seed",
          attempt_id: "seed-#{n}",
          profile: "public",
          chain_id: chain,
          upstream_instance_id: instance,
          transport: :http,
          route_generation: ConfigStore.route_generation(),
          circuit_scope: :broad,
          circuit_epoch: 1,
          execution_safety: :replay_safe,
          routing_intent: "fastest",
          workload_key: "client_basic",
          request_budget_ms: 1_000,
          candidate_admission_count: 1,
          dispatch_count: 1
        )

      fact = AttemptTerminal.Response.new(identity, :success, 10_000)

      assert :ok =
               AttemptProjection.apply_control(
                 AttemptProjection.new(fact, provider, "eth_blockNumber")
               )
    end
  end
end
