defmodule Lasso.RPC.SelectionTest do
  @moduledoc """
  Strategy-agnostic tests for the Selection module.

  Tests the core coordinator responsibilities:
  - Context validation
  - Filter handling (exclude, protocol)
  - ProviderPool integration
  - Error handling
  - Telemetry emission
  - Metadata enrichment

  NOTE: Strategy-specific logic (priority, fastest, cheapest, etc.) is NOT tested here
  as strategies are subject to change and extension. Test those in strategy-specific files.
  """

  use Lasso.Test.LassoIntegrationCase

  alias Lasso.RPC.{Selection, SelectionContext, ProviderPool}
  alias Lasso.Test.TelemetrySync

  describe "select_provider/3 - filter handling" do
    test "respects exclude filter", %{chain: chain} do
      profile = "default"

      setup_providers([
        %{id: "provider_1", priority: 10, behavior: :healthy, profile: profile},
        %{id: "provider_2", priority: 20, behavior: :healthy, profile: profile},
        %{id: "provider_3", priority: 30, behavior: :healthy, profile: profile}
      ])

      # Select without exclusions
      {:ok, selected1} = Selection.select_provider(profile, chain, "eth_blockNumber")
      assert selected1 in ["provider_1", "provider_2", "provider_3"]

      # Select with exclusion
      {:ok, selected2} =
        Selection.select_provider(profile, chain, "eth_blockNumber", exclude: [selected1])

      assert selected2 != selected1
      assert selected2 in ["provider_1", "provider_2", "provider_3"]
    end

    test "respects protocol filter for http", %{chain: chain} do
      profile = "default"

      setup_providers([
        %{id: "http_only", priority: 10, behavior: :healthy, profile: profile}
      ])

      # HTTP protocol should work
      {:ok, selected} =
        Selection.select_provider(profile, chain, "eth_blockNumber", protocol: :http)

      assert selected == "http_only"
    end

    test "combines exclude and protocol filters", %{chain: chain} do
      profile = "default"

      setup_providers([
        %{id: "provider_1", priority: 10, behavior: :healthy, profile: profile},
        %{id: "provider_2", priority: 20, behavior: :healthy, profile: profile}
      ])

      # Exclude provider_1 and use HTTP protocol
      {:ok, selected} =
        Selection.select_provider(profile, chain, "eth_blockNumber",
          exclude: ["provider_1"],
          protocol: :http
        )

      assert selected == "provider_2"
    end
  end

  describe "select_provider/3 - error handling" do
    test "returns error when no providers available", %{chain: chain} do
      profile = "default"
      # Don't setup any providers

      assert {:error, :no_providers_available} =
               Selection.select_provider(profile, chain, "eth_blockNumber")
    end

    test "returns error when all providers excluded", %{chain: chain} do
      profile = "default"

      setup_providers([
        %{id: "provider_1", priority: 10, behavior: :healthy, profile: profile}
      ])

      assert {:error, :no_providers_available} =
               Selection.select_provider(profile, chain, "eth_blockNumber",
                 exclude: ["provider_1"]
               )
    end

    test "returns error for invalid chain" do
      profile = "default"
      # Non-existent chain with no providers
      assert {:error, :no_providers_available} =
               Selection.select_provider(profile, "nonexistent_chain", "eth_blockNumber")
    end
  end

  describe "select_provider/1 - context validation" do
    test "returns error for empty chain name" do
      ctx = %SelectionContext{
        profile: "default",
        chain: "",
        method: "eth_blockNumber",
        strategy: :priority,
        protocol: :http,
        exclude: [],
        metrics: Lasso.Core.Benchmarking.Metrics,
        timeout: 30_000
      }

      assert {:error, "Chain name is required"} = Selection.select_provider(ctx)
    end

    test "returns error for empty method name" do
      ctx = %SelectionContext{
        profile: "default",
        chain: "ethereum",
        method: "",
        strategy: :priority,
        protocol: :http,
        exclude: [],
        metrics: Lasso.Core.Benchmarking.Metrics,
        timeout: 30_000
      }

      assert {:error, "Method name is required"} = Selection.select_provider(ctx)
    end

    test "returns error for invalid strategy" do
      ctx = %SelectionContext{
        profile: "default",
        chain: "ethereum",
        method: "eth_blockNumber",
        strategy: :invalid_strategy,
        protocol: :http,
        exclude: [],
        metrics: Lasso.Core.Benchmarking.Metrics,
        timeout: 30_000
      }

      assert {:error, "Invalid strategy: " <> _} = Selection.select_provider(ctx)
    end

    test "returns error for invalid protocol" do
      ctx = %SelectionContext{
        profile: "default",
        chain: "ethereum",
        method: "eth_blockNumber",
        strategy: :priority,
        protocol: :invalid_protocol,
        exclude: [],
        metrics: Lasso.Core.Benchmarking.Metrics,
        timeout: 30_000
      }

      assert {:error, "Invalid protocol: " <> _} = Selection.select_provider(ctx)
    end

    test "returns error for non-list exclude" do
      ctx = %SelectionContext{
        profile: "default",
        chain: "ethereum",
        method: "eth_blockNumber",
        strategy: :priority,
        protocol: :http,
        exclude: "not_a_list",
        metrics: Lasso.Core.Benchmarking.Metrics,
        timeout: 30_000
      }

      assert {:error, "Exclude must be a list of provider IDs"} = Selection.select_provider(ctx)
    end

    test "returns error for non-positive timeout" do
      ctx = %SelectionContext{
        profile: "default",
        chain: "ethereum",
        method: "eth_blockNumber",
        strategy: :priority,
        protocol: :http,
        exclude: [],
        metrics: Lasso.Core.Benchmarking.Metrics,
        timeout: -1
      }

      assert {:error, "Timeout must be positive"} = Selection.select_provider(ctx)
    end
  end

  describe "select_provider/3 - telemetry" do
    test "emits telemetry on successful selection", %{chain: chain} do
      profile = "default"

      setup_providers([
        %{id: "provider_1", priority: 10, behavior: :healthy, profile: profile}
      ])

      # Attach telemetry collector
      {:ok, collector} =
        TelemetrySync.attach_collector(
          [:lasso, :selection, :success],
          match: [chain: chain, method: "eth_blockNumber"]
        )

      # Perform selection
      {:ok, _selected} = Selection.select_provider(profile, chain, "eth_blockNumber")

      # Verify telemetry emitted
      {:ok, measurements, metadata} = TelemetrySync.await_event(collector, timeout: 1000)

      assert measurements.count == 1
      assert metadata.chain == chain
      assert metadata.method == "eth_blockNumber"
      assert metadata.provider_id in ["provider_1"]
    end
  end

  describe "select_provider_with_metadata/3" do
    test "returns metadata with candidate list", %{chain: chain} do
      profile = "default"

      setup_providers([
        %{id: "provider_1", priority: 10, behavior: :healthy, profile: profile},
        %{id: "provider_2", priority: 20, behavior: :healthy, profile: profile}
      ])

      assert {:ok, %{provider_id: selected, metadata: metadata}} =
               Selection.select_provider_with_metadata(profile, chain, "eth_blockNumber")

      # Verify metadata structure
      assert is_list(metadata.candidates)
      assert length(metadata.candidates) == 2
      assert "provider_1" in metadata.candidates
      assert "provider_2" in metadata.candidates

      # Verify selected provider info
      assert metadata.selected.id == selected
      assert metadata.selected.protocol in [:http, :ws, :both]

      # Verify selection reason is provided
      assert is_binary(metadata.reason)
    end

    test "includes correct protocol in metadata", %{chain: chain} do
      profile = "default"

      setup_providers([
        %{id: "provider_1", priority: 10, behavior: :healthy, profile: profile}
      ])

      assert {:ok, %{metadata: metadata}} =
               Selection.select_provider_with_metadata(profile, chain, "eth_blockNumber",
                 protocol: :http
               )

      assert metadata.selected.protocol == :http
    end

    test "returns error when no providers available", %{chain: chain} do
      profile = "default"
      # Don't setup any providers

      assert {:error, :no_providers_available} =
               Selection.select_provider_with_metadata(profile, chain, "eth_blockNumber")
    end
  end
end
