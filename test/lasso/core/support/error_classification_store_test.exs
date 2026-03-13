defmodule Lasso.Core.Support.ErrorClassificationStoreTest do
  use ExUnit.Case, async: false

  alias Lasso.Core.Support.ErrorClassificationStore

  setup do
    # Clear the store before each test
    if :ets.info(:lasso_error_classification_store) != :undefined do
      ErrorClassificationStore.clear()
    end

    :ok
  end

  describe "telemetry-driven recording" do
    test "records events for sampled codes" do
      :telemetry.execute(
        [:lasso, :error_classification, :classified],
        %{count: 1},
        %{
          code: -32_000,
          message: "something unknown",
          data_present: false,
          provider_id: "test_provider",
          category: :unclassified_server_error,
          classification_path: :code_based
        }
      )

      # Give the GenServer time to process the cast
      Process.sleep(50)

      assert ErrorClassificationStore.count() >= 1
      entries = ErrorClassificationStore.dump(provider_id: "test_provider")
      assert length(entries) >= 1
      entry = hd(entries)
      assert entry.code == -32_000
      assert entry.category == :unclassified_server_error
      assert entry.classification_path == :code_based
      assert entry.count >= 1
    end

    test "deduplicates entries by key" do
      metadata = %{
        code: -32_000,
        message: "same error message",
        data_present: false,
        provider_id: "test_provider",
        category: :unclassified_server_error,
        classification_path: :code_based
      }

      :telemetry.execute([:lasso, :error_classification, :classified], %{count: 1}, metadata)
      Process.sleep(50)
      :telemetry.execute([:lasso, :error_classification, :classified], %{count: 1}, metadata)
      Process.sleep(50)

      entries = ErrorClassificationStore.dump(provider_id: "test_provider")
      assert length(entries) == 1
      assert hd(entries).count >= 2
    end
  end

  describe "configure/1" do
    test "can disable sampling" do
      ErrorClassificationStore.configure(%{enabled: false})

      :telemetry.execute(
        [:lasso, :error_classification, :classified],
        %{count: 1},
        %{
          code: -32_000,
          message: "should not be recorded",
          data_present: false,
          provider_id: "test_disabled",
          category: :unclassified_server_error,
          classification_path: :code_based
        }
      )

      Process.sleep(50)
      entries = ErrorClassificationStore.dump(provider_id: "test_disabled")
      assert entries == []

      # Re-enable for other tests
      ErrorClassificationStore.configure(%{enabled: true})
    end
  end

  describe "dump/1 filters" do
    test "filters by category" do
      :telemetry.execute(
        [:lasso, :error_classification, :classified],
        %{count: 1},
        %{
          code: -32_000,
          message: "test filter",
          data_present: false,
          provider_id: "filter_test",
          category: :unclassified_server_error,
          classification_path: :code_based
        }
      )

      Process.sleep(50)

      assert length(ErrorClassificationStore.dump(category: :unclassified_server_error)) >= 1
      assert ErrorClassificationStore.dump(category: :nonexistent) == []
    end
  end
end
