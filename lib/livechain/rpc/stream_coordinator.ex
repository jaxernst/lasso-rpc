defmodule Livechain.RPC.StreamCoordinator do
  @moduledoc """
  Per-key coordinator that owns continuity (markers, dedupe) and orchestrates backfill.

  Receives upstream events from UpstreamSubscriptionPool and provider health signals.
  Delegates HTTP to GapFiller. Emits to ClientSubscriptionRegistry after dedupe/ordering.
  """

  use GenServer
  require Logger

  alias Livechain.RPC.{StreamState, GapFiller, ContinuityPolicy, ClientSubscriptionRegistry}

  @type key :: {:newHeads} | {:logs, map()}

  def start_link({chain, key, opts}) do
    GenServer.start_link(__MODULE__, {chain, key, opts}, name: via(chain, key))
  end

  def via(chain, key),
    do: {:via, Registry, {Livechain.Registry, {:stream_coordinator, chain, key}}}

  # API called by UpstreamSubscriptionPool

  def upstream_event(chain, key, provider_id, upstream_id, payload, received_at) do
    GenServer.cast(
      via(chain, key),
      {:upstream_event, provider_id, upstream_id, payload, received_at}
    )
  end

  def provider_unhealthy(chain, key, failed_id, proposed_new_id) do
    GenServer.cast(via(chain, key), {:provider_unhealthy, failed_id, proposed_new_id})
  end

  def upstream_confirmed(chain, key, provider_id, upstream_id) do
    GenServer.cast(via(chain, key), {:upstream_confirmed, provider_id, upstream_id})
  end

  # GenServer

  @impl true
  def init({chain, key, opts}) do
    state = %{
      chain: chain,
      key: key,
      primary_provider_id: Keyword.get(opts, :primary_provider_id),
      state:
        StreamState.new(
          dedupe_max_items: Keyword.get(opts, :dedupe_max_items, 256),
          dedupe_max_age_ms: Keyword.get(opts, :dedupe_max_age_ms, 30_000)
        ),
      # backfill config
      max_backfill_blocks: Keyword.get(opts, :max_backfill_blocks, 32),
      backfill_timeout: Keyword.get(opts, :backfill_timeout, 30_000),
      continuity_policy: Keyword.get(opts, :continuity_policy, :best_effort),
      # track pending subscribe
      awaiting_confirm: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:upstream_event, _provider_id, _upstream_id, payload, _received_at}, state) do
    case state.key do
      {:newHeads} ->
        case StreamState.ingest_new_head(state.state, payload) do
          {stream_state, :emit} ->
            ClientSubscriptionRegistry.dispatch(state.chain, state.key, payload)
            {:noreply, %{state | state: stream_state}}

          {stream_state, :skip} ->
            {:noreply, %{state | state: stream_state}}
        end

      {:logs, _filter} ->
        case StreamState.ingest_log(state.state, payload) do
          {stream_state, :emit} ->
            ClientSubscriptionRegistry.dispatch(state.chain, state.key, payload)
            {:noreply, %{state | state: stream_state}}

          {stream_state, :skip} ->
            {:noreply, %{state | state: stream_state}}
        end
    end
  end

  @impl true
  def handle_cast({:provider_unhealthy, failed_id, proposed_new_id}, state) do
    # Compute head and ranges using continuity policy, then backfill via Task
    Task.start(fn -> do_backfill_and_switch(state, failed_id, proposed_new_id) end)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:upstream_confirmed, provider_id, upstream_id}, state) do
    _ = {provider_id, upstream_id}
    {:noreply, %{state | awaiting_confirm: nil, primary_provider_id: provider_id}}
  end

  # Internal

  defp do_backfill_and_switch(state, _failed_id, new_provider) do
    try do
      case state.key do
        {:newHeads} ->
          last = StreamState.last_block_num(state.state)

          with {:range, from_n, to_n} <-
                 ContinuityPolicy.needed_block_range(
                   last,
                   fetch_head(state.chain, new_provider),
                   state.max_backfill_blocks,
                   state.continuity_policy
                 ),
               {:ok, blocks} <-
                 GapFiller.ensure_blocks(state.chain, new_provider, from_n, to_n,
                   timeout_ms: state.backfill_timeout
                 ) do
            Enum.each(blocks, fn b ->
              GenServer.cast(
                self(),
                {:upstream_event, new_provider, nil, b, System.monotonic_time(:millisecond)}
              )
            end)
          else
            {:exceeded, from_n, to_n} ->
              {:ok, blocks} =
                GapFiller.ensure_blocks(state.chain, new_provider, from_n, to_n,
                  timeout_ms: state.backfill_timeout
                )

              Enum.each(blocks, fn b ->
                GenServer.cast(
                  self(),
                  {:upstream_event, new_provider, nil, b, System.monotonic_time(:millisecond)}
                )
              end)

            _ ->
              :ok
          end

        {:logs, filter} ->
          last =
            StreamState.last_log_block(state.state) || StreamState.last_block_num(state.state)

          with {:range, from_n, to_n} <-
                 ContinuityPolicy.needed_block_range(
                   last,
                   fetch_head(state.chain, new_provider),
                   state.max_backfill_blocks,
                   state.continuity_policy
                 ),
               {:ok, logs} <-
                 GapFiller.ensure_logs(state.chain, new_provider, filter, from_n, to_n,
                   timeout_ms: state.backfill_timeout
                 ) do
            Enum.each(logs, fn l ->
              GenServer.cast(
                self(),
                {:upstream_event, new_provider, nil, l, System.monotonic_time(:millisecond)}
              )
            end)
          else
            {:exceeded, from_n, to_n} ->
              {:ok, logs} =
                GapFiller.ensure_logs(state.chain, new_provider, filter, from_n, to_n,
                  timeout_ms: state.backfill_timeout
                )

              Enum.each(logs, fn l ->
                GenServer.cast(
                  self(),
                  {:upstream_event, new_provider, nil, l, System.monotonic_time(:millisecond)}
                )
              end)

            _ ->
              :ok
          end
      end
    rescue
      e -> Logger.error("StreamCoordinator backfill error: #{inspect(e)}", chain: state.chain)
    after
      # Ask pool to subscribe on the new provider
      send(self(), {:subscribe_on, new_provider})
    end
  end

  @impl true
  def handle_info({:subscribe_on, provider_id}, state) do
    # delegate to pool via message; pool owns WS interaction
    send_to_pool(state.chain, {:subscribe_on, provider_id, state.key, self()})
    {:noreply, %{state | awaiting_confirm: provider_id}}
  end

  defp fetch_head(chain, provider_id) do
    case Livechain.RPC.ChainSupervisor.forward_rpc_request(
           chain,
           provider_id,
           "eth_blockNumber",
           []
         ) do
      {:ok, "0x" <> _ = hex} -> String.to_integer(String.trim_leading(hex, "0x"), 16)
      _ -> 0
    end
  end

  defp send_to_pool(chain, msg) do
    pid = GenServer.whereis({:via, Registry, {Livechain.Registry, {:pool, chain}}})
    if is_pid(pid), do: send(pid, msg), else: :ok
  end
end
