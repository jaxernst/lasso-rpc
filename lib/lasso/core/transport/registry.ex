defmodule Lasso.RPC.TransportRegistry do
  @moduledoc """
  Registry for managing transport channels across different providers and protocols.

  This module provides a unified interface for opening, managing, and selecting
  channels (HTTP pools, WebSocket connections) for different providers and transports.
  It acts as the bridge between the transport-agnostic RequestPipeline and the
  concrete transport implementations.

  Each provider can have multiple transport channels:
  - HTTP channel (connection pool)
  - WebSocket channel (persistent connection)

  The registry maintains channel lifecycle, health status, and provides
  channel selection capabilities for the routing logic.

  ## Architecture

  TransportRegistry uses a two-tier storage model for optimal performance:

  1. **GenServer state** (authoritative): Stores channels map and capabilities.
     All writes go through GenServer to ensure serialization.

  2. **ETS cache** (read-optimized): Provides lockless reads for hot-path lookups.
     The cache is kept in sync via `cache_channel/4` and `uncache_channel/3`.

  The ETS table (`:transport_channel_cache`) is created by `Lasso.Application`
  at startup and owned by the Application process (which never dies). This keeps
  the table alive for the lifetime of the application while TransportRegistry
  manages its contents.

  ## WebSocket Lifecycle Invariant

  For WebSocket channels, **cache presence implies the WebSocket is connected**.
  This is enforced by PubSub event handling:

  - On `:ws_connected` → channel is created and cached
  - On `:ws_disconnected` or `:ws_closed` → channel is removed and uncached

  This allows Selection to efficiently check WS availability via ETS lookup
  rather than calling each WSConnection process. If a stale channel reference
  is returned (race condition), the circuit breaker handles the failure gracefully
  on first request attempt.

  ## Responsibilities

  - Lazy channel opening (on-demand)
  - Channel health monitoring
  - Capability caching (supported methods, subscription support)
  - Channel lifecycle management
  - ETS cache coherence

  ## Not Responsible For

  - Provider health/availability (see ProviderPool)
  - Provider selection strategy (see Selection)
  """

  use GenServer
  require Logger

  alias Lasso.Config.ConfigStore
  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.RPC.Channel
  alias Lasso.RPC.ProviderPool

  # ETS table for lockless channel lookups in hot path
  @channel_cache_table :transport_channel_cache

  defstruct [
    :profile,
    :chain_name,
    # Map of provider_id => %{http: channel, ws: channel}
    :channels,
    # Map of {provider_id, transport} => capabilities
    :capabilities
  ]

  @type profile :: String.t()
  @type chain_name :: String.t()
  @type provider_id :: String.t()
  @type transport :: :http | :ws
  @type channel_map :: %{transport => Channel.t()}

  @doc """
  Starts the TransportRegistry for a profile/chain pair.

  Accepts either `{profile, chain_name, chain_config}` (profile-aware) or
  `{chain_name, chain_config}` (backward compatible, uses "default" profile).
  """
  @spec start_link({profile, chain_name, map()} | {chain_name, map()}) :: GenServer.on_start()
  def start_link({profile, chain_name, chain_config}) when is_binary(profile) do
    GenServer.start_link(__MODULE__, {profile, chain_name, chain_config},
      name: via_name(profile, chain_name)
    )
  end

  def start_link({chain_name, chain_config}) do
    start_link({"default", chain_name, chain_config})
  end

  @doc """
  Gets or opens a channel for a provider and transport.

  This function uses a two-tier lookup strategy for optimal performance:

  1. **Fast path (ETS)**: First checks the ETS cache for lockless reads (~100ns)
  2. **Slow path (GenServer)**: On cache miss, falls back to GenServer.call to
     create the channel and populate the cache

  Once a channel is cached, subsequent lookups are instant ETS reads.

  ## Cache Coherence

  The ETS cache is kept in sync with the GenServer state:
  - Channels are cached when created via `create_channel/4`
  - Channels are uncached when removed via `remove_channel/3`
  - WebSocket channels are automatically uncached on disconnect
    (via PubSub events: `:ws_disconnected`, `:ws_closed`)

  **Important**: For WS channels, cache presence implies the WebSocket is connected.
  Stale channel references are handled gracefully by the circuit breaker on
  first failed request.

  Returns {:ok, channel} or {:error, reason}.
  """
  @spec get_channel(profile, chain_name, provider_id, transport, keyword()) ::
          {:ok, Channel.t()} | {:error, term()}
  def get_channel(profile, chain_name, provider_id, transport, opts \\ [])
      when is_binary(profile) and is_binary(chain_name) and is_binary(provider_id) and
             is_atom(transport) do
    cache_key = {profile, chain_name, provider_id, transport}

    case :ets.lookup(@channel_cache_table, cache_key) do
      [{^cache_key, channel}] ->
        # Fast path: channel exists in ETS cache
        {:ok, channel}

      [] ->
        # Slow path: channel not cached, use GenServer to create/fetch
        # This will also populate the ETS cache for future lookups
        do_get_channel(profile, chain_name, provider_id, transport, opts)
    end
  end

  # GenServer call for channel creation/retrieval. Called on cache miss.
  defp do_get_channel(profile, chain_name, provider_id, transport, opts) do
    GenServer.call(via_name(profile, chain_name), {:get_channel, provider_id, transport, opts})
  end

  @doc """
  Pre-warms channels for a provider by creating configured transports that are viable.

  HTTP is created if url/http_url is configured. WS is created only if ws_url is
  configured and the WS connection is currently established.

  Accepts optional profile as first argument (defaults to "default").
  """
  @spec initialize_provider_channels(chain_name, provider_id, map()) :: :ok | {:error, term()}
  def initialize_provider_channels(chain_name, provider_id, provider_config) do
    initialize_provider_channels("default", chain_name, provider_id, provider_config)
  end

  @spec initialize_provider_channels(profile, chain_name, provider_id, map()) ::
          :ok | {:error, term()}
  def initialize_provider_channels(profile, chain_name, provider_id, provider_config)
      when is_binary(profile) do
    GenServer.call(
      via_name(profile, chain_name),
      {:initialize_provider_channels, provider_id, provider_config}
    )
  end

  @doc """
  Lists all available channels for a provider.

  Accepts optional profile as first argument (defaults to "default").

  Returns a list of {transport, channel} tuples.
  """
  @spec list_provider_channels(chain_name, provider_id) :: [{transport, Channel.t()}]
  def list_provider_channels(chain_name, provider_id) do
    list_provider_channels("default", chain_name, provider_id)
  end

  @spec list_provider_channels(profile, chain_name, provider_id) :: [{transport, Channel.t()}]
  def list_provider_channels(profile, chain_name, provider_id) when is_binary(profile) do
    GenServer.call(via_name(profile, chain_name), {:list_provider_channels, provider_id})
  end

  @doc """
  Gets all candidate channels that match the given filters.

  Filters can include:
  - protocol: :http | :ws | :both
  - exclude: [provider_id]
  - method: String.t() (for capability filtering)

  Accepts optional profile as first argument (defaults to "default").

  Returns a list of Channel structs with transport and capability information.
  """
  @spec get_candidate_channels(chain_name, map()) :: [Channel.t()]
  def get_candidate_channels(chain_name, filters \\ %{}) do
    get_candidate_channels("default", chain_name, filters)
  end

  @spec get_candidate_channels(profile, chain_name, map()) :: [Channel.t()]
  def get_candidate_channels(profile, chain_name, filters)
      when is_binary(profile) and is_map(filters) do
    GenServer.call(via_name(profile, chain_name), {:get_candidate_channels, filters})
  end

  @doc """
  Forces refresh of capabilities for a provider/transport combination.

  Accepts optional profile as first argument (defaults to "default").
  """
  @spec refresh_capabilities(chain_name, provider_id, transport) :: :ok
  def refresh_capabilities(chain_name, provider_id, transport) do
    refresh_capabilities("default", chain_name, provider_id, transport)
  end

  @spec refresh_capabilities(profile, chain_name, provider_id, transport) :: :ok
  def refresh_capabilities(profile, chain_name, provider_id, transport) when is_binary(profile) do
    GenServer.cast(via_name(profile, chain_name), {:refresh_capabilities, provider_id, transport})
  end

  @doc """
  Closes and removes a channel from the registry.

  Accepts optional profile as first argument (defaults to "default").
  """
  @spec close_channel(chain_name, provider_id, transport) :: :ok
  def close_channel(chain_name, provider_id, transport) do
    close_channel("default", chain_name, provider_id, transport)
  end

  @spec close_channel(profile, chain_name, provider_id, transport) :: :ok
  def close_channel(profile, chain_name, provider_id, transport) when is_binary(profile) do
    GenServer.cast(via_name(profile, chain_name), {:close_channel, provider_id, transport})
  end

  # GenServer implementation

  @impl true
  def init({profile, chain_name, _chain_config})
      when is_binary(profile) and is_binary(chain_name) do
    state = %__MODULE__{
      profile: profile,
      chain_name: chain_name,
      channels: %{},
      capabilities: %{}
    }

    # Subscribe to profile-scoped WS connection events
    Phoenix.PubSub.subscribe(Lasso.PubSub, "ws:conn:#{profile}:#{chain_name}")

    {:ok, state}
  end

  @impl true
  def handle_call({:get_channel, provider_id, transport, opts}, _from, state) do
    case get_existing_channel(state, provider_id, transport) do
      {:ok, channel} ->
        # Verify channel is still healthy
        if Channel.healthy?(channel) do
          {:reply, {:ok, channel}, state}
        else
          # Channel is unhealthy, remove and create new one
          new_state = remove_channel(state, provider_id, transport)

          case create_channel(new_state, provider_id, transport, opts) do
            {:ok, channel, updated_state} ->
              {:reply, {:ok, channel}, updated_state}

            {:error, reason} ->
              {:reply, {:error, reason}, new_state}
          end
        end

      {:error, :not_found} ->
        case create_channel(state, provider_id, transport, opts) do
          {:ok, channel, updated_state} ->
            {:reply, {:ok, channel}, updated_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:initialize_provider_channels, provider_id, provider_config}, _from, state) do
    # HTTP pre-warm if configured
    state =
      if is_binary(Map.get(provider_config, :url)) or
           is_binary(Map.get(provider_config, :http_url)) do
        case create_channel(state, provider_id, :http, provider_config: provider_config) do
          {:ok, _chan, s} ->
            Logger.info("TransportRegistry: HTTP channel created for #{provider_id}")
            s

          {:error, reason} ->
            # Log actual failures as warnings, missing configs as debug
            case reason do
              :no_http_config ->
                Logger.debug("TransportRegistry: No HTTP URL configured for #{provider_id}")

              _ ->
                Logger.warning(
                  "TransportRegistry: Failed to create HTTP channel for #{provider_id}: #{inspect(reason)}"
                )
            end

            state
        end
      else
        Logger.debug("TransportRegistry: No HTTP URL configured for #{provider_id}")
        state
      end

    # WS channels are created on ws_connected events to avoid races
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:list_provider_channels, provider_id}, _from, state) do
    channels = Map.get(state.channels, provider_id, %{})
    channel_list = Enum.to_list(channels)
    {:reply, channel_list, state}
  end

  @impl true
  def handle_call({:get_candidate_channels, filters}, _from, state) do
    candidates = build_candidate_list(state, filters)
    {:reply, candidates, state}
  end

  @impl true
  def handle_cast({:refresh_capabilities, provider_id, transport}, state) do
    case get_existing_channel(state, provider_id, transport) do
      {:ok, channel} ->
        capabilities = Channel.get_capabilities(channel)
        key = {provider_id, transport}
        new_capabilities = Map.put(state.capabilities, key, capabilities)
        new_state = %{state | capabilities: new_capabilities}
        {:noreply, new_state}

      {:error, :not_found} ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:close_channel, provider_id, transport}, state) do
    new_state = remove_channel(state, provider_id, transport)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:ws_connected, provider_id, _connection_id}, state) do
    handle_ws_connected(provider_id, state)
  end

  @impl true
  def handle_info({:ws_closed, provider_id, _code, _jerr}, state) do
    new_state = remove_channel(state, provider_id, :ws)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:ws_disconnected, provider_id, _jerr}, state) do
    new_state = remove_channel(state, provider_id, :ws)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({_event, _provider_id, _jerr}, state), do: {:noreply, state}

  # Private helper for ws_connected handling
  defp handle_ws_connected(provider_id, state) do
    # Create WS channel on connect (idempotent)
    new_state =
      case create_channel(state, provider_id, :ws, []) do
        {:ok, _ch, s} -> s
        {:error, _} -> state
      end

    {:noreply, new_state}
  end

  # Private functions

  defp get_existing_channel(state, provider_id, transport) do
    case get_in(state.channels, [provider_id, transport]) do
      nil -> {:error, :not_found}
      channel -> {:ok, channel}
    end
  end

  defp create_channel(state, provider_id, transport, opts) do
    # Try to get provider config from opts first (for dynamic providers),
    # fallback to ConfigStore for config-file providers
    provider_config_result =
      case Keyword.get(opts, :provider_config) do
        config when is_map(config) ->
          {:ok, config}

        _ ->
          case ConfigStore.get_provider(state.profile, state.chain_name, provider_id) do
            {:ok, _} = ok -> ok
            _ -> get_provider_config_from_pool(state.profile, state.chain_name, provider_id)
          end
      end

    case provider_config_result do
      {:ok, provider_config} ->
        transport_module = get_transport_module(transport)
        channel_opts = Keyword.put(opts, :provider_id, provider_id)
        # Only attempt to open channels that are actually configured
        case transport do
          :http ->
            if is_binary(Map.get(provider_config, :url)) or
                 is_binary(Map.get(provider_config, :http_url)) do
              transport_module.open(provider_config, channel_opts)
            else
              {:error, :no_http_config}
            end

          :ws ->
            if is_binary(Map.get(provider_config, :ws_url)) do
              transport_module.open(provider_config, channel_opts)
            else
              {:error, :no_ws_config}
            end
        end
        |> case do
          {:ok, raw_channel} ->
            # Wrap in Channel struct
            channel =
              Channel.new(
                state.profile,
                state.chain_name,
                provider_id,
                transport,
                raw_channel,
                transport_module
              )

            # Store channel in GenServer state
            updated_channels =
              Map.update(state.channels, provider_id, %{}, fn provider_channels ->
                Map.put(provider_channels, transport, channel)
              end)

            new_state = %{state | channels: updated_channels}

            # Cache capabilities
            capabilities = Channel.get_capabilities(channel)
            cap_key = {provider_id, transport}
            new_capabilities = Map.put(state.capabilities, cap_key, capabilities)
            final_state = %{new_state | capabilities: new_capabilities}

            # Update ETS cache for lockless hot-path reads
            cache_channel(state, provider_id, transport, channel)

            {:ok, channel, final_state}

          {:error, reason} ->
            # Don't spam logs for missing transport configs (expected for HTTP-only/WS-only providers)
            unless reason in [:no_ws_config, :no_http_config] do
              Logger.warning(
                "Failed to create #{transport} channel for provider #{provider_id}: #{inspect(reason)}"
              )
            end

            {:error, reason}
        end

      {:error, reason} ->
        {:error,
         JError.new(-32_000, "Provider not found: #{inspect(reason)}", provider_id: provider_id)}
    end
  end

  defp get_provider_config_from_pool(profile, chain_name, provider_id) do
    case ProviderPool.get_status(profile, chain_name) do
      {:ok, status} ->
        case Enum.find(status.providers, fn p -> p.id == provider_id end) do
          nil -> {:error, :provider_not_found}
          provider -> {:ok, Map.get(provider, :config, %{})}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remove_channel(state, provider_id, transport) do
    case get_existing_channel(state, provider_id, transport) do
      {:ok, channel} ->
        Channel.close(channel)
        Logger.debug("Closed #{transport} channel for provider #{provider_id}")

      {:error, :not_found} ->
        :ok
    end

    # Remove from ETS cache (lockless reads will now miss)
    uncache_channel(state, provider_id, transport)

    # Remove from GenServer state
    updated_channels =
      case Map.get(state.channels, provider_id) do
        nil ->
          state.channels

        provider_channels ->
          new_provider_channels = Map.delete(provider_channels, transport)

          if map_size(new_provider_channels) == 0 do
            Map.delete(state.channels, provider_id)
          else
            Map.put(state.channels, provider_id, new_provider_channels)
          end
      end

    # Remove capabilities
    cap_key = {provider_id, transport}
    updated_capabilities = Map.delete(state.capabilities, cap_key)

    %{state | channels: updated_channels, capabilities: updated_capabilities}
  end

  defp build_candidate_list(state, filters) do
    protocol_filter = Map.get(filters, :protocol, :both)
    exclude_list = Map.get(filters, :exclude, [])
    method_filter = Map.get(filters, :method)

    # Determine gating by method (Phase 1a)
    {require_unary, require_subscriptions} =
      case method_filter do
        "eth_subscribe" -> {false, true}
        "eth_unsubscribe" -> {false, true}
        _ -> {true, false}
      end

    state.channels
    |> Enum.flat_map(fn {provider_id, provider_channels} ->
      if provider_id in exclude_list do
        []
      else
        provider_channels
        |> Enum.filter(fn {transport, channel} ->
          transport_matches?(transport, protocol_filter) and
            Channel.healthy?(channel) and
            method_supported?(state, provider_id, transport, method_filter) and
            channel_capability_allows?(channel, require_unary, require_subscriptions)
        end)
        |> Enum.map(fn {_t, channel} -> channel end)
      end
    end)
  end

  defp channel_capability_allows?(channel, true, false), do: Channel.supports_unary?(channel)

  defp channel_capability_allows?(channel, false, true),
    do: Channel.supports_subscriptions?(channel)

  defp channel_capability_allows?(_channel, false, false), do: true

  defp transport_matches?(_transport, :both), do: true
  defp transport_matches?(transport, transport), do: true
  defp transport_matches?(_transport, _protocol), do: false

  defp method_supported?(_state, _provider_id, _transport, nil), do: true

  defp method_supported?(state, provider_id, transport, method) do
    key = {provider_id, transport}

    case Map.get(state.capabilities, key) do
      # Assume supported if capabilities unknown
      nil -> true
      %{methods: :all} -> true
      %{methods: method_set} -> MapSet.member?(method_set, method)
    end
  end

  defp get_transport_module(:http), do: Lasso.RPC.Transports.HTTP
  defp get_transport_module(:ws), do: Lasso.RPC.Transports.WebSocket

  @doc """
  Returns the via tuple for the TransportRegistry GenServer.

  Accepts optional profile as first argument (defaults to "default").
  """
  @spec via_name(String.t()) :: {:via, Registry, {atom(), tuple()}}
  def via_name(chain_name) when is_binary(chain_name) do
    via_name("default", chain_name)
  end

  @spec via_name(String.t(), String.t()) :: {:via, Registry, {atom(), tuple()}}
  def via_name(profile, chain_name) when is_binary(profile) and is_binary(chain_name) do
    {:via, Registry, {Lasso.Registry, {:transport_registry, profile, chain_name}}}
  end

  # ETS cache management for lockless hot-path reads

  # Updates the ETS channel cache. Called internally when channels are created.
  # Cache key includes profile for isolation.
  defp cache_channel(state, provider_id, transport, channel) do
    cache_key = {state.profile, state.chain_name, provider_id, transport}
    :ets.insert(@channel_cache_table, {cache_key, channel})
  end

  # Removes a channel from ETS cache. Called internally when channels are closed.
  defp uncache_channel(state, provider_id, transport) do
    cache_key = {state.profile, state.chain_name, provider_id, transport}
    :ets.delete(@channel_cache_table, cache_key)
  end
end
