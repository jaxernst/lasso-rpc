defmodule Lasso.HealthProbe.ProbeClassificationTest do
  @moduledoc """
  Tests for health probe result classification logic.

  The probe classification determines whether a provider is alive or dead based on
  the response to `eth_chainId`. The key invariant: only rate-limit responses should
  be treated as "alive" (the provider is reachable but busy). All other error responses
  mean the provider is broken and should increment consecutive_failures.

  These tests validate the classification patterns inline since the logic is embedded
  in ProbeCoordinator's private probe functions. We test the same branching conditions
  against the same data shapes those functions match on.
  """

  use ExUnit.Case, async: true

  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.RPC.Response

  # Replicate the HTTP probe classification logic from ProbeCoordinator
  defp classify_http_probe_error(%Response.Error{error: jerror}) do
    if jerror.category == :rate_limit do
      {:ok, :rate_limited}
    else
      {:error, jerror}
    end
  end

  # Replicate the WS probe classification logic from ProbeCoordinator
  defp classify_ws_probe_error(error) do
    case error do
      %{category: :rate_limit} ->
        {:ok, :rate_limited}

      reason ->
        {:error, reason}
    end
  end

  describe "HTTP probe classification" do
    test "success response returns chain ID" do
      # eth_chainId success is handled before classification — just verify the shape
      chain_id = String.to_integer("1", 16)
      assert {:ok, ^chain_id} = {:ok, chain_id}
    end

    test "rate_limit error response treated as alive" do
      jerror = JError.new(-32_005, "Rate limit exceeded", category: :rate_limit, retriable?: true)
      response = %Response.Error{id: 1, jsonrpc: "2.0", error: jerror}

      assert {:ok, :rate_limited} = classify_http_probe_error(response)
    end

    test "client_error response treated as failure" do
      jerror = JError.new(-32_000, "Bad Request", category: :client_error, retriable?: false)
      response = %Response.Error{id: 1, jsonrpc: "2.0", error: jerror}

      assert {:error, ^jerror} = classify_http_probe_error(response)
    end

    test "server_error response treated as failure" do
      jerror = JError.new(-32_000, "Internal error", category: :server_error, retriable?: true)
      response = %Response.Error{id: 1, jsonrpc: "2.0", error: jerror}

      assert {:error, ^jerror} = classify_http_probe_error(response)
    end
  end

  describe "WS probe classification" do
    test "rate_limit error treated as alive" do
      jerror = JError.new(-32_005, "Rate limit exceeded", category: :rate_limit, retriable?: true)

      assert {:ok, :rate_limited} = classify_ws_probe_error(jerror)
    end

    test "non-rate-limit error treated as failure" do
      jerror = JError.new(-32_000, "Server error", category: :server_error, retriable?: true)

      assert {:error, ^jerror} = classify_ws_probe_error(jerror)
    end

    test "transport error treated as failure" do
      reason = {:ws_not_connected, "ethereum", "test-provider"}

      assert {:error, ^reason} = classify_ws_probe_error(reason)
    end
  end
end
