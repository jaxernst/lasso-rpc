defmodule TestSupport.FailingWSClient do
  @moduledoc """
  Minimal client that always fails to connect. Used to exercise initial connect
  error paths and reconnection/backoff logic.
  """

  def start_link(_url, _handler_mod, _state) do
    {:error, :econnrefused}
  end

  def start_link(_url, _handler_mod, _state, _opts) do
    {:error, :econnrefused}
  end

  def send_frame(_pid, _frame) do
    {:error, :not_connected}
  end
end
