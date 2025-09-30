#!/usr/bin/env elixir

# WebSocket Subscription Assessment Script
# Tests the WebSocket subscription infrastructure and failover capabilities

Mix.install([
  {:websockex, "~> 0.4"},
  {:jason, "~> 1.4"}
])

defmodule WebSocketSubscriptionTester do
  use WebSockex
  require Logger

  def start_link(url, test_name) do
    Logger.info("Starting WebSocket test: #{test_name}")
    WebSockex.start_link(url, __MODULE__, %{test_name: test_name, events: []})
  end

  def subscribe(pid, subscription_type) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => :rand.uniform(1000),
      "method" => "eth_subscribe",
      "params" => [subscription_type]
    }

    WebSockex.send_frame(pid, {:text, Jason.encode!(request)})
  end

  def handle_frame({:text, msg}, state) do
    case Jason.decode(msg) do
      {:ok, decoded} ->
        Logger.info("[#{state.test_name}] Received: #{inspect(decoded)}")
        {:ok, %{state | events: [decoded | state.events]}}

      {:error, reason} ->
        Logger.error("[#{state.test_name}] Failed to decode: #{reason}")
        {:ok, state}
    end
  end

  def handle_disconnect(%{reason: reason}, state) do
    Logger.warning("[#{state.test_name}] Disconnected: #{inspect(reason)}")
    {:ok, state}
  end

  def get_events(pid) do
    GenServer.call(pid, :get_events)
  end

  def handle_call(:get_events, _from, state) do
    {:reply, Enum.reverse(state.events), state}
  end
end

