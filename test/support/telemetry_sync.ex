defmodule Lasso.Test.TelemetrySync do
  @moduledoc """
  Deterministic test synchronization using telemetry events.

  This module replaces timing-based assertions (Process.sleep) with event-driven
  synchronization. Tests wait for actual telemetry events rather than arbitrary
  time delays, making tests both faster and more reliable.

  ## Usage

      # Wait for circuit breaker to open
      {:ok, meta} = TelemetrySync.wait_for_circuit_breaker_open("provider_id", :http)

      # Wait for any telemetry event
      {:ok, measurements, metadata} =
        TelemetrySync.wait_for_event([:lasso, :subs, :failover, :completed])

      # Wait with custom matching
      {:ok, meta} = TelemetrySync.wait_for_event(
        [:lasso, :rpc, :request, :stop],
        match: %{method: "eth_blockNumber"}
      )
  """

  @default_timeout 5_000

  @doc """
  Attaches a telemetry collector (API-compatible with Lasso.Testing.TelemetrySync).

  This is an alias for `start_collector/2` but returns `{:ok, ref}` tuple for compatibility.

  ## Example

      {:ok, collector} = TelemetrySync.attach_collector([:lasso, :websocket, :connected],
        match: [provider_id: "test_id"],
        count: 2
      )

      # Trigger actions...
      {:ok, _m, meta} = TelemetrySync.await_event(collector)
  """
  @spec attach_collector([atom()], keyword()) :: {:ok, reference()}
  def attach_collector(event_name, opts \\ []) do
    ref = start_collector(event_name, opts)
    {:ok, ref}
  end

  @doc """
  Starts collecting telemetry events in the background.

  This attaches a handler BEFORE triggering actions, ensuring no events are missed.
  Use this when events may fire faster than `wait_for_event/2` can attach.

  Returns a collector reference to be used with `await_event/2`.

  ## Example

      # Start collecting before triggering action
      collector = TelemetrySync.start_collector([:lasso, :subs, :failover, :initiated],
        match: %{chain: chain}
      )

      # Trigger the action that emits events
      MockWSProvider.simulate_provider_failure(chain, "primary")

      # Now wait for the event
      {:ok, _measurements, metadata} = TelemetrySync.await_event(collector)
  """
  @spec start_collector([atom()], keyword()) :: reference()
  def start_collector(event_name, opts \\ []) do
    match_map = Keyword.get(opts, :match, %{})
    predicate = Keyword.get(opts, :predicate)

    test_pid = self()
    ref = make_ref()
    handler_id = {__MODULE__, ref, :erlang.unique_integer()}

    :telemetry.attach(
      handler_id,
      event_name,
      fn ^event_name, measurements, metadata, _config ->
        if should_send_event?(measurements, metadata, match_map, predicate) do
          send(test_pid, {ref, :event, measurements, metadata})
        end
      end,
      nil
    )

    ref
  end

  @doc """
  Waits for an event from a pre-attached collector.

  Use this after `start_collector/2` to wait for events without race conditions.

  ## Options

  - `:timeout` - Maximum time to wait in milliseconds (default: 5000)

  ## Returns

  - `{:ok, measurements, metadata}` when event received
  - `{:error, :timeout}` if timeout exceeded

  ## Example

      collector = start_collector([:lasso, :subs, :failover, :initiated])
      trigger_failover()
      {:ok, _m, meta} = await_event(collector, timeout: 5000)
  """
  @spec await_event(reference(), keyword()) :: {:ok, map(), map()} | {:error, :timeout}
  def await_event(ref, opts \\ []) when is_reference(ref) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    # The collector remains active after await_event returns, allowing multiple
    # await_event calls on the same collector. The handler is only detached when
    # stop_collector/1 is explicitly called or the test process exits.
    receive do
      {^ref, :event, measurements, metadata} ->
        {:ok, measurements, metadata}
    after
      timeout ->
        {:error, :timeout}
    end
  end

  @doc """
  Stops a collector and detaches its handler.

  Call this to clean up if you don't plan to await the event.
  """
  @spec stop_collector(reference()) :: :ok
  def stop_collector(ref) when is_reference(ref) do
    detach_collector_handler(ref)
  end

  @doc """
  Stops all collectors (detaches all TelemetrySync handlers).

  This is useful for test cleanup to prevent handler pollution between tests.
  Call this in on_exit callbacks or at the end of tests that create many collectors.
  """
  @spec stop_all_collectors() :: :ok
  def stop_all_collectors do
    handlers = :telemetry.list_handlers([])

    Enum.each(handlers, fn handler ->
      case handler.id do
        {__MODULE__, _ref, _unique_int} ->
          :telemetry.detach(handler.id)

        _ ->
          :ok
      end
    end)

    :ok
  end

  # Helper to detach handler by finding it via the ref
  defp detach_collector_handler(ref) do
    # Find handler matching our ref
    handlers = :telemetry.list_handlers([])

    matching_handler =
      Enum.find(handlers, fn handler ->
        case handler.id do
          {__MODULE__, ^ref, _unique_int} -> true
          _ -> false
        end
      end)

    case matching_handler do
      %{id: handler_id} -> :telemetry.detach(handler_id)
      nil -> :ok
    end
  end

  @doc """
  Waits for a specific telemetry event with optional metadata matching.

  WARNING: This function attaches the handler AFTER being called, which creates
  a race condition for fast-executing code (<10ms). For events that fire quickly,
  use `start_collector/2` + `await_event/2` instead.

  ## Options

  - `:timeout` - Maximum time to wait in milliseconds (default: 5000)
  - `:match` - Map of metadata fields that must match
  - `:predicate` - Custom function to filter events: `fn measurements, metadata -> boolean end`

  ## Returns

  - `{:ok, measurements, metadata}` when event received
  - `{:error, :timeout}` if timeout exceeded

  ## Examples

      # Wait for any circuit breaker open event
      {:ok, _meas, meta} = wait_for_event([:lasso, :circuit_breaker, :open])

      # Wait for specific provider's circuit breaker
      {:ok, _meas, meta} = wait_for_event(
        [:lasso, :circuit_breaker, :open],
        match: %{provider_id: "alchemy"}
      )

      # Wait with custom predicate
      {:ok, _meas, meta} = wait_for_event(
        [:lasso, :rpc, :request, :stop],
        predicate: fn _m, meta -> meta.status == :success end
      )
  """
  @spec wait_for_event([atom()], keyword()) ::
          {:ok, map(), map()} | {:error, :timeout}
  def wait_for_event(event_name, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    match_map = Keyword.get(opts, :match, %{})
    predicate = Keyword.get(opts, :predicate)

    test_pid = self()
    ref = make_ref()
    handler_id = {__MODULE__, ref, :erlang.unique_integer()}

    :telemetry.attach(
      handler_id,
      event_name,
      fn ^event_name, measurements, metadata, _config ->
        if should_send_event?(measurements, metadata, match_map, predicate) do
          send(test_pid, {ref, :event, measurements, metadata})
        end
      end,
      nil
    )

    result =
      receive do
        {^ref, :event, measurements, metadata} ->
          {:ok, measurements, metadata}
      after
        timeout ->
          {:error, :timeout}
      end

    :telemetry.detach(handler_id)
    result
  end

  @doc """
  Waits for multiple telemetry events to occur in any order.

  Returns when all events have been received or timeout is exceeded.

  ## Options

  - `:timeout` - Maximum time to wait for all events (default: 5000)

  ## Returns

  - `{:ok, events}` where events is a list of `{event_name, measurements, metadata}` tuples
  - `{:error, :timeout, received}` where received is the partial list of events received

  ## Example

      {:ok, events} = wait_for_events([
        [:lasso, :circuit_breaker, :open],
        [:lasso, :subs, :failover, :initiated]
      ])
  """
  @spec wait_for_events([[atom()]], keyword()) ::
          {:ok, [{[atom()], map(), map()}]} | {:error, :timeout, [{[atom()], map(), map()}]}
  def wait_for_events(event_names, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    deadline = System.monotonic_time(:millisecond) + timeout

    wait_for_events_recursive(event_names, [], deadline)
  end

  defp wait_for_events_recursive([], collected, _deadline) do
    {:ok, Enum.reverse(collected)}
  end

  defp wait_for_events_recursive([event_name | rest], collected, deadline) do
    remaining_timeout = deadline - System.monotonic_time(:millisecond)

    if remaining_timeout <= 0 do
      {:error, :timeout, Enum.reverse(collected)}
    else
      case wait_for_event(event_name, timeout: remaining_timeout) do
        {:ok, measurements, metadata} ->
          wait_for_events_recursive(rest, [{event_name, measurements, metadata} | collected], deadline)

        {:error, :timeout} ->
          {:error, :timeout, Enum.reverse(collected)}
      end
    end
  end

  @doc """
  Waits for a circuit breaker to open for a specific provider and transport.

  This is a convenience wrapper around `wait_for_event/2` for the common case
  of waiting for circuit breakers to open.

  ## Example

      {:ok, metadata} = wait_for_circuit_breaker_open("alchemy", :http)
      assert metadata.provider_id == "alchemy"
  """
  @spec wait_for_circuit_breaker_open(String.t(), atom(), non_neg_integer()) ::
          {:ok, map()} | {:error, :timeout}
  def wait_for_circuit_breaker_open(provider_id, transport, timeout \\ @default_timeout) do
    case wait_for_event(
           [:lasso, :circuit_breaker, :open],
           timeout: timeout,
           match: %{provider_id: provider_id}
         ) do
      {:ok, _measurements, metadata} -> {:ok, metadata}
      {:error, :timeout} -> {:error, :timeout}
    end
  end

  @doc """
  Waits for a circuit breaker to close for a specific provider.

  ## Example

      {:ok, metadata} = wait_for_circuit_breaker_close("alchemy", :http)
  """
  @spec wait_for_circuit_breaker_close(String.t(), atom(), non_neg_integer()) ::
          {:ok, map()} | {:error, :timeout}
  def wait_for_circuit_breaker_close(provider_id, transport, timeout \\ @default_timeout) do
    case wait_for_event(
           [:lasso, :circuit_breaker, :close],
           timeout: timeout,
           match: %{provider_id: provider_id}
         ) do
      {:ok, _measurements, metadata} -> {:ok, metadata}
      {:error, :timeout} -> {:error, :timeout}
    end
  end

  @doc """
  Waits for a circuit breaker to enter half-open state.

  ## Example

      {:ok, metadata} = wait_for_circuit_breaker_half_open("alchemy", :http)
  """
  @spec wait_for_circuit_breaker_half_open(String.t(), atom(), non_neg_integer()) ::
          {:ok, map()} | {:error, :timeout}
  def wait_for_circuit_breaker_half_open(provider_id, transport, timeout \\ @default_timeout) do
    case wait_for_event(
           [:lasso, :circuit_breaker, :half_open],
           timeout: timeout,
           match: %{provider_id: provider_id}
         ) do
      {:ok, _measurements, metadata} -> {:ok, metadata}
      {:error, :timeout} -> {:error, :timeout}
    end
  end

  @doc """
  Waits for an upstream subscription to be established.

  This waits for [:lasso, :subs, :upstream, :subscribe] which is emitted when
  UpstreamSubscriptionPool successfully subscribes to a provider.

  ## Example

      {:ok, sub_id} = subscribe_client(chain, self(), {:newHeads})
      {:ok, meta} = wait_for_subscription_established(chain, {:newHeads})
      assert meta.provider_id != nil
  """
  @spec wait_for_subscription_established(String.t(), tuple(), non_neg_integer()) ::
          {:ok, map()} | {:error, :timeout}
  def wait_for_subscription_established(chain, key, timeout \\ @default_timeout) do
    case wait_for_event(
           [:lasso, :subs, :upstream, :subscribe],
           timeout: timeout,
           match: %{chain: chain, key: key}
         ) do
      {:ok, _measurements, metadata} -> {:ok, metadata}
      {:error, :timeout} -> {:error, :timeout}
    end
  end

  @doc """
  Waits for a subscription failover to complete.

  ## Example

      {:ok, meta} = wait_for_failover_completed("ethereum", {:newHeads})
      assert meta.chain == "ethereum"
  """
  @spec wait_for_failover_completed(String.t(), tuple(), non_neg_integer()) ::
          {:ok, map()} | {:error, :timeout}
  def wait_for_failover_completed(chain, key, timeout \\ @default_timeout) do
    case wait_for_event(
           [:lasso, :subs, :failover, :completed],
           timeout: timeout,
           match: %{chain: chain, key: key}
         ) do
      {:ok, measurements, metadata} -> {:ok, Map.merge(metadata, measurements)}
      {:error, :timeout} -> {:error, :timeout}
    end
  end

  @doc """
  Waits for a subscription failover to be initiated.

  ## Example

      {:ok, meta} = wait_for_failover_initiated("ethereum", {:newHeads})
  """
  @spec wait_for_failover_initiated(String.t(), tuple(), non_neg_integer()) ::
          {:ok, map()} | {:error, :timeout}
  def wait_for_failover_initiated(chain, key, timeout \\ @default_timeout) do
    case wait_for_event(
           [:lasso, :subs, :failover, :initiated],
           timeout: timeout,
           match: %{chain: chain, key: key}
         ) do
      {:ok, _measurements, metadata} -> {:ok, metadata}
      {:error, :timeout} -> {:error, :timeout}
    end
  end

  @doc """
  Waits for a provider to start cooldown period.

  ## Example

      {:ok, meta} = wait_for_provider_cooldown_start("alchemy")
  """
  @spec wait_for_provider_cooldown_start(String.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, :timeout}
  def wait_for_provider_cooldown_start(provider_id, timeout \\ @default_timeout) do
    case wait_for_event(
           [:lasso, :provider, :cooldown, :start],
           timeout: timeout,
           match: %{provider_id: provider_id}
         ) do
      {:ok, _measurements, metadata} -> {:ok, metadata}
      {:error, :timeout} -> {:error, :timeout}
    end
  end

  @doc """
  Waits for a provider cooldown to end.

  ## Example

      {:ok, meta} = wait_for_provider_cooldown_end("alchemy")
  """
  @spec wait_for_provider_cooldown_end(String.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, :timeout}
  def wait_for_provider_cooldown_end(provider_id, timeout \\ @default_timeout) do
    case wait_for_event(
           [:lasso, :provider, :cooldown, :end],
           timeout: timeout,
           match: %{provider_id: provider_id}
         ) do
      {:ok, _measurements, metadata} -> {:ok, metadata}
      {:error, :timeout} -> {:error, :timeout}
    end
  end

  @doc """
  Waits for an RPC request to complete.

  ## Options

  - `:method` - Filter by JSON-RPC method name
  - `:status` - Filter by completion status (:success, :error, etc.)
  - `:provider_id` - Filter by provider ID

  ## Example

      {:ok, measurements} = wait_for_request_completed(
        method: "eth_blockNumber",
        status: :success
      )
  """
  @spec wait_for_request_completed(keyword()) ::
          {:ok, map()} | {:error, :timeout}
  def wait_for_request_completed(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    filter_opts = Keyword.drop(opts, [:timeout])

    match_map =
      filter_opts
      |> Enum.into(%{})

    case wait_for_event(
           [:lasso, :rpc, :request, :stop],
           timeout: timeout,
           match: match_map
         ) do
      {:ok, measurements, metadata} -> {:ok, Map.merge(metadata, measurements)}
      {:error, :timeout} -> {:error, :timeout}
    end
  end

  @doc """
  Collects all events of a specific type for a duration.

  Returns all matching events received within the timeout period.

  ## Options

  - `:timeout` - Duration to collect events (default: 1000ms)
  - `:match` - Map of metadata fields that must match

  ## Returns

  List of `{measurements, metadata}` tuples for all matching events.

  ## Example

      # Collect all circuit breaker opens in the next second
      events = collect_events([:lasso, :circuit_breaker, :open], timeout: 1000)
      assert length(events) >= 2
  """
  @spec collect_events([atom()], keyword()) :: [{map(), map()}]
  def collect_events(event_name, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 1000)
    match_map = Keyword.get(opts, :match, %{})

    test_pid = self()
    ref = make_ref()
    handler_id = {__MODULE__, ref, :erlang.unique_integer()}

    :telemetry.attach(
      handler_id,
      event_name,
      fn ^event_name, measurements, metadata, _config ->
        if metadata_matches?(metadata, match_map) do
          send(test_pid, {ref, :event, measurements, metadata})
        end
      end,
      nil
    )

    # Collect events for the duration
    Process.send_after(self(), {ref, :done}, timeout)
    events = collect_events_loop(ref, [])

    :telemetry.detach(handler_id)
    events
  end

  defp collect_events_loop(ref, acc) do
    receive do
      {^ref, :event, measurements, metadata} ->
        collect_events_loop(ref, [{measurements, metadata} | acc])

      {^ref, :done} ->
        Enum.reverse(acc)
    end
  end

  # Private helpers

  defp should_send_event?(measurements, metadata, match_map, predicate) do
    matches_map = metadata_matches?(metadata, match_map)
    matches_predicate = predicate_matches?(measurements, metadata, predicate)

    matches_map and matches_predicate
  end

  defp metadata_matches?(metadata, match_map) when match_map == %{}, do: true

  defp metadata_matches?(metadata, match_map) do
    Enum.all?(match_map, fn {key, expected_value} ->
      Map.get(metadata, key) == expected_value
    end)
  end

  defp predicate_matches?(_measurements, _metadata, nil), do: true

  defp predicate_matches?(measurements, metadata, predicate) when is_function(predicate, 2) do
    predicate.(measurements, metadata)
  end
end
