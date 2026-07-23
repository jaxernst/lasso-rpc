defmodule Lasso.Core.Streaming.SubscriptionRouter do
  @moduledoc """
  Thin facade used by channels/controllers. Resolves chain and forwards
  to the per-chain `UpstreamSubscriptionPool`.

  MVP policy is single-provider (priority-based) with failover on
  disconnect/close and bounded backfill.
  """

  alias Lasso.Core.Streaming.UpstreamSubscriptionPool
  alias Lasso.Core.Support.FilterNormalizer

  @type key :: {:newHeads} | {:logs, map()}

  @spec subscribe(String.t(), pos_integer(), key(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def subscribe(profile, chain_id, key, opts \\ [])

  def subscribe(profile, chain_id, {:newHeads}, opts)
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    UpstreamSubscriptionPool.subscribe_client(profile, chain_id, self(), {:newHeads}, opts)
  end

  def subscribe(profile, chain_id, {:logs, filter}, opts)
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 and is_map(filter) do
    norm = FilterNormalizer.normalize(filter)
    UpstreamSubscriptionPool.subscribe_client(profile, chain_id, self(), {:logs, norm}, opts)
  end

  @spec unsubscribe(String.t(), pos_integer(), String.t()) :: :ok | {:error, term()}
  def unsubscribe(profile, chain_id, subscription_id)
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    UpstreamSubscriptionPool.unsubscribe_client(profile, chain_id, subscription_id)
  end
end
