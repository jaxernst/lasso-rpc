defmodule Lasso.Events.Subscription do
  @moduledoc """
  Typed, versioned subscription lifecycle events for the dashboard activity feed.

  These structs are broadcast over PubSub to surface WebSocket subscription
  lifecycle moments (established, failed, failover, stale) in the Live Activity feed.
  """

  @topic_prefix "subscription:lifecycle:"

  @spec topic(String.t(), String.t()) :: String.t()
  def topic(profile, chain) when is_binary(profile) and is_binary(chain) do
    "#{@topic_prefix}#{profile}:#{chain}"
  end

  defmodule Established do
    @moduledoc false
    @derive Jason.Encoder
    @enforce_keys [:ts, :chain, :provider_id, :subscription_type]
    defstruct v: 1, ts: nil, chain: nil, provider_id: nil, subscription_type: nil

    @type t :: %__MODULE__{
            v: pos_integer(),
            ts: non_neg_integer(),
            chain: String.t(),
            provider_id: String.t(),
            subscription_type: :new_heads | :logs
          }
  end

  defmodule Failed do
    @moduledoc false
    @derive Jason.Encoder
    @enforce_keys [:ts, :chain, :provider_id, :subscription_type]
    defstruct v: 1, ts: nil, chain: nil, provider_id: nil, subscription_type: nil, reason: nil

    @type t :: %__MODULE__{
            v: pos_integer(),
            ts: non_neg_integer(),
            chain: String.t(),
            provider_id: String.t(),
            subscription_type: :new_heads | :logs,
            reason: term() | nil
          }
  end

  defmodule Failover do
    @moduledoc false
    @derive Jason.Encoder
    @enforce_keys [:ts, :chain, :subscription_type, :from_provider_id, :to_provider_id]

    defstruct v: 1,
              ts: nil,
              chain: nil,
              subscription_type: nil,
              from_provider_id: nil,
              to_provider_id: nil

    @type t :: %__MODULE__{
            v: pos_integer(),
            ts: non_neg_integer(),
            chain: String.t(),
            subscription_type: :new_heads | :logs,
            from_provider_id: String.t() | nil,
            to_provider_id: String.t()
          }
  end

  defmodule Stale do
    @moduledoc false
    @derive Jason.Encoder
    @enforce_keys [:ts, :chain, :provider_id, :subscription_type]

    defstruct v: 1,
              ts: nil,
              chain: nil,
              provider_id: nil,
              subscription_type: nil,
              stale_duration_ms: nil

    @type t :: %__MODULE__{
            v: pos_integer(),
            ts: non_neg_integer(),
            chain: String.t(),
            provider_id: String.t(),
            subscription_type: :new_heads | :logs,
            stale_duration_ms: non_neg_integer() | nil
          }
  end

  @spec kind(struct()) :: atom()
  def kind(%Established{}), do: :subscription_established
  def kind(%Failed{}), do: :subscription_failed
  def kind(%Failover{}), do: :subscription_failover
  def kind(%Stale{}), do: :subscription_stale

  @spec subscription_type(term()) :: :new_heads | :logs
  def subscription_type({:newHeads}), do: :new_heads
  def subscription_type({:logs, _}), do: :logs
end
