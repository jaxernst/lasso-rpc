defmodule Lasso.JSONConsoleLoggingIntegrationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Logger

  @moduletag :integration

  test "Logger emits parseable JSON with request correlation and redacted upstream URL" do
    output =
      capture_log(
        [format: {Lasso.Logger.JSONFormatter, :format}, metadata: :all],
        fn ->
          Logger.metadata(
            request_id: "request-123",
            chain_id: 1,
            provider_id: "provider-a",
            url: "https://provider.example/v2/private-key"
          )

          Logger.info(
            "Upstream https://provider.example/v2/private-key?api_key=private-key rejected authorization: Bearer another-secret\nretry queued"
          )
        end
      )

    [line] = String.split(output, "\n", trim: true)

    assert %{"level" => "info", "metadata" => metadata, "message" => message} =
             Jason.decode!(line)

    assert metadata["request_id"] == "request-123"
    assert metadata["chain_id"] == 1
    assert metadata["provider_id"] == "provider-a"
    refute Map.has_key?(metadata, "url")
    assert message =~ "https://provider.example"
    assert message =~ "\nretry queued"
    refute message =~ "private-key"
    refute message =~ "another-secret"
  end
end
