defmodule Lasso.Events.Provider do
  @moduledoc """
  Typed, versioned provider-level events.

  These structs are sent over PubSub directly (BEAM-native). Each event
  includes minimal common fields for routing and filtering and can evolve
  by bumping `v` and adding optional fields.

  Common fields:
  - v: schema version (integer)
  - ts: event timestamp (ms since UNIX epoch)
  - chain: chain name (string)
  - provider_id: provider identifier (string)
  """

  @provider_topic_prefix "provider_pool:events:"

  @doc """
  Returns the per-chain PubSub topic for provider events.
  """
  @spec topic(String.t()) :: String.t()
  def topic(chain) when is_binary(chain), do: @provider_topic_prefix <> chain

  defmodule Healthy do
    @derive Jason.Encoder
    @enforce_keys [:ts, :chain, :provider_id]
    defstruct v: 1, ts: nil, chain: nil, provider_id: nil

    @type t :: %__MODULE__{
            v: pos_integer(),
            ts: non_neg_integer(),
            chain: String.t(),
            provider_id: String.t()
          }
  end

  defmodule Unhealthy do
    @derive Jason.Encoder
    @enforce_keys [:ts, :chain, :provider_id]
    defstruct v: 1, ts: nil, chain: nil, provider_id: nil, reason: nil

    @type t :: %__MODULE__{
            v: pos_integer(),
            ts: non_neg_integer(),
            chain: String.t(),
            provider_id: String.t(),
            reason: term() | nil
          }
  end

  defmodule CooldownStart do
    @derive Jason.Encoder
    @enforce_keys [:ts, :chain, :provider_id, :until]
    defstruct v: 1, ts: nil, chain: nil, provider_id: nil, until: nil

    @type t :: %__MODULE__{
            v: pos_integer(),
            ts: non_neg_integer(),
            chain: String.t(),
            provider_id: String.t(),
            until: non_neg_integer()
          }
  end

  defmodule CooldownEnd do
    @derive Jason.Encoder
    @enforce_keys [:ts, :chain, :provider_id]
    defstruct v: 1, ts: nil, chain: nil, provider_id: nil

    @type t :: %__MODULE__{
            v: pos_integer(),
            ts: non_neg_integer(),
            chain: String.t(),
            provider_id: String.t()
          }
  end

  defmodule HealthCheckFailed do
    @derive Jason.Encoder
    @enforce_keys [:ts, :chain, :provider_id]
    defstruct v: 1,
              ts: nil,
              chain: nil,
              provider_id: nil,
              reason: nil,
              consecutive_failures: nil

    @type t :: %__MODULE__{
            v: pos_integer(),
            ts: non_neg_integer(),
            chain: String.t(),
            provider_id: String.t(),
            reason: term() | nil,
            consecutive_failures: non_neg_integer() | nil
          }
  end

  @doc """
  Returns a concise atom representing the event kind.
  """
  @spec kind(struct()) :: atom()
  def kind(%Healthy{}), do: :healthy
  def kind(%Unhealthy{}), do: :unhealthy
  def kind(%CooldownStart{}), do: :cooldown_start
  def kind(%CooldownEnd{}), do: :cooldown_end
  def kind(%HealthCheckFailed{}), do: :health_check_failed

  defmodule WSDisconnected do
    @derive Jason.Encoder
    @enforce_keys [:ts, :chain, :provider_id]
    defstruct v: 1, ts: nil, chain: nil, provider_id: nil, reason: nil

    @type t :: %__MODULE__{
            v: pos_integer(),
            ts: non_neg_integer(),
            chain: String.t(),
            provider_id: String.t(),
            reason: term() | nil
          }
  end

  defmodule WSClosed do
    @derive Jason.Encoder
    @enforce_keys [:ts, :chain, :provider_id, :code]
    defstruct v: 1, ts: nil, chain: nil, provider_id: nil, code: nil, reason: nil

    @type t :: %__MODULE__{
            v: pos_integer(),
            ts: non_neg_integer(),
            chain: String.t(),
            provider_id: String.t(),
            code: integer(),
            reason: term() | nil
          }
  end

  def kind(%WSDisconnected{}), do: :ws_disconnected
  def kind(%WSClosed{}), do: :ws_closed

  defmodule WSConnected do
    @derive Jason.Encoder
    @enforce_keys [:ts, :chain, :provider_id]
    defstruct v: 1, ts: nil, chain: nil, provider_id: nil

    @type t :: %__MODULE__{
            v: pos_integer(),
            ts: non_neg_integer(),
            chain: String.t(),
            provider_id: String.t()
          }
  end

  def kind(%WSConnected{}), do: :ws_connected
end
