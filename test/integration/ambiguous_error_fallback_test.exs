defmodule Lasso.RPC.AmbiguousErrorFallbackTest do
  use Lasso.Test.LassoIntegrationCase

  @moduletag :integration

  alias Lasso.Core.Support.CircuitBreaker.Snapshot
  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.Providers.Catalog
  alias Lasso.RPC.{RequestOptions, RequestPipeline}

  setup do
    setup_providers([
      %{id: "proven", priority: 1, behavior: :healthy, background_observations: false},
      %{id: "unproven", priority: 2, behavior: :healthy, background_observations: false}
    ])

    :ok
  end

  for {category, code} <- [{:unclassified_server_error, -32_000}, {:unknown_error, 35}] do
    @tag ambiguous_category: category, ambiguous_code: code
    test "#{category} falls back on safe reads without penalizing health", %{
      chain: chain,
      ambiguous_category: category,
      ambiguous_code: code
    } do
      set_behavior(
        "unproven",
        {:error,
         JError.new(code, "unfamiliar upstream failure",
           category: category,
           data: %{"detail" => "original upstream data"},
           retriable?: false,
           breaker_penalty?: false
         )}
      )

      instance = Catalog.lookup_instance_id("public", chain, "unproven")
      assert {:ok, before} = Snapshot.lookup({instance, :http})

      assert {:ok, _response, ctx} =
               RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [], options())

      assert ctx.executed_channel.provider_id == "proven"
      assert ctx.execution_envelope.dispatch_count == 2
      assert {:ok, after_snapshot} = Snapshot.lookup({instance, :http})
      assert after_snapshot.failure_count == before.failure_count

      assert {:error, %JError{code: ^code}, unsafe_ctx} =
               RequestPipeline.execute_via_channels(
                 chain,
                 "eth_sendRawTransaction",
                 ["0x1234"],
                 options()
               )

      assert unsafe_ctx.execution_envelope.dispatch_count == 1
      assert unsafe_ctx.retries == 0
    end
  end

  defp options,
    do: %RequestOptions{
      profile: "public",
      strategy: :priority,
      transport: :http,
      timeout_ms: 1_000,
      provider_override: "unproven",
      failover_on_override: true
    }

  defp set_behavior(provider, behavior) do
    [{pid, _}] = Registry.lookup(Lasso.Registry, {:http_provider, provider})
    :sys.replace_state(pid, &%{&1 | behavior: behavior})
  end
end
