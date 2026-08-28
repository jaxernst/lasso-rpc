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
          message_fingerprint: "fingerprint-one",
          data_kind: :none,
          provider_id: "test_provider",
          category: :unclassified_server_error,
          classification_path: :code_based
        }
      )

      :sys.get_state(ErrorClassificationStore)

      assert ErrorClassificationStore.count() >= 1
      entries = ErrorClassificationStore.dump(provider_id: "test_provider")
      assert length(entries) >= 1
      entry = hd(entries)
      assert entry.code == -32_000
      assert entry.category == :unclassified_server_error
      assert entry.classification_path == :code_based
      assert entry.control_category == :unclassified_server_error
      refute entry.shared_control?
      assert entry.count >= 1
      assert entry.message_fingerprint == "fingerprint-one"
      assert entry.data_kind == :none
      refute Map.has_key?(entry, :message)
      refute Map.has_key?(entry, :data_sample)
    end

    test "deduplicates entries by key" do
      metadata = %{
        code: -32_000,
        message_fingerprint: "same-fingerprint",
        data_kind: :none,
        provider_id: "test_provider",
        category: :unclassified_server_error,
        classification_path: :code_based
      }

      :telemetry.execute([:lasso, :error_classification, :classified], %{count: 1}, metadata)
      :telemetry.execute([:lasso, :error_classification, :classified], %{count: 1}, metadata)
      :sys.get_state(ErrorClassificationStore)

      entries = ErrorClassificationStore.dump(provider_id: "test_provider")
      assert length(entries) == 1
      assert hd(entries).count >= 2
    end

    test "keeps classification path and control authority distinct" do
      base = %{
        code: -32_000,
        message_fingerprint: "shared-fingerprint",
        data_kind: :object,
        provider_id: "test_provider",
        category: :rate_limit
      }

      :telemetry.execute(
        [:lasso, :error_classification, :classified],
        %{count: 1},
        Map.merge(base, %{
          classification_path: :message_pattern,
          control_category: :rate_limit,
          shared_control?: false
        })
      )

      :telemetry.execute(
        [:lasso, :error_classification, :classified],
        %{count: 1},
        Map.merge(base, %{
          classification_path: :provider_rule,
          control_category: :unclassified_server_error,
          shared_control?: true
        })
      )

      :sys.get_state(ErrorClassificationStore)

      assert length(ErrorClassificationStore.dump(provider_id: "test_provider")) == 2

      assert [provider_rule] =
               ErrorClassificationStore.dump(
                 provider_id: "test_provider",
                 classification_path: :provider_rule,
                 shared_control?: true
               )

      assert provider_rule.control_category == :unclassified_server_error
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
          message_fingerprint: "disabled-fingerprint",
          data_kind: :none,
          provider_id: "test_disabled",
          category: :unclassified_server_error,
          classification_path: :code_based
        }
      )

      :sys.get_state(ErrorClassificationStore)
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
          message_fingerprint: "filter-fingerprint",
          data_kind: :none,
          provider_id: "filter_test",
          category: :unclassified_server_error,
          classification_path: :code_based
        }
      )

      :sys.get_state(ErrorClassificationStore)

      assert length(ErrorClassificationStore.dump(category: :unclassified_server_error)) >= 1
      assert ErrorClassificationStore.dump(category: :nonexistent) == []
    end
  end
end
