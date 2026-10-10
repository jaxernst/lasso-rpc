defmodule Lasso.RPC.MethodNotFoundRoutingTest do
  use Lasso.Test.LassoIntegrationCase

  @moduletag timeout: 20_000

  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.RPC.{AttemptTerminal, Response}
  alias Lasso.Testing.MockProviderBehavior

  @profile "public"
  @unsupported_code -32_601
  @read_method "eth_getBalance"
  @read_params ["0x0000000000000000000000000000000000000001", "latest"]

  for outcome <- [:unsupported, :provider_failure, :quota_exhaustion] do
    test "HTTP #{outcome} exhaustion preserves the serving owners and an independent route", %{
      chain: chain
    } do
      control_chain = chain + 1_000_000_000

      on_exit(fn ->
        Lasso.ProfileChainSupervisor.stop_profile_chain(@profile, control_chain)
        Lasso.Config.ConfigStore.unregister_chain_runtime(@profile, control_chain)
        Lasso.Providers.Catalog.build_from_config()
      end)

      setup_providers([%{id: "control", behavior: healthy("control")}], chain: control_chain)

      owners =
        Map.new(
          [
            LassoWeb.Endpoint,
            Lasso.Config.ConfigStore,
            Lasso.Config.ConfigStore.Owner,
            Lasso.Providers.Catalog.Owner,
            Lasso.ProfileChainSupervisor,
            Lasso.Core.Request.ByteBudget,
            Lasso.Core.Transport.UpstreamAdmission
          ],
          fn owner ->
            pid = Process.whereis(owner)
            assert is_pid(pid)
            {owner, pid}
          end
        )

      assert_http_serving(control_chain, owners)

      setup_providers([
        %{id: "unsupported", behavior: unsupported("unsupported")},
        %{id: "other", behavior: http_other(unquote(outcome))}
      ])

      assert %{"id" => 1, "error" => error} = http_read(chain)
      assert upstream_calls("unsupported", @read_method) == 1
      assert upstream_calls("other", @read_method) == 1

      if unquote(outcome) == :unsupported do
        assert %{"code" => @unsupported_code, "message" => message, "data" => data} = error
        assert data["provider"] in ["unsupported", "other"]
        assert message == "unsupported by #{data["provider"]}"
      else
        refute error["code"] == @unsupported_code
      end

      assert_http_serving(control_chain, owners)
    end
  end

  describe "replay-safe reads" do
    test "continue past an unsupported provider inside the dispatch budget", %{chain: chain} do
      setup_providers([
        %{id: "unsupported", priority: 1, behavior: unsupported("unsupported")},
        %{id: "healthy", priority: 2, behavior: healthy("healthy")}
      ])

      assert {:ok, %Response.Success{} = response, ctx} = read(chain)
      Response.Success.release_capacity(response, :test_complete)

      assert ctx.execution_envelope.dispatch_count == 2
      assert upstream_calls("unsupported", @read_method) == 1
      assert upstream_calls("healthy", @read_method) == 1

      assert [
               %{
                 outcome: :error,
                 category: :method_not_found,
                 channel: %{provider_id: "unsupported"}
               },
               %{outcome: :success, channel: %{provider_id: "healthy"}}
             ] = ctx.attempted_channels
    end

    test "load-balanced picks that land on an unsupported provider reach the next one",
         %{chain: chain} do
      setup_providers([
        %{id: "unsupported", priority: 1, behavior: unsupported("unsupported")},
        %{id: "healthy", priority: 1, behavior: healthy("healthy")}
      ])

      for _request <- 1..16 do
        assert {:ok, %Response.Success{} = response, ctx} =
                 read(chain, strategy: :load_balanced)

        Response.Success.release_capacity(response, :test_complete)
        assert ctx.execution_envelope.dispatch_count in 1..2
      end

      assert upstream_calls("unsupported", @read_method) > 0
    end

    test "answer -32601 when every upstream is unsupported, past the dispatch budget",
         %{chain: chain} do
      setup_providers(
        for index <- 1..4 do
          id = "unsupported-#{index}"
          %{id: id, priority: index, behavior: unsupported(id)}
        end
      )

      assert {:error, %JError{} = error, ctx} = read(chain)

      assert error.code == @unsupported_code
      assert error.category == :method_not_found
      assert error.message == "unsupported by unsupported-3"
      assert error.data == %{"provider" => "unsupported-3"}
      assert ctx.execution_envelope.dispatch_count == 3
    end
  end

  describe "unknown-safety methods" do
    test "stay single-dispatch and return the upstream -32601", %{chain: chain} do
      setup_providers([
        %{id: "unsupported", priority: 1, behavior: unsupported("unsupported")},
        %{id: "healthy", priority: 2, behavior: healthy("healthy")}
      ])

      assert {:error, %JError{} = error, ctx} = execute(chain, "vendor_futureMethod", [])

      assert error.code == @unsupported_code
      assert error.category == :method_not_found
      assert error.message == "unsupported by unsupported"
      assert ctx.execution_envelope.dispatch_count == 1
      assert upstream_calls("healthy", "vendor_futureMethod") == 0
    end
  end

  describe "pre-dispatch failures" do
    test "after a rejection never promote the reduced rejection", %{chain: chain} do
      setup_providers([
        %{id: "unsupported", priority: 1, behavior: unsupported("unsupported")},
        %{
          id: "unreachable",
          priority: 2,
          behavior: healthy("unreachable"),
          predispatch_failure: :pool_unavailable
        }
      ])

      assert {:error, %JError{} = error, ctx} = read(chain)

      assert %AttemptTerminal.PredispatchFailure{} = ctx.terminal_attempt_fact
      refute error.code == @unsupported_code
      assert error.category == :provider_error
      assert ctx.execution_envelope.dispatch_count == 1
      assert upstream_calls("unreachable", @read_method) == 0
    end
  end

  describe "transaction submission" do
    test "keeps its single dispatch after an upstream -32601", %{chain: chain} do
      setup_providers([
        %{id: "unsupported", priority: 1, behavior: unsupported("unsupported")},
        %{id: "healthy", priority: 2, behavior: healthy("healthy")}
      ])

      assert {:error, %JError{category: :method_not_found}, ctx} =
               execute(chain, "eth_sendRawTransaction", ["0x02"])

      assert ctx.execution_envelope.dispatch_count == 1
      assert upstream_calls("healthy", "eth_sendRawTransaction") == 0
    end
  end

  describe "mixed outcomes" do
    test "a rejection at the dispatch budget does not hide an earlier provider failure", %{
      chain: chain
    } do
      setup_providers([
        %{id: "failed", priority: 1, behavior: watched(failing(:provider_failure), "failed")},
        %{id: "unsupported-2", priority: 2, behavior: unsupported("unsupported-2")},
        %{id: "unsupported-3", priority: 3, behavior: unsupported("unsupported-3")},
        %{id: "healthy", priority: 4, behavior: healthy("healthy")}
      ])

      assert {:error, %JError{category: :provider_error} = error, ctx} = read(chain)
      refute error.code == @unsupported_code
      assert ctx.execution_envelope.dispatch_count == 3
      assert upstream_calls("failed", @read_method) == 1
      assert upstream_calls("unsupported-2", @read_method) == 1
      assert upstream_calls("unsupported-3", @read_method) == 1
      assert upstream_calls("healthy", @read_method) == 0
    end

    for kind <- [:provider_failure, :quota_exhaustion, :attempt_timeout] do
      test "unsupported then #{kind} is not reported as method-not-found", %{chain: chain} do
        assert_mixed_not_method_not_found(chain, unquote(kind), :unsupported_first)
      end

      test "#{kind} then unsupported is not reported as method-not-found", %{chain: chain} do
        assert_mixed_not_method_not_found(chain, unquote(kind), :unsupported_last)
      end
    end

    test "a request that reaches no upstream is not reported as method-not-found",
         %{chain: chain} do
      assert {:error, %JError{} = error, ctx} = read(chain)

      assert error.category == :provider_error
      assert ctx.execution_envelope.dispatch_count == 0
    end
  end

  defp assert_mixed_not_method_not_found(chain, kind, order) do
    {unsupported_priority, other_priority} =
      if order == :unsupported_first, do: {1, 2}, else: {2, 1}

    setup_providers([
      %{id: "unsupported", priority: unsupported_priority, behavior: unsupported("unsupported")},
      %{id: "other", priority: other_priority, behavior: failing(kind)}
    ])

    assert {:error, %JError{} = error, ctx} = read(chain, timeout_ms: 1_000)

    refute error.code == @unsupported_code
    refute error.category == :method_not_found
    assert ctx.execution_envelope.dispatch_count == 2
    assert Enum.any?(ctx.attempted_channels, &(&1.category == failure_category(kind)))
  end

  defp failure_category(:provider_failure), do: :server_error
  defp failure_category(:quota_exhaustion), do: :rate_limit
  defp failure_category(:attempt_timeout), do: :deadline_expired

  defp failing(:provider_failure), do: :always_fail

  defp failing(:quota_exhaustion),
    do: {:error, %JError{code: -32_005, message: "Rate limit exceeded"}}

  defp failing(:attempt_timeout) do
    {:conditional,
     fn _, _, _ ->
       Process.sleep(3_000)
       {:ok, "0x1"}
     end}
  end

  defp unsupported(provider_id) do
    watched(
      {:error,
       %JError{
         code: @unsupported_code,
         message: "unsupported by #{provider_id}",
         data: %{"provider" => provider_id}
       }},
      provider_id
    )
  end

  defp http_other(:unsupported), do: unsupported("other")
  defp http_other(outcome), do: watched(failing(outcome), "other")

  defp healthy(provider_id),
    do: watched({:conditional, fn _, _, _ -> {:ok, "0x1"} end}, provider_id)

  defp watched(behavior, provider_id) do
    observer = self()

    {:conditional,
     fn method, params, state ->
       send(observer, {:upstream_call, provider_id, method})
       MockProviderBehavior.execute_behavior(behavior, method, params, state)
     end}
  end

  defp upstream_calls(provider_id, method) do
    Stream.repeatedly(fn ->
      receive do
        {:upstream_call, ^provider_id, ^method} -> :call
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(& &1)
    |> length()
  end

  defp read(chain, opts \\ []), do: execute(chain, @read_method, @read_params, opts)

  defp assert_http_serving(chain, owners) do
    assert %{"id" => 1, "result" => "0x1"} = http_read(chain)
    assert upstream_calls("control", @read_method) == 1
    assert %{"status" => "healthy"} = http_json(:get, "/api/health")

    for {owner, pid} <- owners do
      assert Process.alive?(pid)
      assert Process.whereis(owner) == pid
    end
  end

  defp http_read(chain), do: http_json(:post, "/rpc/#{chain}")

  defp http_json(method, path) do
    {:ok, _} = Application.ensure_all_started(:inets)
    port = LassoWeb.Endpoint.config(:http)[:port]
    url = String.to_charlist("http://127.0.0.1:#{port}#{path}")
    body = Jason.encode!(%{jsonrpc: "2.0", method: @read_method, params: @read_params, id: 1})
    request = if method == :get, do: {url, []}, else: {url, [], ~c"application/json", body}

    assert {:ok, {{_, 200, _}, _, response}} =
             :httpc.request(method, request, [timeout: 5_000], [])

    Jason.decode!(to_string(response))
  end

  defp execute(chain, method, params, opts \\ []) do
    RequestPipeline.execute_via_channels(
      chain,
      method,
      params,
      %RequestOptions{
        profile: @profile,
        strategy: Keyword.get(opts, :strategy, :priority),
        transport: :http,
        timeout_ms: Keyword.get(opts, :timeout_ms, 2_000)
      }
    )
  end
end
