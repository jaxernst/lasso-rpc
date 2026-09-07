defmodule LassoWeb.Dashboard.ProviderConnectionTest do
  use ExUnit.Case, async: true

  alias LassoWeb.Dashboard.ProviderConnection

  test "dashboard endpoints retain only their origin" do
    credential = "credential-that-must-not-enter-dashboard-assigns"

    endpoints = [
      "https://rpc.example.test/v2/#{credential}",
      "wss://rpc.example.test/ws?api_key=#{credential}",
      "https://user:#{credential}@rpc.example.test/rpc"
    ]

    Enum.each(endpoints, fn endpoint ->
      safe = ProviderConnection.safe_endpoint(endpoint)
      uri = URI.parse(safe)

      refute safe =~ credential
      assert uri.host == "rpc.example.test"
      assert uri.path in [nil, ""]
      assert uri.query == nil
      assert uri.userinfo == nil
    end)
  end

  test "invalid endpoints do not cross the dashboard boundary" do
    assert ProviderConnection.safe_endpoint("not a URL with secret-value") == nil
    assert ProviderConnection.safe_endpoint(nil) == nil
  end
end
