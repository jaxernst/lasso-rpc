defmodule Lasso.ApplicationTest do
  use ExUnit.Case, async: false

  test "builds a bounded HTTP pool from runtime configuration" do
    previous = Application.fetch_env!(:lasso, :http_pool)
    on_exit(fn -> Application.put_env(:lasso, :http_pool, previous) end)

    Application.put_env(:lasso, :http_pool, size: 192, count: 2)

    options = Lasso.Application.http_pool_options()
    assert options[:size] == 192
    assert options[:count] == 2
    assert options[:protocols] == [:http1]
  end

  test "rejects invalid HTTP pool bounds" do
    previous = Application.fetch_env!(:lasso, :http_pool)
    on_exit(fn -> Application.put_env(:lasso, :http_pool, previous) end)

    Application.put_env(:lasso, :http_pool, size: 0, count: 1)

    assert_raise ArgumentError, "http pool size must be a positive integer", fn ->
      Lasso.Application.http_pool_options()
    end
  end
end
