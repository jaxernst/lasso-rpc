#!/usr/bin/env elixir

# Test script to verify JSON-RPC error response consistency across HTTP and WebSocket

defmodule ErrorConsistencyTest do
  alias Livechain.RPC.Error
  
  def run do
    IO.puts("\n=== Testing JSON-RPC Error Response Consistency ===\n")
    
    # Test various error scenarios
    test_error_normalization()
    test_provider_error_mapping()
    test_nested_error_handling()
    
    IO.puts("\n=== All tests completed ===\n")
  end
  
  defp test_error_normalization do
    IO.puts("1. Testing error normalization:")
    
    # Test typed errors
    test_cases = [
      {:rate_limit, "Too many requests"},
      {:server_error, "Server unavailable"},
      {:client_error, "Invalid parameters"},
      {:network_error, "Connection timeout"},
      {:decode_error, "Invalid JSON"},
      {:circuit_open, "Provider circuit open"},
      "Simple string error",
      :atom_error
    ]
    
    for error <- test_cases do
      normalized = Error.normalize(error, 123)
      IO.puts("   Input: #{inspect(error, limit: 50)}")
      IO.puts("   Output: #{inspect(normalized, pretty: true, limit: :infinity)}")
      
      # Verify JSON-RPC 2.0 compliance
      assert_json_rpc_compliant(normalized)
      IO.puts("   ✓ JSON-RPC 2.0 compliant\n")
    end
  end
  
  defp test_provider_error_mapping do
    IO.puts("2. Testing provider error mapping:")
    
    provider_errors = [
      %{"code" => -32005, "message" => "Rate limit exceeded"},
      %{"code" => 429, "message" => "Too many requests"},
      %{"code" => 4001, "message" => "User rejected"},
      %{"code" => -32700, "message" => "Parse error"},
      %{"error" => %{"code" => -32602, "message" => "Invalid params"}}
    ]
    
    for error <- provider_errors do
      normalized = Error.normalize_error(error)
      IO.puts("   Provider error: #{inspect(error)}")
      IO.puts("   Normalized: #{inspect(normalized)}")
      
      # Check that nested errors are flattened
      refute_nested_error(normalized)
      IO.puts("   ✓ No nested errors\n")
    end
  end
  
  defp test_nested_error_handling do
    IO.puts("3. Testing nested error handling:")
    
    # Simulate provider returning nested error structure
    nested_error = %{
      "error" => %{
        "code" => -32005,
        "message" => "Rate limit exceeded",
        "data" => %{"retry_after" => 60}
      }
    }
    
    normalized = Error.normalize_error(nested_error)
    IO.puts("   Nested error: #{inspect(nested_error)}")
    IO.puts("   Normalized: #{inspect(normalized)}")
    
    # Verify it's flattened
    assert normalized["code"] == -32005
    assert normalized["message"] == "Rate limit exceeded"
    assert normalized["data"]["retry_after"] == 60
    refute Map.has_key?(normalized, "error")
    IO.puts("   ✓ Properly flattened\n")
  end
  
  defp assert_json_rpc_compliant(response) do
    # Check required fields
    assert response["jsonrpc"] == "2.0"
    assert is_map(response["error"])
    assert is_integer(response["error"]["code"])
    assert is_binary(response["error"]["message"])
    assert Map.has_key?(response, "id")
    
    # Check error code is in valid range
    code = response["error"]["code"]
    assert code >= -32768 and code <= -32000
  end
  
  defp refute_nested_error(error) do
    refute Map.has_key?(error, "error")
    refute Map.has_key?(error, :error)
  end
  
  defp assert(true), do: :ok
  defp assert(false), do: raise "Assertion failed"
  
  defp refute(false), do: :ok
  defp refute(true), do: raise "Refutation failed"
end

# Run the tests
ErrorConsistencyTest.run()