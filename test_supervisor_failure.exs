#!/usr/bin/env elixir

Mix.install([{:livechain, path: "."}])

alias Livechain.Config.ChainConfig

invalid_config = %ChainConfig{
  chain_id: nil,
  name: "",
  aggregation: %{},
  providers: []
}

IO.puts("Testing ChainSupervisor.start_link with invalid config...")

try do
  result = Livechain.RPC.ChainSupervisor.start_link({"invalid_chain", invalid_config})
  IO.puts("Result: #{inspect(result)}")
  
  case result do
    {:ok, pid} ->
      IO.puts("Started successfully (unexpected)")
      Supervisor.stop(pid)
    {:error, reason} ->
      IO.puts("Failed as expected: #{inspect(reason)}")
  end
rescue
  error ->
    IO.puts("Exception raised: #{inspect(error)}")
end