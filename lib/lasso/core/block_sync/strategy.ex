defmodule Lasso.BlockSync.Strategy do
  @moduledoc """
  Behavior for block sync transport strategies.

  Strategies are responsible for obtaining block heights from providers
  via a specific transport (WebSocket or HTTP). The Worker orchestrates
  strategies and reports results to the Registry.

  ## Implementations

  - `Lasso.BlockSync.Strategies.HttpStrategy` - HTTP polling via eth_blockNumber
  - `Lasso.BlockSync.Strategies.WsStrategy` - WebSocket subscription to newHeads

  ## Lifecycle

  1. Worker calls `start/3` to initialize the strategy
  2. Strategy sends `{:block_height, height, metadata}` messages to parent
  3. Strategy sends `{:health, latency_ms, success?}` for health metrics
  4. Strategy sends `{:status, status_atom}` for status changes
  5. Worker calls `stop/1` when strategy should terminate
  """

  @type chain :: String.t()
  @type provider_id :: String.t()
  @type height :: non_neg_integer()
  @type source :: :ws | :http
  @type state :: term()

  @type start_opts :: [
          {:poll_interval_ms, pos_integer()}
          | {:staleness_threshold_ms, pos_integer()}
          | {:parent, pid()}
        ]

  @type metadata :: %{
          optional(:hash) => String.t(),
          optional(:timestamp) => non_neg_integer(),
          optional(:latency_ms) => non_neg_integer(),
          optional(:parent_hash) => String.t()
        }

  @doc """
  Start the strategy for a specific provider.

  Returns `{:ok, state}` on success, `{:error, reason}` on failure.
  The state will be passed to subsequent callbacks.

  ## Options
  - `:poll_interval_ms` - For HTTP, interval between polls
  - `:staleness_threshold_ms` - For WS, how long before subscription is stale
  - `:parent` - PID to receive messages (defaults to caller)
  """
  @callback start(chain, provider_id, start_opts) :: {:ok, state} | {:error, term()}

  @doc """
  Stop the strategy and clean up resources.
  """
  @callback stop(state) :: :ok

  @doc """
  Check if the strategy is currently healthy.

  For WS: subscription is active and receiving events
  For HTTP: last poll succeeded
  """
  @callback healthy?(state) :: boolean()

  @doc """
  Get the transport source identifier.
  """
  @callback source() :: source

  @doc """
  Get current status of the strategy.

  Returns a map with strategy-specific status information.
  """
  @callback get_status(state) :: map()

  @doc """
  Handle an incoming message (for strategies that need it).

  Returns `{:ok, new_state}` or `{:stop, reason}`.
  """
  @callback handle_message(message :: term(), state) :: {:ok, state} | {:stop, term()}

  @optional_callbacks [handle_message: 2]
end
