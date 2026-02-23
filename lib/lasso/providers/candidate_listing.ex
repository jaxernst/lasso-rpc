defmodule Lasso.Providers.CandidateListing do
  @moduledoc """
  Pure ETS reads for provider candidate selection.

  Implements a 7-stage filter pipeline using shared ETS state:
  1. Transport availability (provider config has url/ws_url)
  2. WS liveness (channel cache for WS presence)
  3. Circuit breaker state
  4. Rate limit state
  5. Lag filtering (BlockSync.Registry + ChainState)
  6. Archival filtering
  7. Exclude list

  Return shape: `%{id, config, availability, circuit_state, rate_limited}`.
  """

  require Logger

  alias Lasso.Providers.{Catalog, InstanceState, LagCalculation}
  alias Lasso.RPC.SelectionFilters

  @doc """
  Lists provider candidates for a (profile, chain) pair, filtered by selection criteria.
  """
  @spec list_candidates(String.t(), String.t(), SelectionFilters.t() | map()) :: [map()]
  def list_candidates(profile, chain, %SelectionFilters{} = filters) do
    list_candidates(profile, chain, SelectionFilters.to_map(filters))
  end

  def list_candidates(profile, chain, filters) when is_map(filters) do
    protocol = Map.get(filters, :protocol)
    include_half_open = Map.get(filters, :include_half_open, false)

    profile_providers = Catalog.get_profile_providers(profile, chain)

    profile_providers
    |> Enum.map(&build_candidate/1)
    |> Enum.filter(fn c ->
      transport_available?(c, protocol, profile, chain) and
        circuit_breaker_ready?(c, protocol, include_half_open) and
        rate_limit_ok?(c, protocol, filters)
    end)
    |> filter_by_lag(profile, chain, Map.get(filters, :max_lag_blocks))
    |> filter_by_archival(Map.get(filters, :requires_archival))
    |> filter_excluded(filters)
  end

  @doc """
  Returns the minimum recovery time across all open circuits for a (profile, chain) pair.
  """
  @spec get_min_recovery_time(String.t(), String.t(), keyword()) ::
          {:ok, non_neg_integer() | nil} | {:error, term()}
  def get_min_recovery_time(profile, chain, opts \\ []) do
    transport_filter = Keyword.get(opts, :transport, :both)
    profile_providers = Catalog.get_profile_providers(profile, chain)
    now_ms = System.monotonic_time(:millisecond)

    times =
      Enum.flat_map(profile_providers, fn pp ->
        transports =
          case transport_filter do
            :http -> [:http]
            :ws -> [:ws]
            _ -> [:http, :ws]
          end

        Enum.flat_map(transports, fn t ->
          cb = InstanceState.read_circuit(pp.instance_id, t)

          if cb.state == :open and is_integer(cb.recovery_deadline_ms) do
            remaining = max(0, cb.recovery_deadline_ms - now_ms)
            if remaining > 0, do: [remaining], else: []
          else
            []
          end
        end)
      end)

    case times do
      [] -> {:ok, nil}
      ts -> {:ok, Enum.min(ts)}
    end
  end

  defp build_candidate(profile_provider) do
    instance_id = profile_provider.instance_id

    instance_config =
      case Catalog.get_instance(instance_id) do
        {:ok, config} -> config
        _ -> %{}
      end

    health = InstanceState.read_health(instance_id)

    config = %{
      id: profile_provider.provider_id,
      url: Map.get(instance_config, :url),
      ws_url: Map.get(instance_config, :ws_url),
      priority: profile_provider.priority,
      capabilities: profile_provider.capabilities,
      archival: profile_provider.archival,
      name: profile_provider[:name] || profile_provider.provider_id
    }

    http_cb = InstanceState.read_circuit(instance_id, :http)
    ws_cb = InstanceState.read_circuit(instance_id, :ws)
    http_rl = InstanceState.read_rate_limit(instance_id, :http)
    ws_rl = InstanceState.read_rate_limit(instance_id, :ws)

    %{
      id: profile_provider.provider_id,
      instance_id: instance_id,
      config: config,
      availability: InstanceState.status_to_availability(health.status),
      circuit_state: %{http: http_cb.state, ws: ws_cb.state},
      rate_limited: %{http: http_rl.rate_limited, ws: ws_rl.rate_limited}
    }
  end

  defp transport_available?(candidate, protocol, profile, chain) do
    config = candidate.config

    case protocol do
      :http ->
        is_binary(config.url)

      :ws ->
        is_binary(config.ws_url) and ws_channel_live?(profile, chain, candidate.id)

      :both ->
        is_binary(config.url) or
          (is_binary(config.ws_url) and ws_channel_live?(profile, chain, candidate.id))

      nil ->
        is_binary(config.url) or is_binary(config.ws_url)
    end
  end

  defp ws_channel_live?(profile, chain, provider_id) do
    case :ets.lookup(:transport_channel_cache, {profile, chain, provider_id, :ws}) do
      [{_, _channel}] -> true
      [] -> false
    end
  end

  defp circuit_breaker_ready?(candidate, protocol, include_half_open) do
    cs = candidate.circuit_state

    case protocol do
      :http ->
        cb_ready?(cs.http, include_half_open)

      :ws ->
        cb_ready?(cs.ws, include_half_open)

      p when p in [:both, nil] ->
        has_http = is_binary(candidate.config.url)
        has_ws = is_binary(candidate.config.ws_url)

        if include_half_open do
          (has_http and cs.http != :open) or (has_ws and cs.ws != :open)
        else
          (has_http and cs.http == :closed) or (has_ws and cs.ws == :closed)
        end
    end
  end

  defp cb_ready?(cb_state, include_half_open) do
    if include_half_open, do: cb_state != :open, else: cb_state == :closed
  end

  defp rate_limit_ok?(candidate, protocol, filters) do
    if Map.get(filters, :exclude_rate_limited, false) do
      rl = candidate.rate_limited

      case protocol do
        :http -> not rl.http
        :ws -> not rl.ws
        :both -> not rl.http and not rl.ws
        nil -> not rl.http or not rl.ws
      end
    else
      true
    end
  end

  defp filter_by_lag(candidates, _profile, _chain, nil), do: candidates

  defp filter_by_lag(candidates, profile, chain, max_lag_blocks)
       when is_integer(max_lag_blocks) do
    block_time_ms = LagCalculation.get_block_time_ms(chain, profile)

    filtered =
      Enum.filter(candidates, fn candidate ->
        case LagCalculation.calculate_optimistic_lag(chain, candidate.instance_id, block_time_ms) do
          {:ok, optimistic_lag, _raw_lag} -> optimistic_lag >= -max_lag_blocks
          {:error, _} -> true
        end
      end)

    if candidates != [] and filtered == [] do
      Logger.warning(
        "All providers for #{chain} excluded due to lag (threshold: -#{max_lag_blocks} blocks)"
      )
    end

    filtered
  end

  defp filter_by_archival(candidates, true) do
    Enum.filter(candidates, fn c -> c.config.archival != false end)
  end

  defp filter_by_archival(candidates, _), do: candidates

  defp filter_excluded(candidates, filters) do
    case Map.get(filters, :exclude) do
      exclude_list when is_list(exclude_list) ->
        Enum.filter(candidates, &(&1.id not in exclude_list))

      _ ->
        candidates
    end
  end
end
