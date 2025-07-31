#!/usr/bin/env elixir

# Simple test script for JSON-RPC endpoint
IO.puts("Testing JSON-RPC endpoint...")

# Test with system command
result = System.cmd("curl", [
  "-s",
  "-X", "POST",
  "-H", "Content-Type: application/json",
  "-d", "{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\",\"params\":[],\"id\":1}",
  "http://localhost:4000/rpc/ethereum"
])

case result do
  {output, 0} ->
    IO.puts("Success!")
    IO.puts("Response: #{output}")
  {error, code} ->
    IO.puts("Error (code #{code}): #{error}")
end
