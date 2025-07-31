#!/usr/bin/env elixir

# Simple test script for JSON-RPC endpoint
HTTPoison.start()

test_request = %{
  "jsonrpc" => "2.0",
  "method" => "eth_blockNumber",
  "params" => [],
  "id" => 1
}

case HTTPoison.post("http://localhost:4000/rpc/ethereum", Jason.encode!(test_request), [{"Content-Type", "application/json"}]) do
  {:ok, %HTTPoison.Response{status_code: status, body: body}} ->
    IO.puts("Status: #{status}")
    IO.puts("Response: #{body}")

  {:error, %HTTPoison.Error{reason: reason}} ->
    IO.puts("Error: #{reason}")
end
