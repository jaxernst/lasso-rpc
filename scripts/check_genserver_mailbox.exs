#!/usr/bin/env elixir

# Quick diagnostic to check ProviderPool GenServer mailbox depth
# Run with: mix run scripts/check_genserver_mailbox.exs

chain = "ethereum"
pool_pid = GenServer.whereis({:via, Registry, {Lasso.Registry, {:provider_pool, chain}}})

if pool_pid do
  {:message_queue_len, queue_len} = Process.info(pool_pid, :message_queue_len)
  {:memory, memory} = Process.info(pool_pid, :memory)
  {:reductions, reductions} = Process.info(pool_pid, :reductions)

  IO.puts("\n=== ProviderPool GenServer Stats (#{chain}) ===")
  IO.puts("PID: #{inspect(pool_pid)}")
  IO.puts("Mailbox Queue Length: #{queue_len} messages")
  IO.puts("Memory: #{div(memory, 1024)} KB")
  IO.puts("Reductions: #{reductions}")

  if queue_len > 0 do
    IO.puts("\n⚠️  WARNING: Mailbox has #{queue_len} queued messages!")
    IO.puts("This indicates the GenServer is processing slower than requests are arriving.")
  else
    IO.puts("\n✓ Mailbox is empty - GenServer is keeping up with load")
  end
else
  IO.puts("ERROR: Could not find ProviderPool for chain '#{chain}'")
end