defmodule AssessmentRunner do
  require Logger

  def run do
    Logger.configure(level: :info)

    IO.puts("\n" <> IO.ANSI.cyan() <> "═" <> String.duplicate("═", 78) <> "═" <> IO.ANSI.reset())
    IO.puts(IO.ANSI.cyan() <> "║" <> IO.ANSI.yellow() <> "  WebSocket Subscription Capabilities Assessment" <> String.duplicate(" ", 30) <> IO.ANSI.cyan() <> "║" <> IO.ANSI.reset())
    IO.puts(IO.ANSI.cyan() <> "═" <> String.duplicate("═", 78) <> "═" <> IO.ANSI.reset() <> "\n")

    # Test 1: Can we connect to the WebSocket endpoint?
    IO.puts(IO.ANSI.blue() <> "📡 Test 1: WebSocket Connection" <> IO.ANSI.reset())
    test_connection()

    # Test 2: Can we subscribe to newHeads?
    IO.puts("\n" <> IO.ANSI.blue() <> "📊 Test 2: newHeads Subscription" <> IO.ANSI.reset())
    test_new_heads_subscription()

    # Test 3: Can we subscribe to logs?
    IO.puts("\n" <> IO.ANSI.blue() <> "📝 Test 3: Logs Subscription" <> IO.ANSI.reset())
    test_logs_subscription()

    IO.puts("\n" <> IO.ANSI.cyan() <> "═" <> String.duplicate("═", 78) <> "═" <> IO.ANSI.reset())
    IO.puts(IO.ANSI.green() <> "✅ Assessment Complete" <> IO.ANSI.reset())
    IO.puts(IO.ANSI.cyan() <> "═" <> String.duplicate("═", 78) <> "═" <> IO.ANSI.reset() <> "\n")
  end

  defp test_connection do
    url = "ws://localhost:4000/rpc/ethereum"

    case WebSocketSubscriptionTester.start_link(url, "Connection Test") do
      {:ok, pid} ->
        Process.sleep(1000)
        if Process.alive?(pid) do
          IO.puts(IO.ANSI.green() <> "  ✓ Successfully connected to #{url}" <> IO.ANSI.reset())
          Process.exit(pid, :normal)
          :ok
        else
          IO.puts(IO.ANSI.red() <> "  ✗ Connection died immediately" <> IO.ANSI.reset())
          :error
        end

      {:error, reason} ->
        IO.puts(IO.ANSI.red() <> "  ✗ Failed to connect: #{inspect(reason)}" <> IO.ANSI.reset())
        :error
    end
  end

  defp test_new_heads_subscription do
    url = "ws://localhost:4000/rpc/ethereum"

    case WebSocketSubscriptionTester.start_link(url, "newHeads") do
      {:ok, pid} ->
        Process.sleep(500)

        # Send subscription request
        WebSocketSubscriptionTester.subscribe(pid, "newHeads")
        IO.puts("  → Sent newHeads subscription request")

        # Wait for response
        Process.sleep(5000)

        events = WebSocketSubscriptionTester.get_events(pid)

        # Check for subscription confirmation
        subscription_id = Enum.find_value(events, fn
          %{"result" => id} when is_binary(id) -> id
          _ -> nil
        end)

        if subscription_id do
          IO.puts(IO.ANSI.green() <> "  ✓ Received subscription ID: #{subscription_id}" <> IO.ANSI.reset())

          # Check if we received any block headers
          block_events = Enum.filter(events, fn
            %{"method" => "eth_subscription", "params" => %{"result" => %{"number" => _}}} -> true
            _ -> false
          end)

          if length(block_events) > 0 do
            IO.puts(IO.ANSI.green() <> "  ✓ Received #{length(block_events)} block header(s)" <> IO.ANSI.reset())
          else
            IO.puts(IO.ANSI.yellow() <> "  ⚠ No block headers received (may need to wait for next block)" <> IO.ANSI.reset())
          end
        else
          IO.puts(IO.ANSI.red() <> "  ✗ No subscription confirmation received" <> IO.ANSI.reset())
          IO.puts(IO.ANSI.yellow() <> "  Events received: #{inspect(events)}" <> IO.ANSI.reset())
        end

        Process.exit(pid, :normal)

      {:error, reason} ->
        IO.puts(IO.ANSI.red() <> "  ✗ Failed to connect: #{inspect(reason)}" <> IO.ANSI.reset())
    end
  end

  defp test_logs_subscription do
    url = "ws://localhost:4000/rpc/ethereum"

    case WebSocketSubscriptionTester.start_link(url, "logs") do
      {:ok, pid} ->
        Process.sleep(500)

        # Subscribe to all logs (no filter)
        request = %{
          "jsonrpc" => "2.0",
          "id" => :rand.uniform(1000),
          "method" => "eth_subscribe",
          "params" => ["logs", %{}]
        }

        WebSockex.send_frame(pid, {:text, Jason.encode!(request)})
        IO.puts("  → Sent logs subscription request")

        # Wait for response
        Process.sleep(5000)

        events = WebSocketSubscriptionTester.get_events(pid)

        # Check for subscription confirmation
        subscription_id = Enum.find_value(events, fn
          %{"result" => id} when is_binary(id) -> id
          _ -> nil
        end)

        if subscription_id do
          IO.puts(IO.ANSI.green() <> "  ✓ Received subscription ID: #{subscription_id}" <> IO.ANSI.reset())

          # Check if we received any logs
          log_events = Enum.filter(events, fn
            %{"method" => "eth_subscription", "params" => %{"result" => %{"topics" => _}}} -> true
            _ -> false
          end)

          if length(log_events) > 0 do
            IO.puts(IO.ANSI.green() <> "  ✓ Received #{length(log_events)} log event(s)" <> IO.ANSI.reset())
          else
            IO.puts(IO.ANSI.yellow() <> "  ⚠ No logs received (network may be quiet)" <> IO.ANSI.reset())
          end
        else
          IO.puts(IO.ANSI.red() <> "  ✗ No subscription confirmation received" <> IO.ANSI.reset())
        end

        Process.exit(pid, :normal)

      {:error, reason} ->
        IO.puts(IO.ANSI.red() <> "  ✗ Failed to connect: #{inspect(reason)}" <> IO.ANSI.reset())
    end
  end
end

# Run the assessment
AssessmentRunner.run()