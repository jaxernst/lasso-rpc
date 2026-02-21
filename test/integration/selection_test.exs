defmodule Lasso.RPC.SelectionTest do
  @moduledoc """
  Strategy-agnostic tests for the Selection module.

  Tests the core coordinator responsibilities:
  - Context validation
  - Filter handling (exclude, protocol)
  - CandidateListing integration
  - Error handling
  - Telemetry emission
  - Metadata enrichment

  NOTE: Strategy-specific logic (priority, fastest, cheapest, etc.) is NOT tested here
  as strategies are subject to change and extension. Test those in strategy-specific files.
  """

  use Lasso.Test.LassoIntegrationCase

  alias Lasso.RPC.Selection
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

  describe "select_channels/4 - archival filtering" do
    test "excludes non-archival providers for historical eth_getLogs requests", %{chain: chain} do
      profile = "default"

      # Setup providers with archival: false
      setup_providers([
        %{id: "provider_1", priority: 10, behavior: :healthy, profile: profile, archival: false},
        %{id: "provider_2", priority: 20, behavior: :healthy, profile: profile, archival: false}
      ])

      # Historical eth_getLogs request (block 12369621 is from 2021)
      params = [%{"fromBlock" => "0xBCEE25", "toBlock" => "0xBCEE25"}]

      # Should return empty list - no archival providers available
      channels = Selection.select_channels(profile, chain, "eth_getLogs", params: params)

      assert channels == []
    end

    test "includes archival providers for historical eth_getLogs requests", %{chain: chain} do
      profile = "default"

      # Setup one archival and one non-archival provider
      setup_providers([
        %{id: "archival", priority: 10, behavior: :healthy, profile: profile, archival: true},
        %{id: "non_archival", priority: 20, behavior: :healthy, profile: profile, archival: false}
      ])

      # Historical eth_getLogs request
      params = [%{"fromBlock" => "0xBCEE25", "toBlock" => "0xBCEE25"}]

      # Should return only the archival provider
      channels = Selection.select_channels(profile, chain, "eth_getLogs", params: params)

      assert length(channels) == 1
      channel = hd(channels)
      assert channel.provider_id == "archival"
    end

    test "includes all providers for recent eth_getLogs requests", %{chain: chain} do
      profile = "default"

      setup_providers([
        %{id: "provider_1", priority: 10, behavior: :healthy, profile: profile, archival: false},
        %{id: "provider_2", priority: 20, behavior: :healthy, profile: profile, archival: true}
      ])

      # Recent request using "latest"
      params = [%{"fromBlock" => "latest", "toBlock" => "latest"}]

      # Should return both providers - archival not required
      channels = Selection.select_channels(profile, chain, "eth_getLogs", params: params)

      assert length(channels) == 2
      provider_ids = Enum.map(channels, & &1.provider_id)
      assert "provider_1" in provider_ids
      assert "provider_2" in provider_ids
    end
  end
end
