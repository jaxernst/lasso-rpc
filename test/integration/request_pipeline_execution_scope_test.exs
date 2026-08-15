defmodule Lasso.RPC.RequestPipelineExecutionScopeTest do
  use Lasso.Test.LassoIntegrationCase

  @moduletag timeout: 10_000

  alias Lasso.Core.Request.{ExecutionScope, RequestOwner}

  alias Lasso.Core.Support.CircuitBreaker
  alias Lasso.Core.Support.CircuitBreaker.Snapshot
  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.RPC.{RequestOptions, RequestPipeline, Response, StrategyContext}

  defmodule BlockingSelectionStrategy do
    @behaviour Lasso.RPC.Strategy

    @impl true
    def prepare_context(_profile, chain_id, _method, timeout) do
      StrategyContext.new(chain_id, timeout)
    end

    @impl true
    def rank_channels(channels, _method, _context, _profile, _chain_id) do
      {observer, token} = Application.fetch_env!(:lasso, :execution_scope_selection_probe)
      send(observer, {:selection_blocked, self(), token})

      receive do
        {:continue_selection, ^token} -> channels
      end
    end
  end

  setup do
    original_registry = Application.get_env(:lasso, :strategy_registry)
    original_probe = Application.get_env(:lasso, :execution_scope_selection_probe)

    registry =
      (original_registry || Lasso.RPC.Strategies.Registry.default_registry())
      |> Map.put(:execution_scope_probe, BlockingSelectionStrategy)

    Application.put_env(:lasso, :strategy_registry, registry)

    on_exit(fn ->
      restore_env(:strategy_registry, original_registry)
      restore_env(:execution_scope_selection_probe, original_probe)
    end)

    :ok
  end

  test "execute_owned rejects a scope bound to another process", %{chain: chain} do
    other_owner = spawn(fn -> Process.sleep(:infinity) end)
    scope = ExecutionScope.local(other_owner)

    assert_raise ArgumentError, fn ->
      RequestPipeline.execute_owned(
        scope,
        chain,
        "eth_blockNumber",
        [],
        request_options(:priority)
      )
    end

    Process.exit(other_owner, :kill)
  end

  test "the public local-owner entry creates no caller monitor", %{chain: chain} do
    before = Process.info(self(), :monitors)

    assert {:error, %JError{}, _ctx} =
             RequestPipeline.execute_via_channels(
               chain,
               "eth_blockNumber",
               [],
               request_options(:priority)
             )

    assert Process.info(self(), :monitors) == before
  end

  test "an already-dead caller prevents selection and transport", %{chain: chain} do
    setup_providers([%{id: "only", priority: 1, behavior: :healthy}])
    token = make_ref()
    Application.put_env(:lasso, :execution_scope_selection_probe, {self(), token})
    set_provider_behavior("only", transport_probe(self(), :transport_started))

    caller = spawn(fn -> :ok end)
    await_process_down(caller)
    scope = ExecutionScope.monitored(self(), caller, deadline_after(1_000))

    assert {:error, %JError{category: :cancelled}, ctx} =
             RequestPipeline.execute_owned(
               scope,
               chain,
               "eth_blockNumber",
               [],
               request_options(:execution_scope_probe)
             )

    assert ctx.execution_envelope.candidate_admission_count == 0
    assert ctx.execution_envelope.dispatch_count == 0
    refute_receive {:selection_blocked, _owner, ^token}
    refute_receive :transport_started
  end

  test "an explicit null JSON-RPC id is forwarded without an internal replacement", %{
    chain: chain
  } do
    setup_providers([%{id: "only", priority: 1, behavior: :healthy}])

    assert {:ok, %Response.Success{id: nil}, _ctx} =
             RequestPipeline.execute_via_channels(
               chain,
               "eth_blockNumber",
               [],
               %RequestOptions{
                 profile: "public",
                 strategy: :priority,
                 transport: :http,
                 timeout_ms: 1_000,
                 jsonrpc_id: nil,
                 jsonrpc_id_present?: true
               }
             )
  end

  test "caller death during selection stops before admission and uses one monitor", %{
    chain: chain
  } do
    setup_providers([%{id: "only", priority: 1, behavior: :healthy}])
    token = make_ref()
    Application.put_env(:lasso, :execution_scope_selection_probe, {self(), token})
    set_provider_behavior("only", transport_probe(self(), :transport_started))

    caller = spawn(fn -> Process.sleep(:infinity) end)
    owner = start_owned_request(self(), caller, chain, :execution_scope_probe)

    assert_receive {:selection_blocked, ^owner, ^token}
    assert caller_monitor_count(owner, caller) == 1
    Process.exit(caller, :kill)
    send(owner, {:continue_selection, token})

    assert_receive {:owned_result, ^owner, {:error, %JError{category: :cancelled}, ctx}}
    assert ctx.execution_envelope.candidate_admission_count == 0
    assert ctx.execution_envelope.dispatch_count == 0
    refute_receive :transport_started
    await_process_down(owner)
  end

  test "caller death between candidates prevents the next transport", %{chain: chain} do
    setup_providers([
      %{id: "first", priority: 1, behavior: :healthy},
      %{id: "second", priority: 2, behavior: :healthy}
    ])

    set_provider_behavior("first", blocking_failure(self()))
    set_provider_behavior("second", transport_probe(self(), :second_transport_started))

    caller = spawn(fn -> Process.sleep(:infinity) end)
    owner = start_owned_request(self(), caller, chain, :priority)

    assert_receive {:first_transport_blocked, provider}
    assert :erlang.suspend_process(owner)
    send(provider, :release_first_failure)

    await_mailbox(owner, fn messages ->
      Enum.any?(messages, &match?({_ref, %RequestOwner.AttemptCompletion{}}, &1))
    end)

    Process.exit(caller, :kill)
    assert :erlang.resume_process(owner)

    assert_receive {:owned_result, ^owner, {:error, %JError{category: :cancelled}, ctx}}
    assert ctx.execution_envelope.candidate_admission_count == 1
    assert ctx.execution_envelope.dispatch_count == 1
    refute_receive :second_transport_started
    await_process_down(owner)
  end

  test "caller death while breaker admission is blocked prevents transport authorization", %{
    chain: chain
  } do
    setup_providers([%{id: "only", priority: 1, behavior: :healthy}])
    set_provider_behavior("only", transport_probe(self(), :transport_started))

    instance_id = Lasso.Providers.Catalog.lookup_instance_id("public", chain, "only")
    breaker_id = {instance_id, :http}
    breaker_pid = GenServer.whereis(CircuitBreaker.via_name(breaker_id))
    assert is_pid(breaker_pid)

    assert {:ok, snapshot} = Snapshot.lookup(breaker_id)
    Snapshot.put(%{snapshot | control_health: :degraded})
    assert :ok = :sys.suspend(breaker_pid)

    on_exit(fn ->
      if Process.alive?(breaker_pid), do: :sys.resume(breaker_pid)
    end)

    caller = spawn(fn -> Process.sleep(:infinity) end)
    owner = start_owned_request(self(), caller, chain, :priority)

    await_mailbox(breaker_pid, fn messages ->
      Enum.any?(messages, fn
        {:"$gen_call", _from,
         {:admit_exceptional, _token, ^owner, _generation, _epoch, _deadline}} ->
          true

        _message ->
          false
      end)
    end)

    Process.exit(caller, :kill)
    assert :ok = :sys.resume(breaker_pid)

    assert_receive {:owned_result, ^owner, {:error, %JError{category: :cancelled}, ctx}}
    assert ctx.execution_envelope.candidate_admission_count == 1
    assert ctx.execution_envelope.dispatch_count == 0
    refute_receive :transport_started
    await_process_down(owner)
  end

  defp start_owned_request(observer, caller, chain, strategy) do
    spawn(fn ->
      scope = ExecutionScope.monitored(self(), caller, deadline_after(2_000))

      result =
        RequestPipeline.execute_owned(
          scope,
          chain,
          "eth_blockNumber",
          [],
          request_options(strategy)
        )

      send(observer, {:owned_result, self(), result})
    end)
  end

  defp request_options(strategy) do
    %RequestOptions{
      profile: "public",
      strategy: strategy,
      transport: :http,
      timeout_ms: 2_000
    }
  end

  defp blocking_failure(observer) do
    {:conditional,
     fn _method, _params, _state ->
       send(observer, {:first_transport_blocked, self()})

       receive do
         :release_first_failure ->
           {:error,
            JError.new(-32_002, "first failed",
              category: :server_error,
              retriable?: true,
              breaker_penalty?: true
            )}
       end
     end}
  end

  defp transport_probe(observer, message) do
    {:conditional,
     fn method, params, _state ->
       send(observer, message)
       Lasso.Testing.MockProviderBehavior.execute_behavior(:healthy, method, params, %{})
     end}
  end

  defp set_provider_behavior(provider_id, behavior) do
    [{provider, _value}] = Registry.lookup(Lasso.Registry, {:http_provider, provider_id})
    :sys.replace_state(provider, &%{&1 | behavior: behavior})
  end

  defp caller_monitor_count(owner, caller) do
    {:monitors, monitors} = Process.info(owner, :monitors)
    Enum.count(monitors, &(&1 == {:process, caller}))
  end

  defp await_process_down(pid) do
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 1_000
  end

  defp await_mailbox(pid, predicate, timeout_ms \\ 1_000) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_await_mailbox(pid, predicate, deadline_ms)
  end

  defp do_await_mailbox(pid, predicate, deadline_ms) do
    messages =
      case Process.info(pid, :messages) do
        {:messages, messages} -> messages
        nil -> flunk("process exited before reaching the expected mailbox state")
      end

    cond do
      predicate.(messages) ->
        messages

      System.monotonic_time(:millisecond) >= deadline_ms ->
        flunk("expected mailbox state did not arrive")

      true ->
        receive do
        after
          1 -> do_await_mailbox(pid, predicate, deadline_ms)
        end
    end
  end

  defp deadline_after(milliseconds) do
    System.monotonic_time(:microsecond) + milliseconds * 1_000
  end

  defp restore_env(key, nil), do: Application.delete_env(:lasso, key)
  defp restore_env(key, value), do: Application.put_env(:lasso, key, value)
end
