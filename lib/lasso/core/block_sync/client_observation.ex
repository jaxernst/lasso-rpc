defmodule Lasso.BlockSync.ClientObservation do
  @moduledoc """
  Bounded head evidence from actual client upstream attempts.

  Only head-reporting requests qualify. Extraction is opportunistic and never
  changes the response or the accepted regression floor. On the request path one
  registry read decides whether an answer is new evidence; scope references are
  read and the observation published in an isolated, coalescing projection lane.
  Oversized responses remain passthrough.
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
  @max_references 8
  @sample_interval_ms 250

  @doc "Wraps eligible transport work, retaining the actual dispatched selector."
  @spec wrap((-> term()), PreparedRequest.t(), map(), atom()) :: (-> term())
  def wrap(task, %PreparedRequest{} = request, identity, :client) do
    if head_request?(request) do
      fn ->
        sent_at_ms = System.system_time(:millisecond)
        result = task.()
        record(identity, request.method, sent_at_ms, result)
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

  # A `latest` block is sampled before its body is decoded. An eth_blockNumber answer is
  # skipped only when it repeats a recent head, so a height a client was just told is
  # evidence for the client's next read.
  defp record(identity, method, sent_at_ms, {:ok, %Success{raw_bytes: bytes}, _latency})
       when byte_size(bytes) <= @max_response_bytes do
    observed_at_ms = System.system_time(:millisecond)
    %{chain_id: chain_id, upstream_instance_id: instance_id, transport: transport} = identity
    recent = recent_observation(chain_id, instance_id, transport, observed_at_ms)

    with false <- method == "eth_getBlockByNumber" and recent != nil,
         {:ok, %{"result" => result}} <- Jason.decode(bytes),
         {:ok, fields} <- head_fields(method, result),
         false <- recent != nil and fields.height <= recent.height do
      ProjectionDispatcher.enqueue(
        @dispatcher,
        :head_observations,
        {instance_id <> ":" <> Atom.to_string(transport), chain_id},
        :erlang.term_to_binary(
          {{identity.profile, chain_id, instance_id, transport}, sent_at_ms, observed_at_ms,
           fields}
        )
      )
    end

    :ok
  rescue
    ArgumentError -> :ok
  catch
    :exit, _ -> :ok
  end

  defp record(_identity, _method, _sent_at_ms, _result), do: :ok

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

  @doc "Publishes a client-served head if its initiating profile still references the instance."
  @spec deliver(term(), binary()) :: :ok
  def deliver(_scope, payload) do
    {{profile, _chain_id, instance_id, _transport} = route, sent_at_ms, observed_at_ms, fields} =
      :erlang.binary_to_term(payload, [:safe])

    with true <- profile in Catalog.get_instance_refs(instance_id),
         {:ok, observation} <- observation(route, sent_at_ms, observed_at_ms, fields) do
      Worker.publish_client_observation(observation)
    end

    :ok
  end

  defp recent_observation(chain_id, instance_id, transport, now_ms) do
    case Registry.get_observation(chain_id, instance_id, transport) do
      {:ok, last} when now_ms - last.observed_at_ms < @sample_interval_ms -> last
      _ -> nil
    end
  end

  # The scope references are those a poll had reported before the request was sent.
  defp observation(
         {profile, chain_id, instance_id, transport},
         sent_at_ms,
         observed_at_ms,
         fields
       ) do
    with %{} = catalog <- Catalog.snapshot(),
         {:ok, plan} <- Catalog.get_routing_plan(catalog, profile, chain_id),
         true <- instance_id in plan.head_scope.instance_ids do
      references =
        [plan.head_scope | Catalog.head_scopes_for_instance(catalog, instance_id)]
        |> Stream.uniq_by(& &1.scope_id)
        |> Enum.take(@max_references)
        |> Enum.flat_map(fn scope ->
          with {:ok, snapshot} <- Registry.get_cached_head_snapshot(scope),
               {:ok, reference} <- HeadSnapshot.reference(snapshot),
               true <- is_nil(reference.observed_at_ms) or reference.observed_at_ms <= sent_at_ms do
            [%{reference | captured_at_ms: sent_at_ms}]
          else
            _ -> []
          end
        end)

      HeadObservation.new(
        Map.merge(fields, %{
          chain_id: chain_id,
          instance_id: instance_id,
          transport: transport,
          observed_at_ms: observed_at_ms,
          origin_member_id: Topology.self_node_id(),
          poll_references: references,
          attributes: %{
            collection: :client,
            evidence_freshness_ms: plan.head_scope.policy.reference_freshness_ms
          }
        })
      )
    end
  end
end
