defmodule Lasso.Testing.TelemetrySync do
  @moduledoc """
  Synchronization primitives for telemetry-based testing.

  ## BEAM Semantics

  Telemetry handlers execute synchronously in the calling process when
  :telemetry.execute/3 is called. This means:

  1. Handlers MUST be attached BEFORE events fire
  2. Events are fire-and-forget with no history/replay
  3. Handler execution blocks the event emitter

  ## Usage Pattern

      # CORRECT: Attach handler, THEN trigger event
      {:ok, collector} = TelemetrySync.attach_collector([:lasso, :request, :completed])

      # Now execute the action that generates telemetry
      {:ok, result} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [], %Lasso.RPC.RequestOptions{strategy: :round_robin, timeout_ms: 30_000})

      # Wait for the event we collected
      {:ok, measurements, metadata} = TelemetrySync.await_event(collector, timeout: 1000)

      # INCORRECT: Execute first, attach second
      {:ok, result} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [], %Lasso.RPC.RequestOptions{strategy: :round_robin, timeout_ms: 30_000})
      {:ok, collector} = TelemetrySync.attach_collector([:lasso, :request, :completed])
      TelemetrySync.await_event(collector, timeout: 1000)  # Always times out!
  """

  require Logger

  @type event_name :: :telemetry.event_name()
  @type measurements :: :telemetry.event_measurements()
  @type metadata :: :telemetry.event_metadata()
  @type match_spec :: keyword() | (measurements(), metadata() -> boolean())

  @type collector :: %{
          ref: reference(),
          handler_id: term(),
          test_pid: pid(),
          event_name: event_name(),
          expected_count: pos_integer()
        }

  @default_timeout 5000

  ## Public API

  @doc """
  Attaches a telemetry collector for the given event.

  Returns a collector handle that can be used with await_event/2.

  ## Options

  - `:match` - Keyword list or predicate function to filter events
  - `:count` - Number of matching events to collect (default: 1)

  ## Examples

      # Collect any request completion
      {:ok, collector} = attach_collector([:lasso, :request, :completed])

      # Collect specific method
      {:ok, collector} = attach_collector(
        [:lasso, :request, :completed],
        match: [method: "eth_blockNumber"]
      )

      # Collect with predicate
      {:ok, collector} = attach_collector(
        [:lasso, :request, :completed],
        match: fn _measurements, metadata ->
          metadata.method in ["eth_blockNumber", "eth_getBalance"]
        end
      )

      # Collect multiple events
      {:ok, collector} = attach_collector(
        [:lasso, :request, :completed],
        count: 3
      )
  """
  @spec attach_collector(event_name(), keyword()) :: {:ok, collector()}
  def attach_collector(event_name, opts \\ []) when is_list(event_name) do
    match_spec = Keyword.get(opts, :match, %{})
    count = Keyword.get(opts, :count, 1)

    test_pid = self()
    ref = make_ref()
    handler_id = {__MODULE__, ref, System.unique_integer([:positive, :monotonic])}

    predicate = build_predicate(match_spec)

    # Attach BEFORE the action
    :telemetry.attach(
      handler_id,
      event_name,
      fn ^event_name,
         measurements,
         metadata,
         %{ref: ref, pid: pid, pred: pred, count_ref: count_ref} ->
        if pred.(measurements, metadata) do
          # Send event to test process
          send(pid, {ref, :telemetry_event, measurements, metadata})

          # Track count
          :counters.add(count_ref, 1, 1)
        end
      end,
      %{
        ref: ref,
        pid: test_pid,
        pred: predicate,
        count_ref: :counters.new(1, [:atomics])
      }
    )

    collector = %{
      ref: ref,
      handler_id: handler_id,
      test_pid: test_pid,
      event_name: event_name,
      expected_count: count
    }

    {:ok, collector}
  end

  @doc """
  Waits for a telemetry event collected by the given collector.

  This must be called AFTER the action that generates the telemetry event,
  but the collector must have been attached BEFORE the action.

  ## Options

  - `:timeout` - Maximum time to wait in milliseconds (default: 5000)

  ## Returns

  - `{:ok, measurements, metadata}` - Single event received
  - `{:ok, events}` - Multiple events if count > 1, where events is list of {measurements, metadata}
  - `{:error, :timeout}` - No matching event within timeout
  """
  @spec await_event(collector(), keyword()) ::
          {:ok, measurements(), metadata()}
          | {:ok, [{measurements(), metadata()}]}
          | {:error, :timeout}
  def await_event(collector, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    try do
      events = collect_events(collector.ref, collector.expected_count, timeout, [])

      case {collector.expected_count, events} do
        {1, [{measurements, metadata}]} ->
          {:ok, measurements, metadata}

        {n, events} when length(events) == n ->
          {:ok, events}

        _ ->
          {:error, :timeout}
      end
    after
      # Always detach handler
      :telemetry.detach(collector.handler_id)
    end
  end

  @doc """
  Convenience function combining attach_collector/2 and await_event/2.

  WARNING: This only works if you can pass a function that will generate
  the telemetry event. Use attach_collector + await_event for more control.

  ## Example

      {:ok, measurements, metadata} =
        TelemetrySync.collect_event(
          [:lasso, :request, :completed],
          fn ->
            RequestPipeline.execute_via_channels(
              chain,
              "eth_blockNumber",
              [],
              %Lasso.RPC.RequestOptions{strategy: :round_robin, timeout_ms: 30_000}
            )
          end,
          match: [method: "eth_blockNumber"],
          timeout: 1000
        )
  """
  @spec collect_event(event_name(), (-> any()), keyword()) ::
          {:ok, measurements(), metadata()}
          | {:ok, [{measurements(), metadata()}]}
          | {:error, :timeout}
  def collect_event(event_name, action_fn, opts \\ []) when is_function(action_fn, 0) do
    {:ok, collector} = attach_collector(event_name, opts)

    # Execute the action that will generate telemetry
    _result = action_fn.()

    # Now wait for the event
    await_event(collector, opts)
  end

  ## High-Level Helpers

  @doc """
  Waits for a request completion event.

  ## Options

  - `:method` - Filter by RPC method name (optional)
  - `:chain` - Filter by chain (optional)
  - `:timeout` - Maximum wait time (default: 5000)

  ## Example

      # Must be called AFTER attaching collector but BEFORE request
      {:ok, collector} = TelemetrySync.attach_request_collector(method: "eth_blockNumber")

      {:ok, result} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          %Lasso.RPC.RequestOptions{strategy: :round_robin, timeout_ms: 30_000}
        )

      {:ok, measurements, metadata} = TelemetrySync.await_event(collector)
  """
  def attach_request_collector(opts \\ []) do
    match_spec =
      opts
      |> Keyword.take([:method, :chain])
      |> Enum.into(%{})

    attach_collector(
      [:lasso, :request, :completed],
      match: match_spec,
      count: Keyword.get(opts, :count, 1)
    )
  end

  ## Private Helpers

  # Recursively collect multiple events within a timeout budget
  defp collect_events(_ref, 0, _timeout, acc), do: Enum.reverse(acc)

  defp collect_events(ref, remaining, timeout, acc) do
    start_time = System.monotonic_time(:millisecond)

    receive do
      {^ref, :telemetry_event, measurements, metadata} ->
        elapsed = System.monotonic_time(:millisecond) - start_time
        new_timeout = max(0, timeout - elapsed)

        collect_events(ref, remaining - 1, new_timeout, [{measurements, metadata} | acc])
    after
      timeout ->
        Enum.reverse(acc)
    end
  end

  defp build_predicate(match_spec) when is_function(match_spec, 2), do: match_spec

  defp build_predicate(match_spec) when is_map(match_spec) or is_list(match_spec) do
    match_map = Enum.into(match_spec, %{})

    fn _measurements, metadata ->
      Enum.all?(match_map, fn {key, expected_value} ->
        Map.get(metadata, key) == expected_value
      end)
    end
  end
end
