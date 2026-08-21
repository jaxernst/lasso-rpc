defmodule Lasso.RPC.RequestAggregateTest do
  use Lasso.Test.LassoIntegrationCase

  @moduletag :integration

  alias Lasso.Providers.Catalog

  alias Lasso.RPC.{
    AttemptIdentity,
    AttemptTerminal,
    RequestAggregate,
    RequestOptions,
    RequestPipeline,
    RequestTerminal
  }

  test "records exact origin-separated outcomes while bounding detail", %{chain: chain} do
    setup_providers([
      %{id: "aggregate-provider", priority: 1, behavior: :healthy, profile: "public"}
    ])

    success = success_terminal(chain)
    failure = failure_terminal(chain)

    assert {:ok,
            %{
              client: %{total: 0, successes: 0, sampled_out: 0},
              system: %{total: 0, successes: 0, sampled_out: 0}
            }} = RequestAggregate.snapshot("public", chain)

    client_results =
      Enum.map(1..300, fn _ ->
        RequestAggregate.record_and_reserve_detail(success, :client, 1_000)
      end)

    system_success_results =
      Enum.map(1..300, fn _ ->
        RequestAggregate.record_and_reserve_detail(success, :system, 1_000)
      end)

    assert Enum.frequencies(client_results) == %{detail: 256, aggregate_only: 44}
    assert Enum.frequencies(system_success_results) == %{detail: 256, aggregate_only: 44}
    assert :detail = RequestAggregate.record_and_reserve_detail(failure, :system, 1_000)
    assert :detail = RequestAggregate.record_and_reserve_detail(success, :client, 2_000)

    assert {:ok,
            %{
              generation: generation,
              client: %{
                total: 301,
                successes: 301,
                failures: 0,
                elapsed_us: 301_000,
                sampled_out: 44
              },
              system: %{
                total: 301,
                successes: 300,
                failures: 1,
                elapsed_us: 300_010,
                sampled_out: 44
              }
            }} = RequestAggregate.snapshot("public", chain)

    assert generation == Catalog.active_generation()
  end

  test "catalog publication replaces counters with the new generation", %{chain: chain} do
    setup_providers([
      %{id: "aggregate-provider", priority: 1, behavior: :healthy, profile: "public"}
    ])

    assert :detail =
             RequestAggregate.record_and_reserve_detail(success_terminal(chain), :client, 1_000)

    assert {:ok, %{generation: first_generation, client: %{total: 1}}} =
             RequestAggregate.snapshot("public", chain)

    :ok = Catalog.build_from_config()

    assert {:ok, %{generation: ^first_generation, client: %{total: 1}}} =
             RequestAggregate.snapshot("public", chain)

    setup_providers([
      %{id: "aggregate-provider-b", priority: 1, behavior: :healthy, profile: "public"}
    ])

    assert {:ok, %{generation: next_generation, client: %{total: 0}}} =
             RequestAggregate.snapshot("public", chain)

    assert next_generation > first_generation
  end

  test "concurrent producers preserve totals and never exceed the detail budget", %{chain: chain} do
    setup_providers([
      %{id: "aggregate-provider", priority: 1, behavior: :healthy, profile: "public"}
    ])

    terminal = success_terminal(chain)

    results =
      1..2_000
      |> Task.async_stream(
        fn _ -> RequestAggregate.record_and_reserve_detail(terminal, :client, 5_000) end,
        max_concurrency: 64,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    frequencies = Enum.frequencies(results)
    assert frequencies[:detail] <= 256
    assert frequencies[:detail] + frequencies[:aggregate_only] == 2_000

    assert {:ok,
            %{
              client: %{
                total: 2_000,
                successes: 2_000,
                failures: 0,
                sampled_out: sampled_out
              }
            }} = RequestAggregate.snapshot("public", chain)

    assert sampled_out == frequencies[:aggregate_only]
  end

  test "request pipeline records the final public outcome", %{chain: chain} do
    setup_providers([
      %{id: "aggregate-provider", priority: 1, behavior: :healthy, profile: "public"}
    ])

    opts = %RequestOptions{
      profile: "public",
      strategy: :fastest,
      transport: :http,
      timeout_ms: 5_000,
      request_origin: :client
    }

    assert {:ok, _value, _ctx} =
             RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [], opts)

    assert {:ok,
            %{
              client: %{total: 1, successes: 1, failures: 0, sampled_out: 0},
              system: %{total: 0}
            }} = RequestAggregate.snapshot("public", chain)
  end

  defp success_terminal(chain) do
    identity = identity(chain)
    attempt = AttemptTerminal.Response.new(identity, :success, 750)

    RequestTerminal.UpstreamResponse.new_runtime(attempt, 1_000, 1, 1, nil)
  end

  defp failure_terminal(chain) do
    RequestTerminal.LocalFailure.new(
      [
        request_id: "aggregate-local-failure",
        profile: "public",
        subject_token: nil,
        chain_id: chain,
        execution_safety: :replay_safe,
        routing_intent: "fastest",
        workload_key: "default",
        elapsed_us: 10,
        candidate_admission_count: 0,
        dispatch_count: 0,
        observed_at: nil
      ],
      :invalid_request
    )
  end

  defp identity(chain) do
    AttemptIdentity.new_runtime(%{
      request_id: "aggregate-request",
      attempt_id: "aggregate-attempt",
      profile: "public",
      subject_token: nil,
      chain_id: chain,
      upstream_instance_id: "aggregate-instance",
      transport: :http,
      route_generation: Catalog.active_generation(),
      circuit_scope: :broad,
      circuit_epoch: 1,
      execution_safety: :replay_safe,
      routing_intent: "fastest",
      workload_key: "default",
      request_budget_ms: 100,
      candidate_admission_count: 1,
      dispatch_count: 1
    })
  end
end
