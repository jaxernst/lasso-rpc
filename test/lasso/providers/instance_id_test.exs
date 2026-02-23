defmodule Lasso.Providers.InstanceIdTest do
  use ExUnit.Case, async: true

  alias Lasso.Providers.InstanceId

  describe "derive/3" do
    test "same URL and chain produce the same instance_id" do
      config = %{url: "https://eth.drpc.org", archival: true}
      id1 = InstanceId.derive("ethereum", config)
      id2 = InstanceId.derive("ethereum", config)
      assert id1 == id2
    end

    test "different chains produce different instance_ids" do
      config = %{url: "https://rpc.example.com"}
      id_eth = InstanceId.derive("ethereum", config)
      id_arb = InstanceId.derive("arbitrum", config)
      assert id_eth != id_arb
    end

    test "different URLs produce different instance_ids" do
      config_a = %{url: "https://eth.drpc.org"}
      config_b = %{url: "https://rpc.ankr.com/eth"}
      id_a = InstanceId.derive("ethereum", config_a)
      id_b = InstanceId.derive("ethereum", config_b)
      assert id_a != id_b
    end

    test "different API keys produce different instance_ids" do
      config_a = %{url: "https://eth.drpc.org", api_key: "key_aaa"}
      config_b = %{url: "https://eth.drpc.org", api_key: "key_bbb"}
      id_a = InstanceId.derive("ethereum", config_a)
      id_b = InstanceId.derive("ethereum", config_b)
      assert id_a != id_b
    end

    test "same URL across profiles produces the same instance_id (sharing_mode: :auto)" do
      config = %{url: "https://eth.drpc.org"}
      id_default = InstanceId.derive("ethereum", config, profile: "default")
      id_premium = InstanceId.derive("ethereum", config, profile: "premium")
      assert id_default == id_premium
    end

    test "sharing_mode: :isolated forces unique ids per profile" do
      config = %{url: "https://eth.drpc.org"}

      id_default =
        InstanceId.derive("ethereum", config, profile: "default", sharing_mode: :isolated)

      id_premium =
        InstanceId.derive("ethereum", config, profile: "premium", sharing_mode: :isolated)

      assert id_default != id_premium
    end

    test "format is chain:host_hint:hash_12" do
      config = %{url: "https://eth.drpc.org/path"}
      id = InstanceId.derive("ethereum", config)
      assert id =~ ~r/^ethereum:drpc:[a-f0-9]{12}$/
    end

    test "host_hint extracts penultimate domain part" do
      config = %{url: "https://eth-mainnet.g.alchemy.com/v2/key123"}
      id = InstanceId.derive("ethereum", config)
      assert id =~ ~r/^ethereum:alchemy:/
    end

    test "host_hint for simple two-part domain" do
      config = %{url: "https://rpc.example.com"}
      id = InstanceId.derive("ethereum", config)
      assert id =~ ~r/^ethereum:example:/
    end

    test "sharing_mode: :isolated without profile raises ArgumentError" do
      config = %{url: "https://eth.drpc.org"}

      assert_raise ArgumentError, ~r/profile is required/, fn ->
        InstanceId.derive("ethereum", config, sharing_mode: :isolated)
      end
    end
  end

  describe "normalize_url/1" do
    test "lowercases scheme and host" do
      assert InstanceId.normalize_url("HTTPS://ETH.DRPC.ORG") ==
               InstanceId.normalize_url("https://eth.drpc.org")
    end

    test "strips default HTTPS port 443" do
      assert InstanceId.normalize_url("https://eth.drpc.org:443") ==
               InstanceId.normalize_url("https://eth.drpc.org")
    end

    test "strips default HTTP port 80" do
      assert InstanceId.normalize_url("http://eth.drpc.org:80") ==
               InstanceId.normalize_url("http://eth.drpc.org")
    end

    test "preserves non-default ports" do
      normalized = InstanceId.normalize_url("https://eth.drpc.org:8545")
      assert normalized =~ ":8545"
    end

    test "strips trailing slash" do
      assert InstanceId.normalize_url("https://eth.drpc.org/") ==
               InstanceId.normalize_url("https://eth.drpc.org")
    end

    test "preserves path without trailing slash" do
      normalized = InstanceId.normalize_url("https://eth.drpc.org/v2/key123")
      assert normalized =~ "/v2/key123"
      refute String.ends_with?(normalized, "/v2/key123/")
    end

    test "sorts query parameters" do
      assert InstanceId.normalize_url("https://rpc.example.com?z=1&a=2") ==
               InstanceId.normalize_url("https://rpc.example.com?a=2&z=1")
    end

    test "no query preserves nil query" do
      normalized = InstanceId.normalize_url("https://eth.drpc.org")
      refute normalized =~ "?"
    end

    test "normalizes URL with both path and query" do
      url_a = "https://rpc.example.com/v2/key123?z=1&a=2"
      url_b = "https://rpc.example.com/v2/key123?a=2&z=1"
      assert InstanceId.normalize_url(url_a) == InstanceId.normalize_url(url_b)
      normalized = InstanceId.normalize_url(url_a)
      assert normalized =~ "/v2/key123"
      assert normalized =~ "a=2"
    end

    test "strips default WSS port 443" do
      assert InstanceId.normalize_url("wss://eth.drpc.org:443") ==
               InstanceId.normalize_url("wss://eth.drpc.org")
    end

    test "strips default WS port 80" do
      assert InstanceId.normalize_url("ws://eth.drpc.org:80") ==
               InstanceId.normalize_url("ws://eth.drpc.org")
    end
  end

  describe "auth_fingerprint/1" do
    test "returns nil when no auth configured" do
      assert InstanceId.auth_fingerprint(%{url: "https://example.com"}) == nil
    end

    test "returns nil for empty api_key" do
      assert InstanceId.auth_fingerprint(%{api_key: ""}) == nil
    end

    test "same api_key produces same fingerprint" do
      fp1 = InstanceId.auth_fingerprint(%{api_key: "my-secret-key"})
      fp2 = InstanceId.auth_fingerprint(%{api_key: "my-secret-key"})
      assert fp1 == fp2
      assert is_binary(fp1)
      assert byte_size(fp1) == 12
    end

    test "different api_keys produce different fingerprints" do
      fp1 = InstanceId.auth_fingerprint(%{api_key: "key_aaa"})
      fp2 = InstanceId.auth_fingerprint(%{api_key: "key_bbb"})
      assert fp1 != fp2
    end

    test "auth_headers produce a fingerprint" do
      fp = InstanceId.auth_fingerprint(%{auth_headers: %{"Authorization" => "Bearer token"}})
      assert is_binary(fp)
      assert byte_size(fp) == 12
    end

    test "different auth_headers produce different fingerprints" do
      fp1 = InstanceId.auth_fingerprint(%{auth_headers: %{"Authorization" => "Bearer a"}})
      fp2 = InstanceId.auth_fingerprint(%{auth_headers: %{"Authorization" => "Bearer b"}})
      assert fp1 != fp2
    end

    test "empty auth_headers returns nil" do
      assert InstanceId.auth_fingerprint(%{auth_headers: %{}}) == nil
    end

    test "api_key takes precedence over auth_headers when both present" do
      fp = InstanceId.auth_fingerprint(%{api_key: "my-key", auth_headers: %{"X-Auth" => "val"}})
      fp_key_only = InstanceId.auth_fingerprint(%{api_key: "my-key"})
      assert fp == fp_key_only
    end

    test "returns nil for Provider struct (no api_key/auth_headers fields)" do
      provider = %Lasso.Config.ChainConfig.Provider{
        id: "test",
        name: "Test",
        url: "https://example.com",
        priority: 1
      }

      assert InstanceId.auth_fingerprint(provider) == nil
    end
  end
end
