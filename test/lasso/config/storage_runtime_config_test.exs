defmodule Lasso.Config.StorageRuntimeConfigTest do
  use ExUnit.Case, async: false

  @variables ~w(LASSO_DATA_DIR LASSO_PROFILES_DIR LASSO_SNAPSHOTS_DIR)

  setup do
    original = Map.new(@variables, &{&1, System.get_env(&1)})
    Enum.each(@variables, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(original, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)
  end

  test "data directory selects both persisted profiles and snapshots" do
    System.put_env("LASSO_DATA_DIR", "/data")
    config = runtime_config()
    assert config[:lasso][:backend_config][:config][:profiles_dir] == "/data/config/profiles"
    assert config[:lasso][:snapshots_dir] == "/data/benchmark_snapshots"
  end

  test "explicit directories override the shared data directory" do
    System.put_env("LASSO_DATA_DIR", "/data")
    System.put_env("LASSO_PROFILES_DIR", "/config")
    System.put_env("LASSO_SNAPSHOTS_DIR", "/history")
    config = runtime_config()
    assert config[:lasso][:backend_config][:config][:profiles_dir] == "/config"
    assert config[:lasso][:snapshots_dir] == "/history"
  end

  test "without overrides existing backend configuration is preserved" do
    config = runtime_config()
    assert config[:lasso][:backend_config][:config][:profiles_dir] == "test/support/profiles"
    assert config[:lasso][:snapshots_dir] == "priv/benchmark_snapshots"
  end

  defp runtime_config do
    base = Config.Reader.read!(Path.expand("config/config.exs"), env: :test)
    runtime = Config.Reader.read!(Path.expand("config/runtime.exs"), env: :test)
    Config.Reader.merge(base, runtime)
  end
end
