defmodule Lasso.HealthProbe.WorkerTest do
  @moduledoc """
  Unit tests for HealthProbe.Worker.

  Tests the core functionality:
  - Worker status queries
  - Integration with actual health probing is covered in integration tests
  """

  use ExUnit.Case, async: false

  alias Lasso.HealthProbe.Worker

  @test_profile "default"

  setup_all do
    TestHelper.ensure_test_environment_ready()
    :ok
  end

  describe "get_status/3" do
    test "returns error for non-running worker" do
      chain = "nonexistent_chain_#{System.unique_integer([:positive])}"
      provider_id = "nonexistent_provider"

      assert {:error, :not_running} = Worker.get_status(chain, @test_profile, provider_id)
    end
  end

  # Circuit breaker integration is thoroughly tested in:
  # - circuit_breaker_test.exs (unit tests)
  # - health_probe_integration_test.exs (end-to-end scenarios)
  # Removed redundant circuit breaker tests that didn't exercise HealthProbe.Worker code
end
