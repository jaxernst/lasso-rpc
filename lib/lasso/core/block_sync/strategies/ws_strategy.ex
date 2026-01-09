defmodule Lasso.BlockSync.Strategies.WsStrategy do
  @moduledoc """
  WebSocket subscription strategy for block sync.

  Subscribes to `newHeads` via UpstreamSubscriptionManager and reports:
  - Block heights with rich metadata (hash, timestamp)
  - Status changes (active, stale, failed)

  ## Staleness Detection

  If no newHeads events are received within `staleness_threshold_ms`, the
  strategy reports itself as stale. The Worker can then start HTTP fallback.

  ## Messages sent to parent

  - `{:block_height, height, %{hash: h, timestamp: ts, parent_hash: ph}}`
  - `{:status, :active | :stale | :failed}`

  ## Events received

  Events come via Registry dispatch from UpstreamSubscriptionManager:
  - `{:upstream_subscription_event, provider_id, {:newHeads}, payload, received_at}`
  - `{:upstream_subscription_invalidated, provider_id, {:newHeads}, reason}`
  """

  @behaviour Lasso.BlockSync.Strategy

  require Logger

  alias Lasso.Core.Streaming.UpstreamSubscriptionManager

  @default_staleness_threshold_ms 35_000

  defstruct [
    :profile,
    :chain,
    :provider_id,
    :parent,
    :staleness_threshold_ms,
    :staleness_timer_ref,
    :status,
    :last_block_time,
    :last_height,
    :subscription_status
  ]

  @type t :: %__MODULE__{
          profile: String.t(),
          chain: String.t(),
          provider_id: String.t(),
          parent: pid(),
          staleness_threshold_ms: non_neg_integer(),
          staleness_timer_ref: reference() | nil,
          status: atom(),
          last_block_time: integer() | nil,
          last_height: non_neg_integer() | nil,
          subscription_status: atom()
        }

  ## Strategy Callbacks

  @impl true
  def start(chain, provider_id, opts) do
    profile = Keyword.fetch!(opts, :profile)
    parent = Keyword.get(opts, :parent, self())

    staleness_threshold =
      Keyword.get(opts, :staleness_threshold_ms, @default_staleness_threshold_ms)

    state = %__MODULE__{
      profile: profile,
      chain: chain,
      provider_id: provider_id,
      parent: parent,
      staleness_threshold_ms: staleness_threshold,
      staleness_timer_ref: nil,
      status: :connecting,
      last_block_time: nil,
      last_height: nil,
      subscription_status: :pending
    }

    # Attempt to subscribe
    case do_subscribe(state) do
      {:ok, new_state} ->
        # Start staleness timer
        new_state = schedule_staleness_check(new_state)
        {:ok, new_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def stop(%__MODULE__{
        staleness_timer_ref: ref,
        profile: profile,
        chain: chain,
        provider_id: provider_id
      }) do
    if ref, do: Process.cancel_timer(ref)

    # Release our subscription from the manager
    UpstreamSubscriptionManager.release_subscription(profile, chain, provider_id, {:newHeads})

    :ok
  end

  @impl true
  def healthy?(%__MODULE__{status: status}) do
    status == :active
  end

  @impl true
  def source, do: :ws

  @impl true
  def get_status(%__MODULE__{} = state) do
    %{
      status: state.status,
      subscription_status: state.subscription_status,
      last_height: state.last_height,
      last_block_time: state.last_block_time,
      staleness_threshold_ms: state.staleness_threshold_ms
    }
  end

  @impl true
  def handle_message(
        {:upstream_subscription_event, provider_id, {:newHeads}, payload, _received_at},
        state
      )
      when provider_id == state.provider_id do
    new_state = process_new_head(state, payload)
    {:ok, new_state}
  end

  def handle_message(
        {:upstream_subscription_invalidated, provider_id, {:newHeads}, reason},
        state
      )
      when provider_id == state.provider_id do
    Logger.debug("WS subscription invalidated",
      chain: state.chain,
      provider_id: provider_id,
      reason: inspect(reason)
    )

    new_state = %{state | status: :failed, subscription_status: :invalidated}
    send(state.parent, {:status, state.provider_id, :ws, :failed})

    {:ok, new_state}
  end

  def handle_message(:check_staleness, state) do
    new_state = check_staleness(state)
    new_state = schedule_staleness_check(new_state)
    {:ok, new_state}
  end

  def handle_message(_other, state) do
    {:ok, state}
  end

  ## Public API (for Worker to call when it receives WS events)

  @doc """
  Process an incoming newHeads event.
  """
  @spec handle_new_head(t(), map()) :: t()
  def handle_new_head(%__MODULE__{} = state, payload) do
    process_new_head(state, payload)
  end

  @doc """
  Handle subscription invalidation.
  """
  @spec handle_invalidation(t(), term()) :: t()
  def handle_invalidation(%__MODULE__{} = state, reason) do
    Logger.debug("WS subscription invalidated",
      chain: state.chain,
      provider_id: state.provider_id,
      reason: inspect(reason)
    )

    new_state = %{state | status: :failed, subscription_status: :invalidated}
    send(state.parent, {:status, state.provider_id, :ws, :failed})

    new_state
  end

  @doc """
  Re-subscribe after connection recovery.
  """
  @spec resubscribe(t()) :: {:ok, t()} | {:error, term()}
  def resubscribe(%__MODULE__{} = state) do
    case do_subscribe(state) do
      {:ok, new_state} ->
        {:ok, schedule_staleness_check(new_state)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## Private Functions

  defp do_subscribe(state) do
    case UpstreamSubscriptionManager.ensure_subscription(
           state.profile,
           state.chain,
           state.provider_id,
           {:newHeads}
         ) do
      {:ok, status} ->
        Logger.debug("WS newHeads subscription registered",
          chain: state.chain,
          provider_id: state.provider_id,
          status: status
        )

        new_state = %{state | status: :active, subscription_status: status}
        send(state.parent, {:status, state.provider_id, :ws, :active})
        {:ok, new_state}

      {:error, reason} ->
        Logger.warning("WS subscription failed",
          chain: state.chain,
          provider_id: state.provider_id,
          reason: inspect(reason)
        )

        send(state.parent, {:status, state.provider_id, :ws, :failed})
        {:error, reason}
    end
  end

  defp process_new_head(state, payload) do
    now = System.system_time(:millisecond)

    # Parse block data from payload
    {height, metadata} = parse_block_payload(payload)

    # Report to parent
    send(state.parent, {:block_height, state.provider_id, height, metadata})

    # Update state
    new_state = %{
      state
      | status: :active,
        last_block_time: now,
        last_height: height
    }

    # If we were stale, notify that we're active again
    if state.status == :stale do
      send(state.parent, {:status, state.provider_id, :ws, :active})
    end

    new_state
  end

  defp parse_block_payload(payload) when is_map(payload) do
    height =
      case Map.get(payload, "number") do
        "0x" <> hex -> String.to_integer(hex, 16)
        nil -> nil
      end

    metadata = %{
      hash: Map.get(payload, "hash"),
      parent_hash: Map.get(payload, "parentHash"),
      timestamp:
        case Map.get(payload, "timestamp") do
          "0x" <> hex -> String.to_integer(hex, 16)
          nil -> nil
        end
    }

    {height, metadata}
  end

  defp check_staleness(state) do
    case state.last_block_time do
      nil ->
        # Never received a block, might still be connecting
        if state.status == :active do
          mark_stale(state)
        else
          state
        end

      last_time ->
        age = System.system_time(:millisecond) - last_time

        if age > state.staleness_threshold_ms and state.status == :active do
          mark_stale(state)
        else
          state
        end
    end
  end

  defp mark_stale(state) do
    Logger.warning("WS subscription stale (no events)",
      chain: state.chain,
      provider_id: state.provider_id,
      threshold_ms: state.staleness_threshold_ms
    )

    send(state.parent, {:status, state.provider_id, :ws, :stale})

    %{state | status: :stale}
  end

  defp schedule_staleness_check(state) do
    if state.staleness_timer_ref do
      Process.cancel_timer(state.staleness_timer_ref)
    end

    # Check staleness at half the threshold interval
    check_interval = div(state.staleness_threshold_ms, 2)

    ref =
      Process.send_after(
        state.parent,
        {:ws_strategy, :check_staleness, state.provider_id},
        check_interval
      )

    %{state | staleness_timer_ref: ref}
  end
end
