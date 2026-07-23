defmodule Lasso.Providers.ProviderHeadersTest do
  use ExUnit.Case, async: true

  alias Lasso.Providers.ProviderHeaders

  test "builds bearer and configured transport headers with explicit auth precedence" do
    headers =
      ProviderHeaders.build(%{
        api_key: "fallback-token",
        headers: %{"x-provider" => "provider-value"},
        auth_headers: [{"Authorization", "Basic explicit"}]
      })
      |> Map.new()

    assert headers["content-type"] == "application/json"
    assert headers["accept"] == "application/json"
    assert headers["x-provider"] == "provider-value"
    assert headers["authorization"] == "Basic explicit"
  end

  test "ignores malformed headers" do
    headers =
      ProviderHeaders.build(%{headers: [{:invalid, nil}, {:valid, "value"}, :invalid]})

    assert {"valid", "value"} in headers
    refute Enum.any?(headers, fn {key, _value} -> key == "invalid" end)
  end
end
