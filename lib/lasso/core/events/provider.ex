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
  Returns the profile-scoped PubSub topic for provider events.
  """
  @spec topic(String.t(), String.t()) :: String.t()
  def topic(profile, chain) when is_binary(profile) and is_binary(chain) do
    "#{@provider_topic_prefix}#{profile}:#{chain}"
  end

  defmodule Healthy do
    @moduledoc "Event indicating a provider is healthy."
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
    @moduledoc "Event indicating a provider is unhealthy."
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

  defmodule HealthCheckFailed do
    @moduledoc "Event indicating a provider health check failed."
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
  def kind(%HealthCheckFailed{}), do: :health_check_failed

  defmodule WSDisconnected do
    @moduledoc "Event indicating a WebSocket connection was disconnected."
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
    @moduledoc "Event indicating a WebSocket connection was closed."
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
    @moduledoc "Event indicating a WebSocket connection was established."
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
