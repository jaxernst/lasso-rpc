defmodule Lasso.Core.Transport.HTTP.ResponseHeapRuntimeConfigTest do
  use ExUnit.Case, async: false

  @env_name "LASSO_HTTP_RESPONSE_HEAP_TUNING_ENABLED"

  setup do
    original = System.get_env(@env_name)

    on_exit(fn -> restore_env(original) end)

    :ok
  end

  test "runtime configuration is disabled by default and parses explicit boolean values" do
    for {value, expected} <- [
          {nil, false},
          {"true", true},
          {"1", true},
          {"false", false},
          {"0", false}
        ] do
      assert get_in(runtime_config(value), [:lasso, :http_response_heap_tuning_enabled]) ==
               expected
    end
  end

  test "runtime configuration rejects ambiguous values" do
    assert_raise RuntimeError,
                 "LASSO_HTTP_RESPONSE_HEAP_TUNING_ENABLED must be true, false, 1, or 0",
                 fn -> runtime_config("yes") end
  end

  defp runtime_config(value) do
    restore_env(value)

    base_config = Config.Reader.read!(Path.expand("config/config.exs"), env: :test)
    runtime_config = Config.Reader.read!(Path.expand("config/runtime.exs"), env: :test)
    Config.Reader.merge(base_config, runtime_config)
  end

  defp restore_env(nil), do: System.delete_env(@env_name)
  defp restore_env(value), do: System.put_env(@env_name, value)
end
