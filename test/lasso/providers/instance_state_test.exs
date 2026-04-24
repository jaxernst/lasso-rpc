defmodule Lasso.Providers.InstanceStateTest do
  use ExUnit.Case, async: false

  alias Lasso.Providers.InstanceState

  @table :lasso_instance_state
  @instance_id "test:inst:000000000001"

  setup do
    on_exit(fn ->
      try do
        :ets.delete(@table, {:health_probe, @instance_id})
        :ets.delete(@table, {:health_block_sync, @instance_id})
        :ets.delete(@table, {:health_routing, @instance_id})
      rescue
        ArgumentError -> :ok
      end
    end)

    :ok
  end

  describe "read_health/1 merge behavior" do
    test "probe unhealthy + routing healthy → merged unhealthy" do
      write_probe(%{status: :unhealthy, http_status: :unhealthy, consecutive_failures: 5})
      write_routing(%{status: :healthy, consecutive_failures: 0, consecutive_successes: 10})

      health = InstanceState.read_health(@instance_id)
      assert health.status == :unhealthy
    end

    test "probe healthy + routing unhealthy → merged unhealthy" do
      write_probe(%{status: :healthy, http_status: :healthy, consecutive_failures: 0})
      write_routing(%{status: :unhealthy, consecutive_failures: 8, consecutive_successes: 0})

      health = InstanceState.read_health(@instance_id)
      assert health.status == :unhealthy
    end

    test "probe misconfigured + routing healthy → merged misconfigured" do
      write_probe(%{status: :misconfigured, http_status: :misconfigured, consecutive_failures: 2})
      write_routing(%{status: :healthy, consecutive_failures: 0, consecutive_successes: 5})

      health = InstanceState.read_health(@instance_id)
      assert health.status == :misconfigured
    end

    test "probe unhealthy + routing nil → merged unhealthy" do
      write_probe(%{status: :unhealthy, http_status: :unhealthy, consecutive_failures: 5})

      health = InstanceState.read_health(@instance_id)
      assert health.status == :unhealthy
    end

    test "both defaults → :connecting (no data yet)" do
      health = InstanceState.read_health(@instance_id)
      assert health.status == :connecting
    end

    test "keeps routing failures and probe failures separate" do
      write_probe(%{status: :degraded, consecutive_failures: 3})
      write_routing(%{status: :healthy, consecutive_failures: 0, consecutive_successes: 10})

      health = InstanceState.read_health(@instance_id)
      assert health.consecutive_failures == 0
      assert health.probe_consecutive_failures == 3
      assert health.consecutive_successes == 10
    end

    test "last_error picks more recent source" do
      now = System.system_time(:millisecond)

      write_probe(%{
        status: :degraded,
        last_health_check: now,
        last_error: :probe_timeout,
        consecutive_failures: 1
      })

      write_routing(%{
        status: :degraded,
        last_health_check: now - 60_000,
        last_error: {:http_status, 500},
        consecutive_failures: 2,
        consecutive_successes: 0
      })

      health = InstanceState.read_health(@instance_id)
      assert health.last_error == :probe_timeout

      # Flip timestamps — routing becomes more recent
      write_routing(%{
        status: :degraded,
        last_health_check: now + 1000,
        last_error: {:http_status, 502},
        consecutive_failures: 2,
        consecutive_successes: 0
      })

      health = InstanceState.read_health(@instance_id)
      assert health.last_error == {:http_status, 502}
    end

    test "last_error returns sole error when only one source has one" do
      write_probe(%{status: :healthy, consecutive_failures: 0, last_error: nil})
      write_routing(%{status: :degraded, consecutive_failures: 2, last_error: :timeout})

      health = InstanceState.read_health(@instance_id)
      assert health.last_error == :timeout
    end

    test "latest_check picks most recent timestamp" do
      now = System.system_time(:millisecond)
      write_probe(%{status: :healthy, last_health_check: now - 5000})
      write_routing(%{status: :healthy, last_health_check: now})

      health = InstanceState.read_health(@instance_id)
      assert health.last_health_check == now
    end
  end

  describe "status_to_availability/1" do
    test "misconfigured maps to :down" do
      assert InstanceState.status_to_availability(:misconfigured) == :down
    end

    test "healthy maps to :up" do
      assert InstanceState.status_to_availability(:healthy) == :up
    end

    test "degraded maps to :limited" do
      assert InstanceState.status_to_availability(:degraded) == :limited
    end
  end

  # Helpers

  defp write_probe(fields) do
    data =
      Map.merge(
        %{
          status: nil,
          http_status: nil,
          last_health_check: System.system_time(:millisecond),
          consecutive_failures: 0,
          last_error: nil
        },
        fields
      )

    :ets.insert(@table, {{:health_probe, @instance_id}, data})
  end

  defp write_routing(fields) do
    data =
      Map.merge(
        %{
          status: nil,
          last_health_check: System.system_time(:millisecond),
          consecutive_failures: 0,
          consecutive_successes: 0,
          last_error: nil
        },
        fields
      )

    :ets.insert(@table, {{:health_routing, @instance_id}, data})
  end
end
