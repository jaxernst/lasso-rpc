defmodule Lasso.Core.Streaming.InstanceSubscriptionRegistryTest do
  @moduledoc """
  Tests for InstanceSubscriptionRegistry.

  Validates:
  - Registration and unregistration
  - Consumer counting
  - Message dispatch
  - Automatic cleanup on process death
  """

  use ExUnit.Case, async: true

  alias Lasso.Core.Streaming.InstanceSubscriptionRegistry

  defp unique_key do
    suffix = System.unique_integer([:positive])
    {"instance_#{suffix}", {:newHeads}}
  end

  describe "registration" do
    test "register_consumer creates registration" do
      {instance_id, sub_key} = unique_key()

      assert :ok = InstanceSubscriptionRegistry.register_consumer(instance_id, sub_key)
      assert InstanceSubscriptionRegistry.count_consumers(instance_id, sub_key) == 1

      InstanceSubscriptionRegistry.unregister_consumer(instance_id, sub_key)
    end

    test "multiple registrations from same process is idempotent" do
      {instance_id, sub_key} = unique_key()

      assert :ok = InstanceSubscriptionRegistry.register_consumer(instance_id, sub_key)
      assert :ok = InstanceSubscriptionRegistry.register_consumer(instance_id, sub_key)
      assert InstanceSubscriptionRegistry.count_consumers(instance_id, sub_key) == 1

      InstanceSubscriptionRegistry.unregister_consumer(instance_id, sub_key)
    end

    test "unregister_consumer removes registration" do
      {instance_id, sub_key} = unique_key()

      :ok = InstanceSubscriptionRegistry.register_consumer(instance_id, sub_key)
      assert InstanceSubscriptionRegistry.count_consumers(instance_id, sub_key) == 1

      :ok = InstanceSubscriptionRegistry.unregister_consumer(instance_id, sub_key)
      assert InstanceSubscriptionRegistry.count_consumers(instance_id, sub_key) == 0
    end
  end

  describe "dispatch" do
    test "dispatch sends message to all consumers" do
      {instance_id, sub_key} = unique_key()
      test_pid = self()
      test_message = {:test_event, %{"data" => "value"}}

      :ok = InstanceSubscriptionRegistry.register_consumer(instance_id, sub_key)

      other =
        spawn(fn ->
          :ok = InstanceSubscriptionRegistry.register_consumer(instance_id, sub_key)
          send(test_pid, :registered)

          receive do
            ^test_message -> send(test_pid, {:other_received, test_message})
          after
            1000 -> send(test_pid, :other_timeout)
          end
        end)

      assert_receive :registered, 1000

      :ok = InstanceSubscriptionRegistry.dispatch(instance_id, sub_key, test_message)

      assert_receive ^test_message, 1000
      assert_receive {:other_received, ^test_message}, 1000

      InstanceSubscriptionRegistry.unregister_consumer(instance_id, sub_key)
      Process.exit(other, :kill)
    end

    test "dispatch to empty subscription succeeds (no-op)" do
      {instance_id, sub_key} = unique_key()
      assert :ok = InstanceSubscriptionRegistry.dispatch(instance_id, sub_key, {:test, "msg"})
    end
  end

  describe "has_consumers?" do
    test "returns correct boolean" do
      {instance_id, sub_key} = unique_key()

      refute InstanceSubscriptionRegistry.has_consumers?(instance_id, sub_key)

      :ok = InstanceSubscriptionRegistry.register_consumer(instance_id, sub_key)
      assert InstanceSubscriptionRegistry.has_consumers?(instance_id, sub_key)

      :ok = InstanceSubscriptionRegistry.unregister_consumer(instance_id, sub_key)
      refute InstanceSubscriptionRegistry.has_consumers?(instance_id, sub_key)
    end
  end

  describe "automatic cleanup" do
    test "process death removes registration automatically" do
      {instance_id, sub_key} = unique_key()
      test_pid = self()

      spawn(fn ->
        :ok = InstanceSubscriptionRegistry.register_consumer(instance_id, sub_key)
        send(test_pid, :registered)
      end)

      assert_receive :registered, 1000
      Process.sleep(50)

      assert InstanceSubscriptionRegistry.count_consumers(instance_id, sub_key) == 0
    end

    test "killed process registration is cleaned up" do
      {instance_id, sub_key} = unique_key()
      test_pid = self()

      consumer =
        spawn(fn ->
          :ok = InstanceSubscriptionRegistry.register_consumer(instance_id, sub_key)
          send(test_pid, :registered)
          receive do: (:never -> :ok)
        end)

      assert_receive :registered, 1000
      assert InstanceSubscriptionRegistry.count_consumers(instance_id, sub_key) == 1

      Process.exit(consumer, :kill)
      Process.sleep(50)

      assert InstanceSubscriptionRegistry.count_consumers(instance_id, sub_key) == 0
    end
  end

  describe "isolation" do
    test "different keys are isolated" do
      suffix = System.unique_integer([:positive])
      instance_id = "instance_#{suffix}"
      key1 = {:newHeads}
      key2 = {:logs, %{"address" => "0x123"}}

      :ok = InstanceSubscriptionRegistry.register_consumer(instance_id, key1)
      :ok = InstanceSubscriptionRegistry.register_consumer(instance_id, key2)

      assert InstanceSubscriptionRegistry.count_consumers(instance_id, key1) == 1
      assert InstanceSubscriptionRegistry.count_consumers(instance_id, key2) == 1

      :ok = InstanceSubscriptionRegistry.unregister_consumer(instance_id, key1)
      assert InstanceSubscriptionRegistry.count_consumers(instance_id, key1) == 0
      assert InstanceSubscriptionRegistry.count_consumers(instance_id, key2) == 1

      :ok = InstanceSubscriptionRegistry.unregister_consumer(instance_id, key2)
    end

    test "different instances are isolated" do
      suffix = System.unique_integer([:positive])
      instance1 = "instance_a_#{suffix}"
      instance2 = "instance_b_#{suffix}"
      key = {:newHeads}

      :ok = InstanceSubscriptionRegistry.register_consumer(instance1, key)
      :ok = InstanceSubscriptionRegistry.register_consumer(instance2, key)

      assert InstanceSubscriptionRegistry.count_consumers(instance1, key) == 1
      assert InstanceSubscriptionRegistry.count_consumers(instance2, key) == 1

      :ok = InstanceSubscriptionRegistry.unregister_consumer(instance1, key)
      :ok = InstanceSubscriptionRegistry.unregister_consumer(instance2, key)
    end
  end
end
