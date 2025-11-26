defmodule Lasso.Core.Streaming.UpstreamSubscriptionRegistryTest do
  @moduledoc """
  Tests for UpstreamSubscriptionRegistry - thin wrapper around Elixir Registry.

  Validates:
  - Registration and unregistration
  - Consumer counting and lookup
  - Message dispatch
  - Automatic cleanup on process death
  """

  use ExUnit.Case, async: true

  alias Lasso.Core.Streaming.UpstreamSubscriptionRegistry

  # Use unique identifiers per test to avoid interference
  defp unique_key do
    suffix = System.unique_integer([:positive])
    {"test_chain_#{suffix}", "test_provider_#{suffix}", {:newHeads}}
  end

  describe "registration" do
    test "register_consumer creates registration" do
      {chain, provider, key} = unique_key()

      assert :ok = UpstreamSubscriptionRegistry.register_consumer(chain, provider, key)
      assert UpstreamSubscriptionRegistry.count_consumers(chain, provider, key) == 1

      # Cleanup
      UpstreamSubscriptionRegistry.unregister_consumer(chain, provider, key)
    end

    test "multiple registrations from same process is idempotent" do
      {chain, provider, key} = unique_key()

      assert :ok = UpstreamSubscriptionRegistry.register_consumer(chain, provider, key)
      assert :ok = UpstreamSubscriptionRegistry.register_consumer(chain, provider, key)
      # Idempotent - second registration doesn't create a duplicate
      assert UpstreamSubscriptionRegistry.count_consumers(chain, provider, key) == 1

      # Cleanup
      UpstreamSubscriptionRegistry.unregister_consumer(chain, provider, key)
    end

    test "unregister_consumer removes registration" do
      {chain, provider, key} = unique_key()

      :ok = UpstreamSubscriptionRegistry.register_consumer(chain, provider, key)
      assert UpstreamSubscriptionRegistry.count_consumers(chain, provider, key) == 1

      :ok = UpstreamSubscriptionRegistry.unregister_consumer(chain, provider, key)
      assert UpstreamSubscriptionRegistry.count_consumers(chain, provider, key) == 0
    end
  end

  describe "lookup" do
    test "lookup_consumers returns all registered consumers" do
      {chain, provider, key} = unique_key()
      test_pid = self()

      # Register from main process
      :ok = UpstreamSubscriptionRegistry.register_consumer(chain, provider, key)

      # Register from another process
      other =
        spawn(fn ->
          :ok = UpstreamSubscriptionRegistry.register_consumer(chain, provider, key)
          send(test_pid, :registered)
          receive do: (:exit -> :ok)
        end)

      assert_receive :registered, 1000

      # Should have 2 consumers
      consumers = UpstreamSubscriptionRegistry.lookup_consumers(chain, provider, key)
      assert length(consumers) == 2

      pids = Enum.map(consumers, fn {pid, _meta} -> pid end)
      assert self() in pids
      assert other in pids

      # Cleanup
      send(other, :exit)
      UpstreamSubscriptionRegistry.unregister_consumer(chain, provider, key)
    end

    test "has_consumers? returns correct boolean" do
      {chain, provider, key} = unique_key()

      refute UpstreamSubscriptionRegistry.has_consumers?(chain, provider, key)

      :ok = UpstreamSubscriptionRegistry.register_consumer(chain, provider, key)
      assert UpstreamSubscriptionRegistry.has_consumers?(chain, provider, key)

      :ok = UpstreamSubscriptionRegistry.unregister_consumer(chain, provider, key)
      refute UpstreamSubscriptionRegistry.has_consumers?(chain, provider, key)
    end
  end

  describe "dispatch" do
    test "dispatch sends message to all consumers" do
      {chain, provider, key} = unique_key()
      test_pid = self()
      test_message = {:test_event, %{"data" => "value"}}

      # Register from main process
      :ok = UpstreamSubscriptionRegistry.register_consumer(chain, provider, key)

      # Register from another process
      _other =
        spawn(fn ->
          :ok = UpstreamSubscriptionRegistry.register_consumer(chain, provider, key)
          send(test_pid, :registered)

          receive do
            ^test_message -> send(test_pid, {:other_received, test_message})
          after
            1000 -> send(test_pid, :other_timeout)
          end
        end)

      assert_receive :registered, 1000

      # Dispatch message
      :ok = UpstreamSubscriptionRegistry.dispatch(chain, provider, key, test_message)

      # Both should receive
      assert_receive ^test_message, 1000
      assert_receive {:other_received, ^test_message}, 1000

      # Cleanup
      UpstreamSubscriptionRegistry.unregister_consumer(chain, provider, key)
    end

    test "dispatch to empty subscription succeeds (no-op)" do
      {chain, provider, key} = unique_key()

      # Should not crash even with no consumers
      assert :ok = UpstreamSubscriptionRegistry.dispatch(chain, provider, key, {:test, "msg"})
    end
  end

  describe "automatic cleanup" do
    test "process death removes registration automatically" do
      {chain, provider, key} = unique_key()
      test_pid = self()

      # Spawn a process that registers and then dies
      spawn(fn ->
        :ok = UpstreamSubscriptionRegistry.register_consumer(chain, provider, key)
        send(test_pid, :registered)
        # Process exits immediately after sending message
      end)

      assert_receive :registered, 1000

      # Give Registry time to clean up (should be immediate)
      Process.sleep(50)

      # Registration should be removed
      assert UpstreamSubscriptionRegistry.count_consumers(chain, provider, key) == 0
    end

    test "killed process registration is cleaned up" do
      {chain, provider, key} = unique_key()
      test_pid = self()

      consumer =
        spawn(fn ->
          :ok = UpstreamSubscriptionRegistry.register_consumer(chain, provider, key)
          send(test_pid, :registered)
          receive do: (:never -> :ok)
        end)

      assert_receive :registered, 1000
      assert UpstreamSubscriptionRegistry.count_consumers(chain, provider, key) == 1

      # Kill the consumer
      Process.exit(consumer, :kill)
      Process.sleep(50)

      # Registration should be removed
      assert UpstreamSubscriptionRegistry.count_consumers(chain, provider, key) == 0
    end
  end

  describe "isolation" do
    test "different keys are isolated" do
      suffix = System.unique_integer([:positive])
      chain = "test_chain_#{suffix}"
      provider = "test_provider_#{suffix}"
      key1 = {:newHeads}
      key2 = {:logs, %{"address" => "0x123"}}

      :ok = UpstreamSubscriptionRegistry.register_consumer(chain, provider, key1)
      :ok = UpstreamSubscriptionRegistry.register_consumer(chain, provider, key2)

      assert UpstreamSubscriptionRegistry.count_consumers(chain, provider, key1) == 1
      assert UpstreamSubscriptionRegistry.count_consumers(chain, provider, key2) == 1

      # Unregister one doesn't affect the other
      :ok = UpstreamSubscriptionRegistry.unregister_consumer(chain, provider, key1)
      assert UpstreamSubscriptionRegistry.count_consumers(chain, provider, key1) == 0
      assert UpstreamSubscriptionRegistry.count_consumers(chain, provider, key2) == 1

      # Cleanup
      :ok = UpstreamSubscriptionRegistry.unregister_consumer(chain, provider, key2)
    end

    test "different providers are isolated" do
      suffix = System.unique_integer([:positive])
      chain = "test_chain_#{suffix}"
      provider1 = "provider_a_#{suffix}"
      provider2 = "provider_b_#{suffix}"
      key = {:newHeads}

      :ok = UpstreamSubscriptionRegistry.register_consumer(chain, provider1, key)
      :ok = UpstreamSubscriptionRegistry.register_consumer(chain, provider2, key)

      assert UpstreamSubscriptionRegistry.count_consumers(chain, provider1, key) == 1
      assert UpstreamSubscriptionRegistry.count_consumers(chain, provider2, key) == 1

      # Cleanup
      :ok = UpstreamSubscriptionRegistry.unregister_consumer(chain, provider1, key)
      :ok = UpstreamSubscriptionRegistry.unregister_consumer(chain, provider2, key)
    end
  end
end
