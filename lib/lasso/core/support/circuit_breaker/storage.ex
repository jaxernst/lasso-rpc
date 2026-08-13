defmodule Lasso.Core.Support.CircuitBreaker.Storage do
  @moduledoc false

  @snapshot_table :lasso_circuit_breaker_snapshots
  @lease_table :lasso_circuit_breaker_leases
  @control_table :lasso_circuit_breaker_control
  @control_meta_table :lasso_circuit_breaker_control_meta

  @spec create_tables!() :: :ok
  def create_tables! do
    create_table(@snapshot_table, [:set, read_concurrency: true, write_concurrency: true])
    create_table(@lease_table, [:set, read_concurrency: true, write_concurrency: true])
    create_table(@control_table, [:set, read_concurrency: true, write_concurrency: true])
    create_table(@control_meta_table, [:set, read_concurrency: true, write_concurrency: true])
    :ok
  end

  @spec snapshot_table() :: atom()
  def snapshot_table, do: @snapshot_table

  @spec lease_table() :: atom()
  def lease_table, do: @lease_table

  @spec control_table() :: atom()
  def control_table, do: @control_table

  @spec control_meta_table() :: atom()
  def control_meta_table, do: @control_meta_table

  defp create_table(name, options) do
    :ets.new(name, [:named_table, :public | options])
  end
end
