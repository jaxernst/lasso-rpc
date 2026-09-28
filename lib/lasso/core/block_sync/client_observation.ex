defmodule Lasso.BlockSync.ClientObservation do
  @moduledoc """
  Bounded head evidence from actual client upstream attempts.

  Only head-reporting requests qualify. Extraction is opportunistic and never
  changes the response or the accepted regression floor. Publication runs in an
  isolated, coalescing projection lane; oversized responses remain passthrough.
  """

  alias Lasso.BlockSync.{Registry, Worker}
  alias Lasso.Cluster.Topology
  alias Lasso.Core.ProjectionDispatcher
  alias Lasso.JSONRPC.Quantity
  alias Lasso.Observations.{HeadObservation, HeadSnapshot}
  alias Lasso.Providers.Catalog
  alias Lasso.RPC.{PreparedRequest, Response.Success}

  @dispatcher Lasso.ExecutionProjectionDispatcher
  @max_response_bytes 65_536
  @max_payload_bytes 4_096
  @max_references 8
  @sample_interval_ms 250

  @doc "Wraps eligible transport work, retaining the actual dispatched selector."
  @spec wrap((-> term()), PreparedRequest.t(), map(), atom()) :: (-> term())
  def wrap(task, %PreparedRequest{} = request, identity, :client) do
    if head_request?(request) do
      fn ->
        capture = capture(identity, request.method)
        result = task.()
        observed_at_ms = System.system_time(:millisecond)
        record(capture, result, observed_at_ms)
        result
      end
    else
      task
    end
  end

  def wrap(task, _request, _identity, _origin), do: task

  defp head_request?(%PreparedRequest{method: method} = request)
       when method in ["eth_blockNumber", "eth_getBlockByNumber"] do
    case PreparedRequest.to_legacy_map(request) do
      {:ok, %{"method" => "eth_blockNumber", "params" => []}} ->
        true

      {:ok, %{"method" => "eth_getBlockByNumber", "params" => ["latest", full]}}
      when is_boolean(full) ->
        true

      _ ->
        false
    end
  end

  defp head_request?(_request), do: false

  defp capture(identity, method) do
    now_ms = System.system_time(:millisecond)

    with false <-
           recently_observed?(
             identity.chain_id,
             identity.upstream_instance_id,
             identity.transport,
             now_ms
           ),
         %{} = catalog <- Catalog.snapshot(),
         {:ok, plan} <- Catalog.get_routing_plan(catalog, identity.profile, identity.chain_id),
         true <- identity.upstream_instance_id in plan.head_scope.instance_ids do
      scopes =
        [
          plan.head_scope
          | Catalog.head_scopes_for_instance(catalog, identity.upstream_instance_id)
        ]
        |> Stream.uniq_by(& &1.scope_id)
        |> Enum.take(@max_references)

      references =
        Enum.flat_map(scopes, fn scope ->
          with {:ok, snapshot} <- Registry.get_cached_head_snapshot(scope),
               {:ok, reference} <- HeadSnapshot.reference(snapshot),
               true <- is_nil(reference.observed_at_ms) or reference.observed_at_ms <= now_ms do
            [%{reference | captured_at_ms: now_ms}]
          else
            _ -> []
          end
        end)

      %{
        method: method,
        profile: identity.profile,
        chain_id: identity.chain_id,
        instance_id: identity.upstream_instance_id,
        transport: identity.transport,
        references: references,
        freshness_ms: plan.head_scope.policy.reference_freshness_ms
      }
    else
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  catch
    :exit, _ -> nil
  end

  defp record(nil, _result, _observed_at_ms), do: :ok

  defp record(capture, {:ok, %Success{raw_bytes: bytes}, _latency}, observed_at_ms)
       when byte_size(bytes) <= @max_response_bytes do
    ProjectionDispatcher.enqueue_lazy(
      @dispatcher,
      :head_observations,
      {capture.instance_id <> ":" <> Atom.to_string(capture.transport), capture.chain_id},
      fn ->
        with {:ok, %{"result" => result}} <- Jason.decode(bytes),
             {:ok, fields} <- head_fields(capture.method, result),
             {:ok, observation} <-
               HeadObservation.new(
                 Map.merge(fields, %{
                   chain_id: capture.chain_id,
                   instance_id: capture.instance_id,
                   transport: capture.transport,
                   observed_at_ms: observed_at_ms,
                   origin_member_id: Topology.self_node_id(),
                   poll_references: capture.references,
                   attributes: %{collection: :client, evidence_freshness_ms: capture.freshness_ms}
                 })
               ) do
          encode(capture.profile, observation)
        else
          _ -> {:error, :invalid_head_response}
        end
      end
    )

    :ok
  rescue
    ArgumentError -> :ok
  catch
    :exit, _ -> :ok
  end

  defp record(_capture, _result, _observed_at_ms), do: :ok

  defp head_fields("eth_blockNumber", value) when is_binary(value) do
    with {:ok, height} <- Quantity.decode(value), do: {:ok, %{height: height}}
  end

  defp head_fields("eth_getBlockByNumber", %{
         "number" => number,
         "hash" => hash,
         "timestamp" => timestamp
       }) do
    with {:ok, height} <- Quantity.decode(number),
         {:ok, timestamp} <- Quantity.decode(timestamp),
         true <- is_binary(hash) and Regex.match?(~r/\A0x[0-9a-fA-F]{64}\z/, hash) do
      {:ok, %{height: height, block_hash: hash, block_timestamp: timestamp}}
    else
      _ -> {:error, :invalid_header}
    end
  end

  defp head_fields(_, _), do: {:error, :invalid_head_response}

  defp encode(profile, observation) do
    base = {1, profile, %{observation | poll_references: []}}
    available = @max_payload_bytes - :erlang.external_size(base) - 8

    {references, _remaining} =
      Enum.reduce(observation.poll_references, {[], available}, fn reference, {refs, remaining} ->
        size = :erlang.external_size(reference)

        if size <= remaining,
          do: {[reference | refs], remaining - size},
          else: {refs, remaining}
      end)

    payload =
      :erlang.term_to_binary(
        {1, profile, %{observation | poll_references: Enum.reverse(references)}}
      )

    if byte_size(payload) <= @max_payload_bytes,
      do: {:ok, payload},
      else: {:error, :oversized_head_observation}
  end

  @doc "Configures the bounded, isolated lane for optional head publication."
  @spec lane_options() :: keyword()
  def lane_options do
    [
      capacity: 256,
      byte_capacity: 256 * 4_096,
      scope_capacity: 1,
      scope_byte_capacity: 4_096,
      shards: 4,
      coalesce: :latest,
      max_age_ms: 2_000,
      audit_interval_ms: 250,
      sink: &__MODULE__.deliver/2
    ]
  end

  @doc "Publishes an encoded client fact if its initiating profile still references the instance."
  @spec deliver(term(), binary()) :: :ok
  def deliver(_scope, payload) do
    {1, profile, %HeadObservation{} = observation} = :erlang.binary_to_term(payload, [:safe])

    if profile in Catalog.get_instance_refs(observation.instance_id) and
         not recently_observed?(
           observation.chain_id,
           observation.instance_id,
           observation.transport,
           observation.observed_at_ms
         ) do
      Worker.publish_client_observation(observation)
    end

    :ok
  end

  defp recently_observed?(chain_id, instance_id, transport, now_ms) do
    case Registry.get_observation(chain_id, instance_id, transport) do
      {:ok, observation} -> now_ms - observation.observed_at_ms < @sample_interval_ms
      _ -> false
    end
  end
end
