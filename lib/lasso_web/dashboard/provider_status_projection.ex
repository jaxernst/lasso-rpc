defmodule LassoWeb.Dashboard.ProviderStatusProjection do
  @moduledoc """
  Projects one provider status from the cluster evidence shown by the dashboard.

  Aggregate status is evaluated across transport-region slots. A provider is
  unavailable only when every supported slot is unavailable; partial failures
  remain degraded. Circuit, rate-limit, and readiness evidence is regional.
  Head evidence is attached to the physical provider instance and retains its
  actual observation origin; cluster replication does not create a separate
  regional head observation.
  """

  alias Lasso.BlockSync.Observation
  alias LassoWeb.Dashboard.StatusHelpers

  @unhealthy_states [:unhealthy, :degraded, :misconfigured]

  @spec status(map(), keyword()) :: atom()
  def status(connection, opts \\ []) when is_map(connection) do
    connection
    |> explain(opts)
    |> Map.fetch!(:status)
  end

  @spec explain(map(), keyword()) :: %{
          status: atom(),
          reason: atom(),
          affected_regions: [String.t()],
          total_regions: non_neg_integer()
        }
  def explain(connection, opts \\ []) when is_map(connection) do
    node_ids = scoped_node_ids(opts)

    if node_ids == [] do
      local_status = StatusHelpers.determine_provider_status(connection)
      now_ms = Keyword.get_lazy(opts, :now_ms, fn -> System.system_time(:millisecond) end)

      observation = %{
        observed_at_ms: connection[:block_observed_at_ms],
        stale_after_ms: connection[:block_stale_after_ms] || 60_000
      }

      fresh? = Observation.fresh?(observation, now_ms)

      status =
        cond do
          local_status in [:healthy, :lagging] and not fresh? ->
            :unknown

          local_status == :unknown and fresh? and connection[:health_status] == :healthy ->
            :healthy

          true ->
            local_status
        end

      %{
        status: status,
        reason: local_reason(status),
        affected_regions: [],
        total_regions: 0
      }
    else
      project_cluster_status(connection, node_ids, opts)
    end
  end

  @doc "Counts availability separately from health, without claiming support for every method."
  def available?(connection, opts \\ []) do
    nodes = scoped_node_ids(opts)
    circuits = Keyword.get(opts, :cluster_circuits, %{})

    Enum.any?(supported_transports(connection), fn transport ->
      if nodes == [] do
        slot_available?(
          %{
            transport => Map.get(connection, circuit_key(transport), :unknown),
            rate_limit_key(transport) => Map.get(connection, rate_limit_key(transport), false),
            :ws_connected => Map.get(connection, :ws_connected, false)
          },
          transport
        )
      else
        Enum.any?(nodes, fn node ->
          slot_available?(Map.get(circuits, {connection.id, node}, %{}), transport)
        end)
      end
    end)
  end

  defp slot_available?(evidence, transport) do
    slot_state(evidence, transport) == :available
  end

  defp slot_state(evidence, transport) do
    cond do
      Map.get(evidence, transport) == :open -> :circuit_open
      Map.get(evidence, rate_limit_key(transport)) == true -> :rate_limited
      transport == :ws and Map.get(evidence, :ws_connected) == false -> :ws_disconnected
      Map.get(evidence, transport) not in [:closed, :half_open] -> :unknown
      transport == :ws and Map.get(evidence, :ws_connected) != true -> :unknown
      true -> :available
    end
  end

  defp circuit_key(:http), do: :http_circuit_state
  defp circuit_key(:ws), do: :ws_circuit_state

  def label(%{reason: :partial_rate_limit}), do: "Partially rate limited"
  def label(%{reason: :partial_circuit_open}), do: "Partial circuit outage"
  def label(%{reason: :mixed_route_failures}), do: "Unavailable"
  def label(%{status: status}), do: StatusHelpers.status_label(status)

  def description(%{reason: :partial_rate_limit} = projection),
    do:
      "Rate limited in #{length(projection.affected_regions)}/#{projection.total_regions} regions; other routes may remain available"

  def description(%{reason: :partial_circuit_open} = projection),
    do:
      "Circuit open in #{length(projection.affected_regions)}/#{projection.total_regions} regions; other routes may remain available"

  def description(%{reason: :mixed_route_failures}),
    do:
      "No available routes: circuits are open, rate limited, or WebSocket connections are disconnected across the selected scope"

  def description(_projection), do: nil

  defp scoped_node_ids(opts) do
    node_ids =
      case Keyword.get(opts, :scope, "aggregate") do
        "aggregate" -> Keyword.get(opts, :available_node_ids, [])
        node_id when is_binary(node_id) -> [node_id]
      end
      |> Enum.uniq()

    if node_ids == [Keyword.get(opts, :local_node_id)], do: [], else: node_ids
  end

  defp project_cluster_status(connection, node_ids, opts) do
    evidence = cluster_evidence(connection, node_ids, opts)

    project_evidence(evidence, node_ids)
  end

  defp cluster_evidence(connection, node_ids, opts) do
    provider_id = connection.id
    circuits = Keyword.get(opts, :cluster_circuits, %{})
    health = Keyword.get(opts, :cluster_health, %{})
    blocks = Keyword.get(opts, :cluster_blocks, %{})
    transports = supported_transports(connection)
    now_ms = Keyword.get_lazy(opts, :now_ms, fn -> System.system_time(:millisecond) end)

    slot_states =
      for node_id <- node_ids, transport <- transports do
        slot_state(Map.get(circuits, {provider_id, node_id}, %{}), transport)
      end

    circuit_slots =
      for node_id <- node_ids, transport <- transports do
        circuits
        |> Map.get({provider_id, node_id}, %{})
        |> Map.get(transport, :unknown)
      end

    rate_limit_slots =
      for node_id <- node_ids, transport <- transports do
        circuits
        |> Map.get({provider_id, node_id}, %{})
        |> Map.get(rate_limit_key(transport), false)
      end

    open_regions =
      affected_regions(node_ids, fn node_id ->
        Enum.any?(transports, fn transport ->
          get_in(circuits, [{provider_id, node_id}, transport]) == :open
        end)
      end)

    rate_limited_regions =
      affected_regions(node_ids, fn node_id ->
        Enum.any?(transports, fn transport ->
          get_in(circuits, [
            {provider_id, node_id},
            rate_limit_key(transport)
          ]) == true
        end)
      end)

    recovering_circuit_regions =
      affected_regions(node_ids, fn node_id ->
        Enum.any?(transports, fn transport ->
          get_in(circuits, [{provider_id, node_id}, transport]) == :half_open
        end)
      end)

    ws_disconnected_regions =
      if is_binary(Map.get(connection, :ws_url)) or
           Map.get(connection, :type) in [:websocket, :both] do
        affected_regions(node_ids, &websocket_disconnected_in_region?(provider_id, &1, circuits))
      else
        []
      end

    unhealthy_regions = unhealthy_regions(provider_id, node_ids, health)
    recovering_regions = recovering_regions(provider_id, node_ids, health)
    lagging_regions = lagging_regions(connection, provider_id, node_ids, blocks, opts, now_ms)

    unknown_circuit_regions =
      affected_regions(node_ids, fn node_id ->
        Enum.any?(transports, fn transport ->
          get_in(circuits, [{provider_id, node_id}, transport]) in [nil, :unknown]
        end)
      end)

    missing_block_regions = missing_block_regions(provider_id, node_ids, blocks, now_ms)

    %{
      slot_states: slot_states,
      circuit_slots: circuit_slots,
      lagging_regions: lagging_regions,
      missing_block_regions: missing_block_regions,
      open_regions: open_regions,
      rate_limit_slots: rate_limit_slots,
      rate_limited_regions: rate_limited_regions,
      recovering_circuit_regions: recovering_circuit_regions,
      recovering_regions: recovering_regions,
      unhealthy_regions: unhealthy_regions,
      unknown_circuit_regions: unknown_circuit_regions,
      ws_disconnected_regions: ws_disconnected_regions
    }
  end

  defp project_evidence(evidence, node_ids) do
    %{
      slot_states: slot_states,
      circuit_slots: circuit_slots,
      lagging_regions: lagging_regions,
      missing_block_regions: missing_block_regions,
      open_regions: open_regions,
      rate_limit_slots: rate_limit_slots,
      rate_limited_regions: rate_limited_regions,
      recovering_circuit_regions: recovering_circuit_regions,
      recovering_regions: recovering_regions,
      unhealthy_regions: unhealthy_regions,
      unknown_circuit_regions: unknown_circuit_regions,
      ws_disconnected_regions: ws_disconnected_regions
    } = evidence

    cond do
      circuit_slots == [] ->
        projection(:unknown, :no_transport_evidence, node_ids, node_ids)

      Enum.all?(circuit_slots, &(&1 == :open)) ->
        projection(:circuit_open, :all_circuits_open, open_regions, node_ids)

      rate_limit_slots != [] and Enum.all?(rate_limit_slots) ->
        projection(:rate_limited, :all_rate_limited, rate_limited_regions, node_ids)

      Enum.all?(slot_states, &(&1 in [:circuit_open, :rate_limited, :ws_disconnected])) ->
        projection(:degraded, :mixed_route_failures, node_ids, node_ids)

      Enum.any?(circuit_slots, &(&1 == :open)) ->
        projection(:degraded, :partial_circuit_open, open_regions, node_ids)

      Enum.any?(rate_limit_slots) ->
        projection(:degraded, :partial_rate_limit, rate_limited_regions, node_ids)

      Enum.any?(circuit_slots, &(&1 == :half_open)) ->
        projection(
          :recovering,
          :circuit_recovering,
          recovering_circuit_regions,
          node_ids
        )

      ws_disconnected_regions != [] ->
        projection(:degraded, :websocket_disconnected, ws_disconnected_regions, node_ids)

      unhealthy_regions != [] ->
        projection(:degraded, :health_degraded, unhealthy_regions, node_ids)

      recovering_regions != [] ->
        projection(:recovering, :health_recovering, recovering_regions, node_ids)

      Enum.all?(circuit_slots, &(&1 == :unknown)) ->
        projection(:unknown, :missing_circuit_evidence, unknown_circuit_regions, node_ids)

      Enum.any?(circuit_slots, &(&1 == :unknown)) ->
        projection(:degraded, :partial_circuit_evidence, unknown_circuit_regions, node_ids)

      length(missing_block_regions) == length(node_ids) ->
        projection(:unknown, :missing_block_evidence, missing_block_regions, node_ids)

      lagging_regions != [] ->
        projection(:lagging, :block_lag, lagging_regions, node_ids)

      true ->
        projection(:healthy, :healthy, [], node_ids)
    end
  end

  defp projection(status, reason, affected_regions, node_ids) do
    %{
      status: status,
      reason: reason,
      affected_regions: affected_regions,
      total_regions: length(node_ids)
    }
  end

  defp local_reason(:circuit_open), do: :all_circuits_open
  defp local_reason(:rate_limited), do: :all_rate_limited
  defp local_reason(:testing_recovery), do: :circuit_recovering
  defp local_reason(:recovering), do: :health_recovering
  defp local_reason(:lagging), do: :block_lag
  defp local_reason(:degraded), do: :health_degraded
  defp local_reason(:healthy), do: :healthy
  defp local_reason(:unknown), do: :missing_evidence
  defp local_reason(_status), do: :missing_evidence

  defp affected_regions(node_ids, predicate), do: Enum.filter(node_ids, predicate)

  defp supported_transports(connection) do
    []
    |> maybe_add_transport(
      is_binary(Map.get(connection, :url)) or Map.get(connection, :type) in [:http, :both],
      :http
    )
    |> maybe_add_transport(
      is_binary(Map.get(connection, :ws_url)) or
        Map.get(connection, :type) in [:websocket, :both],
      :ws
    )
    |> Enum.reverse()
  end

  defp maybe_add_transport(transports, true, transport), do: [transport | transports]
  defp maybe_add_transport(transports, false, _transport), do: transports

  defp rate_limit_key(:http), do: :http_rate_limited
  defp rate_limit_key(:ws), do: :ws_rate_limited

  defp websocket_disconnected_in_region?(provider_id, node_id, circuits) do
    case Map.get(circuits, {provider_id, node_id}) do
      %{ws: :closed, ws_connected: false} -> true
      _ -> false
    end
  end

  defp unhealthy_regions(provider_id, node_ids, health) do
    affected_regions(node_ids, fn node_id ->
      evidence = Map.get(health, {provider_id, node_id}, %{})

      Map.get(evidence, :status) in @unhealthy_states or
        Map.get(evidence, :http_status) in @unhealthy_states or
        max(
          Map.get(evidence, :consecutive_failures) || 0,
          Map.get(evidence, :probe_consecutive_failures) || 0
        ) >= 3
    end)
  end

  defp recovering_regions(provider_id, node_ids, health) do
    affected_regions(node_ids, fn node_id ->
      get_in(health, [{provider_id, node_id}, :status]) in [:connecting, :recovering]
    end)
  end

  defp lagging_regions(connection, provider_id, node_ids, blocks, opts, now_ms) do
    chain_id = Map.get(connection, :chain_id)
    profile_id = Keyword.get(opts, :profile_id) || Map.get(connection, :profile_id)

    threshold =
      StatusHelpers.lag_threshold_blocks(
        profile_id,
        chain_id
      )

    lagging? =
      Enum.any?(blocks, fn
        {{^provider_id, _origin_node_id}, observation} ->
          lag = assessment_lag(observation)

          fresh_observation?(observation, now_ms) and is_integer(lag) and
            abs(min(0, lag)) > threshold

        _other_provider ->
          false
      end)

    if lagging?, do: node_ids, else: []
  end

  defp missing_block_regions(provider_id, node_ids, blocks, now_ms) do
    fresh? =
      Enum.any?(blocks, fn
        {{^provider_id, _origin_node_id}, observation} ->
          fresh_observation?(observation, now_ms)

        _other_provider ->
          false
      end)

    if fresh?, do: [], else: node_ids
  end

  defp fresh_observation?(observation, now_ms) do
    Observation.fresh?(observation, now_ms)
  end

  defp assessment_lag(%{assessment_lag: lag}), do: lag

  defp assessment_lag(%{
         source: :http,
         height: height,
         reference_height: poll_reference_height
       })
       when is_integer(height) and is_integer(poll_reference_height),
       do: min(0, height - poll_reference_height)

  defp assessment_lag(observation), do: Map.get(observation, :lag)
end
