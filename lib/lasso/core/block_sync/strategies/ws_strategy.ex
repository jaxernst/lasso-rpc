defmodule Lasso.BlockSync.Strategies.WsStrategy do
  @moduledoc """
  WebSocket subscription strategy for block sync.

  Subscribes to `newHeads` via InstanceSubscriptionManager and reports:
  - Block heights with rich metadata (hash, timestamp)
  - Status changes (active, stale, failed)

  ## Staleness Detection

  If no newHeads events are received within `staleness_threshold_ms`, the
  strategy reports itself as stale. The Worker can then continue HTTP fallback.

  ## Events received

  Events come via InstanceSubscriptionRegistry dispatch:
  - `{:instance_subscription_event, instance_id, {:newHeads}, payload, received_at}`
  - `{:instance_subscription_invalidated, instance_id, {:newHeads}, reason}`
  """

  @behaviour Lasso.BlockSync.Strategy

  require Logger

  alias Lasso.Core.Streaming.{InstanceSubscriptionManager, InstanceSubscriptionRegistry}

  @default_staleness_threshold_ms 35_000

  defstruct [
    :instance_id,
    :chain,
    :parent,
    :staleness_threshold_ms,
    :staleness_timer_ref,
    :status,
    :last_block_time,
    :last_height,
    :subscription_status
  ]

  @type t :: %__MODULE__{
          instance_id: String.t(),
          chain: String.t(),
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
  def start(chain, instance_id, opts) do
    parent = Keyword.get(opts, :parent, self())

    staleness_threshold =
      Keyword.get(opts, :staleness_threshold_ms, @default_staleness_threshold_ms)

    state = %__MODULE__{
      instance_id: instance_id,
      chain: chain,
      parent: parent,
      staleness_threshold_ms: staleness_threshold,
      staleness_timer_ref: nil,
      status: :connecting,
      last_block_time: nil,
      last_height: nil,
      subscription_status: :pending
    }

    case do_subscribe(state) do
      {:ok, new_state} ->
        new_state = schedule_staleness_check(new_state)
        {:ok, new_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def stop(%__MODULE__{
        staleness_timer_ref: ref,
        instance_id: instance_id
      }) do
    if ref, do: Process.cancel_timer(ref)

    InstanceSubscriptionManager.release_subscription(instance_id, {:newHeads})
    InstanceSubscriptionRegistry.unregister_consumer(instance_id, {:newHeads})

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
  def handle_message(:check_staleness, state) do
    new_state = check_staleness(state)
    new_state = schedule_staleness_check(new_state)
    {:ok, new_state}
  end

  def handle_message(_other, state) do
    {:ok, state}
  end

  ## Public API (for Worker)

  @spec handle_new_head(t(), map()) :: t()
  def handle_new_head(%__MODULE__{} = state, payload) do
    process_new_head(state, payload)
  end

  @spec handle_invalidation(t(), term()) :: t()
  def handle_invalidation(%__MODULE__{} = state, reason) do
    Logger.debug("WS subscription invalidated",
      chain: state.chain,
      instance_id: state.instance_id,
      reason: inspect(reason)
    )

    new_state = %{state | status: :failed, subscription_status: :invalidated}
    send(state.parent, {:status, state.instance_id, :ws, :failed})

    new_state
  end

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
    # Register in InstanceSubscriptionRegistry so Worker receives events
    InstanceSubscriptionRegistry.register_consumer(state.instance_id, {:newHeads})

    case InstanceSubscriptionManager.ensure_subscription(state.instance_id, {:newHeads}) do
      {:ok, status} ->
        Logger.debug("WS newHeads subscription registered",
          chain: state.chain,
          instance_id: state.instance_id,
          status: status
        )

        new_state = %{state | status: :connecting, subscription_status: status}
        {:ok, new_state}

      {:error, reason} ->
        Logger.debug("WS subscription failed",
          chain: state.chain,
          instance_id: state.instance_id,
          reason: inspect(reason)
        )

        InstanceSubscriptionRegistry.unregister_consumer(state.instance_id, {:newHeads})
        send(state.parent, {:status, state.instance_id, :ws, :failed})
        {:error, reason}
    end
  end

  defp process_new_head(state, payload) do
    now = System.system_time(:millisecond)
    {height, metadata} = parse_block_payload(payload)

    send(state.parent, {:block_height, state.instance_id, height, metadata})

    first_block = state.last_block_time == nil

    new_state = %{
      state
      | status: :active,
        last_block_time: now,
        last_height: height
    }

    cond do
      first_block ->
        Logger.debug("WS subscription active (first block received)",
          chain: state.chain,
          instance_id: state.instance_id,
          height: height
        )

        send(state.parent, {:status, state.instance_id, :ws, :active})

      state.status == :stale ->
        Logger.debug("WS subscription recovered from stale",
          chain: state.chain,
          instance_id: state.instance_id,
          height: height
        )

        send(state.parent, {:status, state.instance_id, :ws, :active})

      true ->
        :ok
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
      instance_id: state.instance_id,
      threshold_ms: state.staleness_threshold_ms
    )

    send(state.parent, {:status, state.instance_id, :ws, :stale})

    %{state | status: :stale}
  end

  defp schedule_staleness_check(state) do
    if state.staleness_timer_ref do
      Process.cancel_timer(state.staleness_timer_ref)
    end

    check_interval = div(state.staleness_threshold_ms, 2)

    ref =
      Process.send_after(
        state.parent,
        {:ws_strategy, :check_staleness, state.instance_id},
        check_interval
      )

    %{state | staleness_timer_ref: ref}
  end
end
