defmodule Lasso.Benchmarking.PersistenceDirectoryTest do
  use ExUnit.Case, async: false

  alias Lasso.Benchmarking.Persistence

  @tag :tmp_dir
  test "runtime configuration reads a snapshot override without recompilation", %{tmp_dir: dir} do
    original = System.get_env("LASSO_SNAPSHOTS_DIR")
    System.put_env("LASSO_SNAPSHOTS_DIR", dir)

    on_exit(fn ->
      if original,
        do: System.put_env("LASSO_SNAPSHOTS_DIR", original),
        else: System.delete_env("LASSO_SNAPSHOTS_DIR")
    end)

    config = Config.Reader.read!(Path.expand("config/runtime.exs"), env: :test)
    assert config[:lasso][:snapshots_dir] == dir
  end

  @tag :tmp_dir
  test "a runtime-selected directory retains snapshots across collector restarts", %{tmp_dir: dir} do
    previous = Application.fetch_env(:lasso, :snapshots_dir)
    Application.put_env(:lasso, :snapshots_dir, dir)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:lasso, :snapshots_dir, value)
        :error -> Application.delete_env(:lasso, :snapshots_dir)
      end
    end)

    {:ok, state} = Persistence.init([])
    {:noreply, _} = Persistence.handle_cast({:save_snapshot, "public", "1", %{calls: 7}}, state)
    assert [_] = File.ls!(dir)

    {:ok, restarted} = Persistence.init([])

    assert {:reply, [%{"data" => %{"calls" => 7}}], _} =
             Persistence.handle_call({:load_snapshots, "public", "1", 24}, self(), restarted)

    assert {:reply, %{storage_directory: ^dir, total_snapshots: 1}, _} =
             Persistence.handle_call(:get_summary, self(), restarted)
  end
end
