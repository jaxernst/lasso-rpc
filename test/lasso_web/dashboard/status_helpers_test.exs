defmodule LassoWeb.Dashboard.StatusHelpersTest do
  use ExUnit.Case, async: true

  alias LassoWeb.Dashboard.StatusHelpers

  defp provider(overrides) do
    Map.merge(
      %{
        circuit_state: :closed,
        health_status: :healthy,
        status: :connected,
        consecutive_failures: 0,
        probe_consecutive_failures: 0,
        http_rate_limited: false,
        ws_rate_limited: false,
        is_in_cooldown: false,
        reconnect_attempts: 0,
        ws_status: nil,
        chain: "ethereum",
        id: "test_provider",
        instance_id: "test:inst:000000000001"
      },
      overrides
    )
  end

  describe "determine_provider_status/1" do
    test "circuit_open takes precedence over rate_limited" do
      p = provider(%{circuit_state: :open, http_rate_limited: true})
      assert StatusHelpers.determine_provider_status(p) == :circuit_open
    end

    test "misconfigured health_status maps to degraded" do
      p = provider(%{health_status: :misconfigured})
      assert StatusHelpers.determine_provider_status(p) == :degraded
    end

    test "probe_consecutive_failures alone triggers degraded" do
      p =
        provider(%{
          health_status: nil,
          status: :unknown,
          consecutive_failures: 0,
          probe_consecutive_failures: 5
        })

      assert StatusHelpers.determine_provider_status(p) == :degraded
    end

    test "rate_limited after circuit_open in precedence" do
      p = provider(%{http_rate_limited: true})
      assert StatusHelpers.determine_provider_status(p) == :rate_limited
    end
  end

  describe "status_priority/1" do
    test "circuit_open sorts before rate_limited" do
      circuit = provider(%{circuit_state: :open})
      rate_limited = provider(%{http_rate_limited: true})

      assert StatusHelpers.status_priority(circuit) < StatusHelpers.status_priority(rate_limited)
    end
  end
end
