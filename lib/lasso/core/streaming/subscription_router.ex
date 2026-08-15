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
    UpstreamSubscriptionPool.subscribe_client(
      profile,
      chain_id,
      client_pid(opts),
      {:newHeads},
      opts
    )
  end

  def subscribe(profile, chain_id, {:logs, filter}, opts)
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 and is_map(filter) do
    norm = FilterNormalizer.normalize(filter)

    UpstreamSubscriptionPool.subscribe_client(
      profile,
      chain_id,
      client_pid(opts),
      {:logs, norm},
      opts
    )
  end

  @spec subscribe_request(String.t(), pos_integer(), key(), keyword()) :: term()
  def subscribe_request(profile, chain_id, key, opts \\ [])

  def subscribe_request(profile, chain_id, {:newHeads}, opts)
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    UpstreamSubscriptionPool.subscribe_client_request(
      profile,
      chain_id,
      client_pid(opts),
      {:newHeads},
      opts
    )
  end

  def subscribe_request(profile, chain_id, {:logs, filter}, opts)
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 and is_map(filter) do
    UpstreamSubscriptionPool.subscribe_client_request(
      profile,
      chain_id,
      client_pid(opts),
      {:logs, FilterNormalizer.normalize(filter)},
      opts
    )
  end

  @spec unsubscribe(String.t(), pos_integer(), String.t()) :: :ok | {:error, term()}
  def unsubscribe(profile, chain_id, subscription_id)
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    UpstreamSubscriptionPool.unsubscribe_client(profile, chain_id, subscription_id)
  end

  @spec unsubscribe_checked(String.t(), pos_integer(), String.t(), keyword()) ::
          {:ok, boolean()} | {:error, term()}
  def unsubscribe_checked(profile, chain_id, subscription_id, opts \\ [])
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    UpstreamSubscriptionPool.unsubscribe_client_checked(profile, chain_id, subscription_id, opts)
  end

  @spec unsubscribe_checked_request(String.t(), pos_integer(), String.t(), keyword()) :: term()
  def unsubscribe_checked_request(profile, chain_id, subscription_id, opts \\ [])
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    UpstreamSubscriptionPool.unsubscribe_client_checked_request(
      profile,
      chain_id,
      subscription_id,
      opts
    )
  end

  @spec check_response(term(), term()) :: term()
  def check_response(message, request_id) do
    UpstreamSubscriptionPool.check_response(message, request_id)
  end

  defp client_pid(opts) do
    case Keyword.get(opts, :client_pid, self()) do
      pid when is_pid(pid) -> pid
      invalid -> raise ArgumentError, "client_pid must be a pid, got: #{inspect(invalid)}"
    end
  end
end
