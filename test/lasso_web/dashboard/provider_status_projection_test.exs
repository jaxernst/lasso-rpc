defmodule LassoWeb.Dashboard.ProviderStatusProjectionTest do
  use ExUnit.Case, async: true

  alias LassoWeb.Dashboard.ProviderStatusProjection

  defp connection(attrs \\ %{}) do
    Map.merge(
      %{
        id: "provider",
        profile_id: "public",
        chain_id: 1,
        url: "https://rpc.example",
        ws_url: nil,
        health_status: :healthy,
        status: :connected,
        http_circuit_state: :closed
      },
      attrs
    )
  end

  test "single-node status uses direct local evidence without waiting for cluster circuit events" do
    now = System.system_time(:millisecond)
    conn = connection(%{block_observed_at_ms: now, block_stale_after_ms: 5000})
    opts = [available_node_ids: ["local"], local_node_id: "local", now_ms: now]
    assert ProviderStatusProjection.status(conn, opts) == :healthy

    assert ProviderStatusProjection.status(conn, Keyword.put(opts, :now_ms, now + 5001)) ==
             :unknown

    assert ProviderStatusProjection.status(conn,
             available_node_ids: ["remote"],
             local_node_id: "local"
           ) == :unknown
  end

  defp status(opts) when is_list(opts), do: status(connection(), opts)

  defp status(connection, opts) do
    defaults = [
      scope: "aggregate",
      available_node_ids: ["iad", "sjc"],
      cluster_blocks: %{
        {"provider", "iad"} => %{
          height: 100,
          lag: 0,
          observed_at_ms: System.system_time(:millisecond)
        },
        {"provider", "sjc"} => %{
          height: 100,
          lag: 0,
          observed_at_ms: System.system_time(:millisecond)
        }
      }
    ]

    ProviderStatusProjection.status(connection, Keyword.merge(defaults, opts))
  end

  test "availability includes a provider rate limited in only one region" do
    circuits = %{
      {"provider", "iad"} => %{http: :closed, http_rate_limited: false},
      {"provider", "sin"} => %{http: :closed, http_rate_limited: true}
    }

    opts = [available_node_ids: ["iad", "sin"], cluster_circuits: circuits]
    assert ProviderStatusProjection.available?(connection(), opts)
    refute ProviderStatusProjection.available?(connection(), Keyword.put(opts, :scope, "sin"))
    projection = ProviderStatusProjection.explain(connection(), opts)
    assert projection.status == :degraded
    assert ProviderStatusProjection.label(projection) == "Partially rate limited"
    assert ProviderStatusProjection.description(projection) =~ "1/2 regions"
  end

  test "mixed circuit and rate failures cannot create false availability" do
    circuits = %{
      {"provider", "iad"} => %{http: :open},
      {"provider", "sin"} => %{http: :closed, http_rate_limited: true}
    }

    refute ProviderStatusProjection.available?(connection(),
             available_node_ids: ["iad", "sin"],
             cluster_circuits: circuits
           )

    refute ProviderStatusProjection.available?(connection(),
             available_node_ids: ["iad"],
             cluster_circuits: %{}
           )

    refute ProviderStatusProjection.available?(
             connection(%{url: nil, ws_url: "wss://rpc.example"}),
             available_node_ids: ["iad"],
             cluster_circuits: %{{"provider", "iad"} => %{ws: :closed, ws_connected: false}}
           )
  end

  test "mixed terminal failures explain that no routes remain across regions or transports" do
    cases = [
      {connection(), ["iad", "sin"],
       %{
         {"provider", "iad"} => %{http: :open},
         {"provider", "sin"} => %{http: :closed, http_rate_limited: true}
       }},
      {connection(%{ws_url: "wss://rpc.example"}), ["sin"],
       %{
         {"provider", "sin"} => %{
           http: :open,
           ws: :closed,
           ws_connected: true,
           ws_rate_limited: true
         }
       }}
    ]

    for {provider, nodes, circuits} <- cases do
      opts = [available_node_ids: nodes, cluster_circuits: circuits]
      refute ProviderStatusProjection.available?(provider, opts)
      projection = ProviderStatusProjection.explain(provider, opts)
      assert projection.reason == :mixed_route_failures
      assert ProviderStatusProjection.label(projection) == "Unavailable"
      assert ProviderStatusProjection.description(projection) =~ "No available routes"
    end
  end

  test "disconnected WebSocket cannot mask total unavailability behind a partial circuit outage" do
    provider = connection(%{ws_url: "wss://rpc.example"})

    circuits =
      Map.new(["iad", "sin"], fn node ->
        {{"provider", node}, %{http: :open, ws: :closed, ws_connected: false}}
      end)

    for scope <- ["aggregate", "sin"] do
      opts = [scope: scope, available_node_ids: ["iad", "sin"], cluster_circuits: circuits]
      refute ProviderStatusProjection.available?(provider, opts)
      projection = ProviderStatusProjection.explain(provider, opts)
      assert projection.reason == :mixed_route_failures
      assert ProviderStatusProjection.label(projection) == "Unavailable"

      assert ProviderStatusProjection.description(projection) =~
               "WebSocket connections are disconnected"
    end
  end

  test "ordinary status descriptions retain the client status copy" do
    assert ProviderStatusProjection.description(%{status: :healthy, reason: :healthy}) == nil
  end

  test "zero reporting nodes cannot turn missing head evidence into health" do
    for timing <- [%{}, %{block_observed_at_ms: 1_000, block_stale_after_ms: 1_000}] do
      assert ProviderStatusProjection.status(connection(timing),
               available_node_ids: [],
               now_ms: 10_000
             ) == :unknown
    end

    assert ProviderStatusProjection.status(connection(%{block_observed_at_ms: 10_000}),
             available_node_ids: [],
             now_ms: 10_000
           ) == :healthy

    assert ProviderStatusProjection.status(connection(%{http_circuit_state: :open}),
             available_node_ids: [],
             now_ms: 10_000
           ) == :circuit_open
  end

  test "disjoint regional transport failures do not imply a provider-wide outage" do
    circuits = %{
      {"provider", "iad"} => %{http: :open, ws: :closed, ws_connected: true},
      {"provider", "sjc"} => %{http: :closed, ws: :open, ws_connected: false}
    }

    assert status(connection(%{ws_url: "wss://rpc.example"}), cluster_circuits: circuits) ==
             :degraded
  end

  test "every supported transport-region slot must be open for a circuit outage" do
    circuits = %{
      {"provider", "iad"} => %{http: :open, ws: :open, ws_connected: false},
      {"provider", "sjc"} => %{http: :open, ws: :open, ws_connected: false}
    }

    assert status(connection(%{ws_url: "wss://rpc.example"}), cluster_circuits: circuits) ==
             :circuit_open
  end

  test "partial and complete rate limiting remain distinct" do
    partial = %{
      {"provider", "iad"} => %{http: :closed, http_rate_limited: true},
      {"provider", "sjc"} => %{http: :closed, http_rate_limited: false}
    }

    complete =
      Map.update!(partial, {"provider", "sjc"}, &Map.put(&1, :http_rate_limited, true))

    assert status(cluster_circuits: partial) == :degraded
    assert status(cluster_circuits: complete) == :rate_limited
  end

  test "regional circuit evidence stays regional while one fresh head fact covers the instance" do
    circuits = %{{"provider", "iad"} => %{http: :closed}}

    assert status(cluster_circuits: circuits) == :degraded

    assert %{
             status: :degraded,
             reason: :partial_circuit_evidence,
             affected_regions: ["sjc"],
             total_regions: 2
           } =
             ProviderStatusProjection.explain(connection(),
               scope: "aggregate",
               available_node_ids: ["iad", "sjc"],
               cluster_circuits: circuits,
               cluster_blocks: %{
                 {"provider", "iad"} => %{
                   height: 100,
                   lag: 0,
                   observed_at_ms: System.system_time(:millisecond)
                 },
                 {"provider", "sjc"} => %{
                   height: 100,
                   lag: 0,
                   observed_at_ms: System.system_time(:millisecond)
                 }
               }
             )

    assert status(cluster_circuits: %{}) == :unknown

    circuits = Map.put(circuits, {"provider", "sjc"}, %{http: :closed})

    assert status(cluster_circuits: circuits, cluster_blocks: %{}) == :unknown

    assert status(
             cluster_circuits: circuits,
             cluster_blocks: %{
               {"provider", "iad"} => %{
                 height: 100,
                 lag: 0,
                 observed_at_ms: System.system_time(:millisecond)
               }
             }
           ) == :healthy

    assert %{
             status: :healthy,
             reason: :healthy,
             affected_regions: []
           } =
             ProviderStatusProjection.explain(connection(),
               scope: "aggregate",
               available_node_ids: ["iad", "sjc"],
               cluster_circuits: circuits,
               cluster_blocks: %{
                 {"provider", "iad"} => %{
                   height: 100,
                   lag: 0,
                   observed_at_ms: System.system_time(:millisecond)
                 }
               }
             )
  end

  test "providers without block observations remain unknown" do
    circuits = %{
      {"provider", "iad"} => %{http: :closed},
      {"provider", "sjc"} => %{http: :closed}
    }

    connection = connection(%{background_observations: false})

    assert status(connection, cluster_circuits: circuits, cluster_blocks: %{}) == :unknown
  end

  test "a height without observation time cannot establish health or lag" do
    circuits = %{
      {"provider", "iad"} => %{http: :closed},
      {"provider", "sjc"} => %{http: :closed}
    }

    for lag <- [0, -100] do
      assert status(
               cluster_circuits: circuits,
               cluster_blocks: %{{"provider", "iad"} => %{height: 100, lag: lag}}
             ) == :unknown
    end
  end

  test "legacy timestamp evidence expires under the same freshness boundary" do
    circuits = %{
      {"provider", "iad"} => %{http: :closed},
      {"provider", "sjc"} => %{http: :closed}
    }

    blocks = %{
      {"provider", "iad"} => %{height: 100, lag: 0, timestamp: 10_000, stale_after_ms: 1_000}
    }

    assert status(cluster_circuits: circuits, cluster_blocks: blocks, now_ms: 10_500) == :healthy
    assert status(cluster_circuits: circuits, cluster_blocks: blocks, now_ms: 11_001) == :unknown
  end

  test "observation policy does not hide a routing failure" do
    circuits = %{
      {"provider", "iad"} => %{http: :closed},
      {"provider", "sjc"} => %{http: :closed}
    }

    health = %{{"provider", "sjc"} => %{status: :unhealthy}}
    passive = connection(%{background_observations: false})

    assert status(passive, cluster_circuits: circuits, cluster_health: health) == :degraded
  end

  test "cluster health and lag evidence can degrade an otherwise closed provider" do
    circuits = %{
      {"provider", "iad"} => %{http: :closed},
      {"provider", "sjc"} => %{http: :closed}
    }

    health = %{{"provider", "sjc"} => %{status: :unhealthy}}
    assert status(cluster_circuits: circuits, cluster_health: health) == :degraded

    blocks = %{
      {"provider", "iad"} => %{
        height: 100,
        lag: 0,
        observed_at_ms: System.system_time(:millisecond)
      },
      {"provider", "sjc"} => %{
        height: 80,
        lag: -20,
        observed_at_ms: System.system_time(:millisecond)
      }
    }

    assert status(cluster_circuits: circuits, cluster_blocks: blocks) == :lagging
  end

  test "elapsed time alone cannot manufacture HTTP head progress" do
    circuits = %{
      {"provider", "iad"} => %{http: :closed},
      {"provider", "sjc"} => %{http: :closed}
    }

    now_ms = 1_000_000

    blocks = %{
      {"provider", "iad"} => %{
        height: 100,
        lag: 0,
        observed_at_ms: now_ms,
        source: :http,
        stale_after_ms: 180_000
      },
      {"provider", "sjc"} => %{
        height: 80,
        lag: -20,
        observed_at_ms: now_ms - 40_000,
        source: :http,
        stale_after_ms: 180_000
      }
    }

    assert status(
             cluster_circuits: circuits,
             cluster_blocks: blocks,
             block_time_ms: 2_000,
             now_ms: now_ms
           ) == :lagging
  end

  test "a captured poll reference aligns HTTP assessment with its request start" do
    circuits = %{
      {"provider", "iad"} => %{http: :closed},
      {"provider", "sjc"} => %{http: :closed}
    }

    now_ms = 1_000_000

    blocks = %{
      {"provider", "iad"} => %{
        height: 1_402,
        lag: 0,
        observed_at_ms: now_ms,
        source: :ws,
        stale_after_ms: 42_000
      },
      {"provider", "sjc"} => %{
        height: 1_000,
        lag: -402,
        observed_at_ms: now_ms - 40_000,
        source: :http,
        stale_after_ms: 180_000,
        reference_height: 1_002,
        assessment_lag: -2
      }
    }

    assert status(
             cluster_circuits: circuits,
             cluster_blocks: blocks,
             block_time_ms: 125,
             now_ms: now_ms
           ) == :healthy
  end

  test "cluster lag credit is capped at one HTTP poll interval" do
    circuits = %{
      {"provider", "iad"} => %{http: :closed},
      {"provider", "sjc"} => %{http: :closed}
    }

    now_ms = 1_000_000

    blocks = %{
      {"provider", "iad"} => %{
        height: 100,
        lag: 0,
        observed_at_ms: now_ms,
        source: :http,
        stale_after_ms: 180_000
      },
      {"provider", "sjc"} => %{
        height: 40,
        lag: -60,
        observed_at_ms: now_ms - 120_000,
        source: :http,
        stale_after_ms: 180_000
      }
    }

    assert status(
             cluster_circuits: circuits,
             cluster_blocks: blocks,
             block_time_ms: 2_000,
             now_ms: now_ms
           ) == :lagging
  end

  test "stale height evidence is unavailable rather than reported as provider lag" do
    circuits = %{
      {"provider", "iad"} => %{http: :closed},
      {"provider", "sjc"} => %{http: :closed}
    }

    now_ms = 1_000_000

    blocks = %{
      {"provider", "iad"} => %{
        height: 100,
        lag: 0,
        observed_at_ms: now_ms,
        source: :http,
        stale_after_ms: 180_000
      },
      {"provider", "sjc"} => %{
        height: 40,
        lag: -60,
        observed_at_ms: now_ms - 180_001,
        source: :http,
        stale_after_ms: 180_000
      }
    }

    assert %{status: :healthy, reason: :healthy, affected_regions: []} =
             ProviderStatusProjection.explain(connection(),
               scope: "aggregate",
               available_node_ids: ["iad", "sjc"],
               cluster_circuits: circuits,
               cluster_blocks: blocks,
               block_time_ms: 100,
               now_ms: now_ms
             )
  end

  test "HTTP-specific health degrades a provider even when provider-wide health is healthy" do
    circuits = %{
      {"provider", "iad"} => %{http: :closed},
      {"provider", "sjc"} => %{http: :closed}
    }

    health = %{
      {"provider", "iad"} => %{status: :healthy, http_status: :degraded},
      {"provider", "sjc"} => %{status: :healthy, http_status: :healthy}
    }

    assert status(cluster_circuits: circuits, cluster_health: health) == :degraded
  end

  test "a region-scoped projection ignores failures in other regions" do
    circuits = %{
      {"provider", "iad"} => %{http: :closed},
      {"provider", "sjc"} => %{http: :open}
    }

    blocks = %{
      {"provider", "iad"} => %{
        height: 100,
        lag: 0,
        observed_at_ms: System.system_time(:millisecond)
      }
    }

    assert ProviderStatusProjection.status(connection(),
             scope: "iad",
             cluster_circuits: circuits,
             cluster_blocks: blocks
           ) == :healthy
  end
end
