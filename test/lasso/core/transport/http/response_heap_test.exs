defmodule Lasso.Core.Transport.HTTP.ResponseHeapTest do
  use ExUnit.Case, async: false

  alias Lasso.RPC.Transports.HTTP

  setup do
    previous = HTTP.response_heap_tuning_enabled?()

    on_exit(fn ->
      HTTP.configure_response_heap_tuning(previous)
    end)

    :ok
  end

  test "disabled tuning preserves the task heap" do
    HTTP.configure_response_heap_tuning(false)

    assert {:ok, before_min_heap, after_min_heap} = heap_probe()
    assert after_min_heap == before_min_heap
  end

  test "enabled tuning expands the task heap to the bounded validation class" do
    HTTP.configure_response_heap_tuning(true)

    assert {:ok, before_min_heap, 4_185} = heap_probe()
    assert before_min_heap < 4_185
  end

  defp heap_probe do
    task =
      Task.async(fn ->
        before_min_heap = min_heap_size()
        :ok = HTTP.tune_response_heap()
        {:ok, before_min_heap, min_heap_size()}
      end)

    Task.await(task)
  end

  defp min_heap_size do
    {:garbage_collection, options} = Process.info(self(), :garbage_collection)
    Keyword.fetch!(options, :min_heap_size)
  end
end
