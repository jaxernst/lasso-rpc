defmodule Livechain.RPC.SubscriptionRouter do
  @moduledoc """
  Thin facade used by channels/controllers. Resolves chain and forwards
  to the per-chain `UpstreamSubscriptionPool`.

  MVP policy is single-provider (priority-based) with failover on
  disconnect/close and bounded backfill.
  """

  alias Livechain.RPC.UpstreamSubscriptionPool
  alias Livechain.RPC.FilterNormalizer

  @type key :: {:newHeads} | {:logs, map()}

  @spec subscribe(String.t(), {:newHeads}) :: {:ok, String.t()} | {:error, term()}
  def subscribe(chain, {:newHeads}) do
    UpstreamSubscriptionPool.subscribe_client(chain, self(), {:newHeads})
  end

  @spec subscribe(String.t(), {:logs, map()}) :: {:ok, String.t()} | {:error, term()}
  def subscribe(chain, {:logs, filter}) when is_map(filter) do
    norm = FilterNormalizer.normalize(filter)
    UpstreamSubscriptionPool.subscribe_client(chain, self(), {:logs, norm})
  end

  @spec unsubscribe(String.t(), String.t()) :: :ok | {:error, term()}
  def unsubscribe(chain, subscription_id) do
    UpstreamSubscriptionPool.unsubscribe_client(chain, subscription_id)
  end
end
