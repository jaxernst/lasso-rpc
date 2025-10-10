defmodule Lasso.RPC.Caching.MetadataTableOwner do
  @moduledoc """
  Simple GenServer that owns the :blockchain_metadata ETS table.

  This process exists solely to ensure the ETS table persists across
  monitor crashes. When any individual BlockchainMetadataMonitor crashes,
  the cached data remains intact.

  The table is created once during init and never touched again. All reads
  and writes are performed directly by other processes using ETS operations.

  ## Why This Exists

  ETS tables are owned by the process that creates them. If that process dies,
  the table is destroyed. Previously, monitors created the table in init/1,
  causing ALL chains to lose cached data if ANY monitor crashed.

  With this dedicated owner:
  - Table survives individual monitor crashes
  - Data persists across chain supervisor restarts
  - Only destroyed if MetadataTableOwner crashes (which triggers app restart)
  """

  use GenServer
  require Logger

  @table_name :blockchain_metadata

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init([]) do
    # Create ETS table with proper configuration
    # :set - unique keys
    # :public - any process can read/write
    # :named_table - accessible by name instead of tid
    # read_concurrency: true - optimizes for concurrent reads
    table = :ets.new(@table_name, [:set, :public, :named_table, read_concurrency: true])

    Logger.info("MetadataTableOwner created ETS table :blockchain_metadata")

    # Store table reference to keep it alive
    {:ok, %{table: table}}
  end

  @impl true
  def terminate(reason, _state) do
    Logger.warning("MetadataTableOwner terminating: #{inspect(reason)}")
    :ok
  end
end
