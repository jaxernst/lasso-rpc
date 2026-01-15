defmodule Lasso.RPC.SelectionFiltersTest do
  use ExUnit.Case, async: true

  alias Lasso.RPC.SelectionFilters

  describe "new/1" do
    test "creates struct with default values" do
      filters = SelectionFilters.new()

      assert filters.protocol == nil
      assert filters.exclude == []
      assert filters.include_half_open == false
      assert filters.exclude_rate_limited == false
      assert filters.max_lag_blocks == nil
      assert filters.requires_archival == false
    end

    test "accepts all filter options" do
      filters =
        SelectionFilters.new(
          protocol: :http,
          exclude: ["provider_1"],
          include_half_open: true,
          exclude_rate_limited: true,
          max_lag_blocks: 5,
          requires_archival: true
        )

      assert filters.protocol == :http
      assert filters.exclude == ["provider_1"]
      assert filters.include_half_open == true
      assert filters.exclude_rate_limited == true
      assert filters.max_lag_blocks == 5
      assert filters.requires_archival == true
    end

    test "normalizes protocol strings" do
      assert SelectionFilters.new(protocol: "http").protocol == :http
      assert SelectionFilters.new(protocol: "ws").protocol == :ws
      assert SelectionFilters.new(protocol: "both").protocol == :both
    end

    test "wraps single exclude value in list" do
      filters = SelectionFilters.new(exclude: "provider_1")
      assert filters.exclude == ["provider_1"]
    end
  end

  describe "from_map/1" do
    test "converts raw map to struct" do
      map = %{
        protocol: :ws,
        exclude: ["p1", "p2"],
        include_half_open: true,
        max_lag_blocks: 10
      }

      filters = SelectionFilters.from_map(map)

      assert filters.protocol == :ws
      assert filters.exclude == ["p1", "p2"]
      assert filters.include_half_open == true
      assert filters.max_lag_blocks == 10
    end

    test "handles string keys" do
      map = %{
        "protocol" => "http",
        "exclude" => ["p1"],
        "requires_archival" => true
      }

      filters = SelectionFilters.from_map(map)

      assert filters.protocol == :http
      assert filters.exclude == ["p1"]
      assert filters.requires_archival == true
    end

    test "handles missing keys with defaults" do
      filters = SelectionFilters.from_map(%{})

      assert filters.protocol == nil
      assert filters.exclude == []
      assert filters.include_half_open == false
    end
  end

  describe "to_map/1" do
    test "converts struct to map" do
      filters =
        SelectionFilters.new(
          protocol: :http,
          exclude: ["p1"],
          requires_archival: true
        )

      map = SelectionFilters.to_map(filters)

      assert map.protocol == :http
      assert map.exclude == ["p1"]
      assert map.requires_archival == true
      assert map.include_half_open == false
    end
  end
end
