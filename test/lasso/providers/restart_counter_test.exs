defmodule Lasso.Providers.RestartCounterTest do
  use ExUnit.Case, async: true

  alias Lasso.Providers.RestartCounter

  test "uses conservative backoff when the table is unavailable" do
    assert RestartCounter.update_counter(:missing_restart_counter_table, {:block_sync, "missing"}) ==
             10
  end

  test "clearing remains idempotent when the table is unavailable" do
    assert RestartCounter.clear_counter(
             :missing_restart_counter_table,
             {:block_sync, "missing"}
           ) == :ok
  end
end
