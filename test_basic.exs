#!/usr/bin/env elixir

# Start the application
Application.ensure_all_started(:livechain)

# Test basic functionality
alias Livechain.RPC.{MockWSEndpoint, WSSupervisor}

IO.puts("Testing MockWSEndpoint creation...")

# Create a mock endpoint
ethereum = MockWSEndpoint.ethereum_mainnet()
IO.inspect(ethereum, label: "Ethereum endpoint")

# Start the supervisor
{:ok, _supervisor_pid} = WSSupervisor.start_link()
IO.puts("✅ WSSupervisor started")

# Start a connection
{:ok, _connection_pid} = WSSupervisor.start_connection(ethereum)
IO.puts("✅ Mock connection started")

# List connections
connections = WSSupervisor.list_connections()
IO.inspect(connections, label: "Active connections")

IO.puts("✅ Basic test completed successfully!")