defmodule Lasso.Testing.ClusterPubSubForwarder do
  @moduledoc false

  def start(owner, tag, topics) do
    spawn(fn ->
      Enum.each(topics, &Phoenix.PubSub.subscribe(Lasso.PubSub, &1))
      send(owner, {:forwarder_ready, tag, self()})
      forward(owner, tag)
    end)
  end

  defp forward(owner, tag) do
    receive do
      message ->
        send(owner, {tag, message})
        forward(owner, tag)
    end
  end
end
