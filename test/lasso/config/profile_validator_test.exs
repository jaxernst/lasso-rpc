defmodule Lasso.Config.ProfileValidatorTest do
  use ExUnit.Case, async: false

  import Lasso.Config.ProfileValidator, only: [is_valid_profile: 1]
  alias Lasso.Config.{ConfigStore, ProfileValidator}

  describe "validate/1" do
    test "returns ok for valid existing profile" do
      # "default" and "testnet" profiles exist in test config
      assert {:ok, "default"} = ProfileValidator.validate("default")
      assert {:ok, "testnet"} = ProfileValidator.validate("testnet")
    end

    test "trims whitespace from valid profiles" do
      assert {:ok, "default"} = ProfileValidator.validate("  default  ")
      assert {:ok, "testnet"} = ProfileValidator.validate("\ttestnet\n")
    end

    test "returns profile_nil error for nil" do
      assert {:error, :profile_nil, msg} = ProfileValidator.validate(nil)
      assert msg =~ "required"
    end

    test "returns profile_empty error for empty string" do
      assert {:error, :profile_empty, msg} = ProfileValidator.validate("")
      assert msg =~ "empty"
    end

    test "returns profile_empty error for whitespace-only string" do
      assert {:error, :profile_empty, msg} = ProfileValidator.validate("   ")
      assert msg =~ "empty"
    end

    test "returns profile_invalid_type error for non-string types" do
      assert {:error, :profile_invalid_type, msg} = ProfileValidator.validate(123)
      assert msg =~ "string"
      assert msg =~ "123"

      assert {:error, :profile_invalid_type, msg} = ProfileValidator.validate(:atom)
      assert msg =~ "string"

      assert {:error, :profile_invalid_type, msg} = ProfileValidator.validate(%{})
      assert msg =~ "string"

      assert {:error, :profile_invalid_type, msg} = ProfileValidator.validate([])
      assert msg =~ "string"
    end

    test "returns profile_not_found error for nonexistent profile" do
      assert {:error, :profile_not_found, msg} =
               ProfileValidator.validate("nonexistent_profile_xyz")

      assert msg =~ "not found"
      assert msg =~ "nonexistent_profile_xyz"
    end

    test "handles ConfigStore errors gracefully" do
      # Profile that doesn't exist should return not_found error
      assert {:error, :profile_not_found, msg} = ProfileValidator.validate("missing")
      assert msg =~ "not found"
    end
  end

  describe "validate_with_default/1" do
    test "returns 'default' for nil input" do
      assert {:ok, "default"} = ProfileValidator.validate_with_default(nil)
    end

    test "returns 'default' for empty string" do
      assert {:ok, "default"} = ProfileValidator.validate_with_default("")
    end

    test "returns 'default' for whitespace-only string" do
      assert {:ok, "default"} = ProfileValidator.validate_with_default("   ")
      assert {:ok, "default"} = ProfileValidator.validate_with_default("\t\n")
    end

    test "returns validated profile for valid non-empty string" do
      assert {:ok, "testnet"} = ProfileValidator.validate_with_default("testnet")
      assert {:ok, "testnet"} = ProfileValidator.validate_with_default("  testnet  ")
    end

    test "returns error for invalid types even with default fallback" do
      assert {:error, :profile_invalid_type, _} = ProfileValidator.validate_with_default(123)
      assert {:error, :profile_invalid_type, _} = ProfileValidator.validate_with_default(:atom)
    end

    test "returns error for nonexistent profile" do
      assert {:error, :profile_not_found, _} =
               ProfileValidator.validate_with_default("nonexistent")
    end
  end

  describe "validate!/1" do
    test "returns validated profile for valid input" do
      assert "default" = ProfileValidator.validate!("default")
      assert "testnet" = ProfileValidator.validate!("testnet")
    end

    test "trims whitespace" do
      assert "default" = ProfileValidator.validate!("  default  ")
    end

    test "raises ArgumentError for nil" do
      assert_raise ArgumentError, ~r/required/, fn ->
        ProfileValidator.validate!(nil)
      end
    end

    test "raises ArgumentError for empty string" do
      assert_raise ArgumentError, ~r/empty/, fn ->
        ProfileValidator.validate!("")
      end
    end

    test "raises ArgumentError for invalid type" do
      assert_raise ArgumentError, ~r/string/, fn ->
        ProfileValidator.validate!(123)
      end
    end

    test "raises ArgumentError for nonexistent profile" do
      assert_raise ArgumentError, ~r/not found/, fn ->
        ProfileValidator.validate!("nonexistent_profile_xyz")
      end
    end
  end

  describe "is_valid_profile/1 guard" do
    # Test the guard by using it in a function
    defp test_guard(profile) when is_valid_profile(profile) do
      :valid
    end

    defp test_guard(_profile), do: :invalid

    test "accepts non-empty strings" do
      assert :valid = test_guard("default")
      assert :valid = test_guard("testnet")
      assert :valid = test_guard("x")
    end

    test "rejects nil" do
      assert :invalid = test_guard(nil)
    end

    test "rejects empty string" do
      assert :invalid = test_guard("")
    end

    test "rejects non-string types" do
      assert :invalid = test_guard(123)
      assert :invalid = test_guard(:atom)
      assert :invalid = test_guard(%{})
      assert :invalid = test_guard([])
    end

    test "accepts strings with whitespace (guard doesn't trim)" do
      # Note: Guard only checks type and size, doesn't trim
      assert :valid = test_guard("  default  ")
    end
  end

  describe "error_to_http_status/1" do
    test "returns 400 for parameter validation errors" do
      assert 400 = ProfileValidator.error_to_http_status(:profile_nil)
      assert 400 = ProfileValidator.error_to_http_status(:profile_invalid_type)
      assert 400 = ProfileValidator.error_to_http_status(:profile_empty)
    end

    test "returns 503 for profile not found" do
      assert 503 = ProfileValidator.error_to_http_status(:profile_not_found)
    end
  end

  describe "error_to_jsonrpc_code/1" do
    test "returns -32602 (Invalid params) for parameter validation errors" do
      assert -32_602 = ProfileValidator.error_to_jsonrpc_code(:profile_nil)
      assert -32_602 = ProfileValidator.error_to_jsonrpc_code(:profile_invalid_type)
      assert -32_602 = ProfileValidator.error_to_jsonrpc_code(:profile_empty)
    end

    test "returns -32000 (Server error) for profile not found" do
      assert -32_000 = ProfileValidator.error_to_jsonrpc_code(:profile_not_found)
    end
  end

  describe "integration with ConfigStore" do
    test "validates against actual ConfigStore profiles" do
      # Get list of configured profiles
      profiles = ConfigStore.list_profiles()

      # All configured profiles should validate
      for profile <- profiles do
        assert {:ok, ^profile} = ProfileValidator.validate(profile)
      end
    end

    test "rejects profiles not in ConfigStore" do
      # Test with a profile that definitely doesn't exist
      fake_profile = "test_profile_#{System.unique_integer([:positive])}"

      assert {:error, :profile_not_found, _} = ProfileValidator.validate(fake_profile)
    end
  end
end
