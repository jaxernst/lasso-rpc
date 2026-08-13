defmodule Lasso.RPC.Selection.HealthTierTest do
  use ExUnit.Case, async: true

  alias Lasso.RPC.{Channel, Selection}

  test "preserves strategy order inside the explicit four health tiers" do
    channels =
      Enum.map(
        ["half-limited", "closed-limited", "half-live-b", "closed-live", "half-live-a"],
        fn provider_id ->
          %Channel{provider_id: provider_id, instance_id: provider_id, transport: :http}
        end
      )

    circuit_states = %{
      {"half-limited", :http} => :half_open,
      {"closed-limited", :http} => :closed,
      {"half-live-b", :http} => :half_open,
      {"closed-live", :http} => :closed,
      {"half-live-a", :http} => :half_open
    }

    rate_limits = %{
      "half-limited" => %{http: true},
      "closed-limited" => %{http: true},
      "half-live-b" => %{http: false},
      "closed-live" => %{http: false},
      "half-live-a" => %{http: false}
    }

    assert ["closed-live", "half-live-b", "half-live-a", "closed-limited", "half-limited"] ==
             channels
             |> Selection.tier_channels(circuit_states, rate_limits)
             |> Enum.map(& &1.provider_id)
  end

  test "excludes open and unrecognized circuit states" do
    channels =
      Enum.map(["closed", "open", "unknown"], fn provider_id ->
        %Channel{provider_id: provider_id, instance_id: provider_id, transport: :http}
      end)

    circuit_states = %{
      {"closed", :http} => :closed,
      {"open", :http} => :open,
      {"unknown", :http} => :unknown
    }

    assert [%Channel{provider_id: "closed"}] =
             Selection.tier_channels(channels, circuit_states, %{})
  end
end
