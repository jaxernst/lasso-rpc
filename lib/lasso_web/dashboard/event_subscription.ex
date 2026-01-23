defmodule LassoWeb.Dashboard.EventSubscription do
  @moduledoc """
  Simple profile-scoped event subscription for OSS.

  Provides helper functions for subscribing to routing and provider events
  with profile-scoped topics to prevent cross-tenant data leakage.
  """

  @doc """
  Subscribes to routing decision events for a specific profile.

  Returns the topic string for later unsubscription.
  """
  @spec subscribe_routing_events(String.t()) :: String.t()
  def subscribe_routing_events(profile) do
    topic = "routing:decisions:#{profile}"
    Phoenix.PubSub.subscribe(Lasso.PubSub, topic)
    topic
  end

  @doc """
  Unsubscribes from a specific topic.
  """
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(topic) do
    Phoenix.PubSub.unsubscribe(Lasso.PubSub, topic)
  end
end
