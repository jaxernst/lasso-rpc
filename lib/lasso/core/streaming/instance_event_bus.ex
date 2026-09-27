defmodule Lasso.Core.Streaming.InstanceEventBus do
  @moduledoc """
  Node-local delivery for physical upstream WebSocket control facts.

  Every Lasso node owns an independent socket, subscription manager, transport
  registry, and block-sync worker for a provider instance. Connection IDs,
  upstream subscription IDs, raw payloads, and manager generations are valid
  only inside that owning runtime and must not enter the clustered PubSub plane.
  """

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(topic) when is_binary(topic) do
    Phoenix.PubSub.subscribe(Lasso.PubSub, topic)
  end

  @spec broadcast(String.t(), term()) :: :ok | {:error, term()}
  def broadcast(topic, event) when is_binary(topic) do
    Phoenix.PubSub.local_broadcast(Lasso.PubSub, topic, event)
  end
end
