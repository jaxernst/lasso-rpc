#!/usr/bin/env elixir
# Usage: bin/lasso eval "Code.eval_file(\"scripts/cluster_smoke_test.exs\")"
# Or via remote: bin/lasso rpc "Code.eval_file(\"scripts/cluster_smoke_test.exs\")"

defmodule ClusterSmokeTest do
  @timeout 10_000

  def run do
    IO.puts("=== Cluster Smoke Test ===\n")

    results = [
      {"Node Discovery", &check_nodes/0},
      {"Topology", &check_topology/0},
      {"MetricsStore", &check_metrics_store/0},
      {"PubSub Distribution", &check_pubsub/0},
      {"Health Endpoint", &check_health/0}
    ]
    |> Enum.map(fn {name, check} ->
      result = try do
        case check.() do
          :ok -> {:pass, nil}
          {:ok, info} -> {:pass, info}
          {:error, reason} -> {:fail, reason}
        end
      rescue
        e -> {:fail, Exception.message(e)}
      end
      {name, result}
    end)

    # Print results
    Enum.each(results, fn {name, {status, info}} ->
      icon = if status == :pass, do: "✓", else: "✗"
      IO.puts("#{icon} #{name}")
      if info, do: IO.puts("  └─ #{info}")
    end)

    # Summary
    passed = Enum.count(results, fn {_, {s, _}} -> s == :pass end)
    total = length(results)
    IO.puts("\n#{passed}/#{total} checks passed")

    if passed < total do
      System.halt(1)
    end
  end

  defp check_nodes do
    nodes = Node.list()
    expected = String.to_integer(System.get_env("EXPECTED_NODE_COUNT", "1"))

    total = length(nodes) + 1  # +1 for self
    if total >= expected do
      {:ok, "#{total}/#{expected} nodes connected: #{inspect([node() | nodes])}"}
    else
      {:error, "Only #{total}/#{expected} nodes. Connected: #{inspect(nodes)}"}
    end
  end

  defp check_topology do
    case Lasso.Cluster.Topology.get_coverage() do
      %{connected: connected, responding: responding} ->
        {:ok, "#{responding}/#{connected} nodes responding"}
      other ->
        {:error, "Unexpected coverage format: #{inspect(other)}"}
    end
  catch
    :exit, {:noproc, _} -> {:error, "Topology not running"}
  end

  defp check_metrics_store do
    case LassoWeb.Dashboard.MetricsStore.get_provider_leaderboard("default", "ethereum") do
      %{data: _data, coverage: coverage} ->
        {:ok, "#{coverage.responding}/#{coverage.total} nodes responding"}
      other ->
        {:error, "Unexpected result: #{inspect(other)}"}
    end
  catch
    :exit, {:noproc, _} -> {:error, "MetricsStore not running"}
    :exit, {:timeout, _} -> {:error, "MetricsStore timed out"}
  end

  defp check_pubsub do
    # Verify PubSub can broadcast and receive
    test_topic = "smoke_test:#{System.unique_integer()}"
    Phoenix.PubSub.subscribe(Lasso.PubSub, test_topic)
    Phoenix.PubSub.broadcast(Lasso.PubSub, test_topic, :ping)

    receive do
      :ping -> :ok
    after
      1_000 -> {:error, "PubSub broadcast not received within 1s"}
    end
  end

  defp check_health do
    # Verify health endpoint includes cluster info
    case :httpc.request(:get, {~c"http://localhost:4000/health", []}, [], []) do
      {:ok, {{_, 200, _}, _, body}} ->
        case Jason.decode(to_string(body)) do
          {:ok, %{"cluster" => %{"nodes_connected" => n}}} ->
            {:ok, "Health reports #{n} nodes connected"}
          {:ok, _} ->
            {:error, "Health endpoint missing cluster info"}
          _ ->
            {:error, "Health endpoint returned invalid JSON"}
        end
      {:ok, {{_, status, _}, _, _}} ->
        {:error, "Health returned HTTP #{status}"}
      {:error, reason} ->
        {:error, "Health request failed: #{inspect(reason)}"}
    end
  end
end

ClusterSmokeTest.run()
