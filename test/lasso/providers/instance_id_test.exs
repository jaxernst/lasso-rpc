defmodule Lasso.Providers.InstanceIdTest do
  use ExUnit.Case, async: true

  alias Lasso.Providers.InstanceId

  test "shares matching HTTP and WebSocket endpoints" do
    config = %{url: "https://rpc.example.com", ws_url: "wss://rpc.example.com"}
    assert InstanceId.derive(1, config) == InstanceId.derive(1, config)
  end

  test "distinguishes chains and endpoint URLs" do
    config = %{url: "https://rpc.example.com"}
    assert InstanceId.derive(1, config) != InstanceId.derive(10, config)

    assert InstanceId.derive(1, config) !=
             InstanceId.derive(1, %{url: "https://other.example.com"})
  end

  test "different credentials produce different instance identities" do
    first = %{url: "https://rpc.example.com", api_key: "first-key"}
    second = %{url: "https://rpc.example.com", api_key: "second-key"}

    refute InstanceId.auth_fingerprint(first) == InstanceId.auth_fingerprint(second)
    refute InstanceId.derive(1, first) == InstanceId.derive(1, second)
  end

  test "authentication headers are canonicalized before fingerprinting" do
    first = %{url: "https://rpc.example.com", headers: [{"x-api-key", "secret"}, {"x-id", "1"}]}
    second = %{url: "https://rpc.example.com", headers: [{"x-id", "1"}, {"x-api-key", "secret"}]}

    assert InstanceId.auth_fingerprint(first) == InstanceId.auth_fingerprint(second)
    assert InstanceId.derive(1, first) == InstanceId.derive(1, second)
  end

  test "isolated sharing mode salts by profile ID" do
    config = %{url: "https://rpc.example.com"}

    assert InstanceId.derive(1, config, sharing_mode: :isolated, profile_id: "a") !=
             InstanceId.derive(1, config, sharing_mode: :isolated, profile_id: "b")
  end

  test "isolated sharing mode requires a profile ID" do
    assert_raise ArgumentError, fn ->
      InstanceId.derive(1, %{url: "https://rpc.example.com"}, sharing_mode: :isolated)
    end
  end

  test "normalizes equivalent endpoint URLs" do
    assert InstanceId.normalize_url("HTTPS://RPC.EXAMPLE.COM:443/") ==
             InstanceId.normalize_url("https://rpc.example.com")

    assert InstanceId.normalize_url("wss://rpc.example.com:443/") ==
             InstanceId.normalize_url("wss://rpc.example.com")
  end
end
