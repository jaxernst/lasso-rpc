defmodule Lasso.JSONRPC.SubscriptionParams do
  @moduledoc false

  alias Lasso.JSONRPC.Error, as: JError

  @type key :: {:newHeads} | {:logs, map()}

  @spec subscribe_key(term()) :: {:ok, key()} | {:error, JError.t()}
  def subscribe_key(["newHeads"]), do: {:ok, {:newHeads}}
  def subscribe_key(["logs"]), do: {:ok, {:logs, %{}}}
  def subscribe_key(["logs", filter]) when is_map(filter), do: {:ok, {:logs, filter}}
  def subscribe_key(_params), do: {:error, invalid_params()}

  @spec unsubscribe_id(term()) :: {:ok, String.t()} | {:error, JError.t()}
  def unsubscribe_id([subscription_id]) when is_binary(subscription_id),
    do: {:ok, subscription_id}

  def unsubscribe_id(_params), do: {:error, invalid_params()}

  defp invalid_params do
    JError.new(-32_602, "Invalid subscription parameters", category: :invalid_params)
  end
end
