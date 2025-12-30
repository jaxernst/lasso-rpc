defmodule Lasso.RPC.SubscriptionRouter do
  @moduledoc """
  Thin facade used by channels/controllers. Resolves chain and forwards
  to the per-chain `UpstreamSubscriptionPool`.

  MVP policy is single-provider (priority-based) with failover on
  disconnect/close and bounded backfill.
  """

  alias Lasso.RPC.UpstreamSubscriptionPool
  alias Lasso.RPC.FilterNormalizer

  @type key :: {:newHeads} | {:logs, map()}

  @spec subscribe(String.t(), String.t(), {:newHeads}) :: {:ok, String.t()} | {:error, term()}
  def subscribe(profile, chain, {:newHeads})
      when is_binary(profile) and is_binary(chain) do
    UpstreamSubscriptionPool.subscribe_client(profile, chain, self(), {:newHeads})
  end

  @spec subscribe(String.t(), String.t(), {:logs, map()}) :: {:ok, String.t()} | {:error, term()}
  def subscribe(profile, chain, {:logs, filter})
      when is_binary(profile) and is_binary(chain) and is_map(filter) do
    norm = FilterNormalizer.normalize(filter)
    UpstreamSubscriptionPool.subscribe_client(profile, chain, self(), {:logs, norm})
  end

  @spec unsubscribe(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def unsubscribe(profile, chain, subscription_id)
      when is_binary(profile) and is_binary(chain) do
    UpstreamSubscriptionPool.unsubscribe_client(profile, chain, subscription_id)
  end
end
