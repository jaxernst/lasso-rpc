defmodule Lasso.RPC.RequestProjection do
  @moduledoc false

  alias Lasso.Core.ProjectionDispatcher
  alias Lasso.Events.RoutingDecision

  alias Lasso.RPC.{
    ExecutionFact,
    ExecutionProjector,
    RequestTerminal
  }

  alias Lasso.RPC.ExecutionFact.Codec

  @schema :lasso_request_projection
  @version 1
  @max_bytes 4_096
  @dispatcher Lasso.ExecutionProjectionDispatcher

  @enforce_keys [:version, :fact, :method, :request_origin, :failover_count, :emitted_at_ms]
  defstruct @enforce_keys ++ [:provider_id, :instance_id, :transport]

  @type route_identity :: %{
          provider_id: binary(),
          instance_id: binary() | nil,
          transport: :http | :ws
        }

  @type t :: %__MODULE__{
          version: 1,
          fact: RequestTerminal.t(),
          method: binary(),
          provider_id: binary() | nil,
          instance_id: binary() | nil,
          transport: :http | :ws | nil,
          request_origin: :client | :system,
          failover_count: 0..16,
          emitted_at_ms: non_neg_integer()
        }

  @spec new(
          RequestTerminal.t(),
          binary(),
          route_identity() | nil,
          non_neg_integer(),
          :client | :system
        ) :: t()
  def new(fact, method, route_identity, failover_count, request_origin \\ :client) do
    %__MODULE__{
      version: @version,
      fact: fact,
      method: method,
      provider_id: route_value(route_identity, :provider_id),
      instance_id: route_value(route_identity, :instance_id),
      transport: route_value(route_identity, :transport),
      request_origin: request_origin,
      failover_count: failover_count,
      emitted_at_ms: System.system_time(:millisecond)
    }
    |> validate!()
  end

  @spec enqueue(t(), atom()) :: term()
  def enqueue(%__MODULE__{} = event, dispatcher \\ @dispatcher) when is_atom(dispatcher) do
    ProjectionDispatcher.enqueue_lazy(
      dispatcher,
      :diagnostics,
      {Map.fetch!(event.fact, :profile), Map.fetch!(event.fact, :chain_id)},
      fn -> encode(event) end
    )
  end

  @spec encode(t()) :: {:ok, binary()} | {:error, atom()}
  def encode(%__MODULE__{} = event) do
    event = validate!(event)

    with {:ok, fact_payload} <- Codec.encode(event.fact) do
      payload =
        :erlang.term_to_binary(
          {
            @schema,
            @version,
            fact_payload,
            event.method,
            event.provider_id,
            event.instance_id,
            event.transport,
            event.request_origin,
            event.failover_count,
            event.emitted_at_ms
          },
          [:deterministic]
        )

      if byte_size(payload) <= @max_bytes,
        do: {:ok, payload},
        else: {:error, :event_too_large}
    end
  rescue
    ArgumentError -> {:error, :invalid_event}
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, atom()}
  def decode(payload) when is_binary(payload) and byte_size(payload) <= @max_bytes do
    case :erlang.binary_to_term(payload, [:safe]) do
      {
        @schema,
        @version,
        fact_payload,
        method,
        provider_id,
        instance_id,
        transport,
        request_origin,
        failover_count,
        emitted_at_ms
      } ->
        case Codec.decode(fact_payload) do
          {:ok, fact} ->
            event = %__MODULE__{
              version: @version,
              fact: fact,
              method: method,
              provider_id: provider_id,
              instance_id: instance_id,
              transport: transport,
              request_origin: request_origin,
              failover_count: failover_count,
              emitted_at_ms: emitted_at_ms
            }

            {:ok, validate!(event)}

          {:error, _reason} ->
            {:error, :invalid_fact}
        end

      {@schema, version, _fact, _method, _provider, _instance, _transport, _request_origin,
       _failovers, _emitted_at_ms}
      when is_integer(version) ->
        {:error, :unsupported_version}

      _other ->
        {:error, :invalid_event}
    end
  rescue
    ArgumentError -> {:error, :invalid_event}
  end

  def decode(payload) when is_binary(payload), do: {:error, :event_too_large}

  @spec routing_decision(t()) :: {:ok, RoutingDecision.t()} | :not_routed
  def routing_decision(%__MODULE__{provider_id: provider_id, transport: transport} = event)
      when is_binary(provider_id) and transport in [:http, :ws] do
    fact = event.fact

    {:ok,
     RoutingDecision.new(
       ts: event.emitted_at_ms,
       request_id: Map.fetch!(fact, :request_id),
       profile: Map.fetch!(fact, :profile),
       chain_id: Map.fetch!(fact, :chain_id),
       method: event.method,
       strategy: Map.fetch!(fact, :routing_intent),
       provider_id: provider_id,
       instance_id: event.instance_id,
       transport: transport,
       request_origin: event.request_origin,
       duration_ms: div(Map.fetch!(fact, :elapsed_us), 1_000),
       result: result(event.fact),
       failover_count: event.failover_count
     )}
  end

  def routing_decision(%__MODULE__{}), do: :not_routed

  @spec deliver(t()) :: :ok
  def deliver(%__MODULE__{} = event) do
    publish_routing_decision(event)
    emit_terminal_telemetry(event)
    emit_request_telemetry(event)
    :ok
  end

  defp publish_routing_decision(event) do
    with {:ok, decision} <- routing_decision(event) do
      Phoenix.PubSub.broadcast(
        Lasso.PubSub,
        Lasso.Topics.routing_decision(decision.profile),
        decision
      )
    end
  end

  defp emit_terminal_telemetry(event) do
    fact = event.fact
    projection = ExecutionProjector.project(fact)

    :telemetry.execute(
      [:lasso, :rpc, :request, :terminal],
      %{count: 1, elapsed_us: Map.fetch!(fact, :elapsed_us)},
      %{
        request_id: Map.fetch!(fact, :request_id),
        profile: Map.fetch!(fact, :profile),
        chain_id: Map.fetch!(fact, :chain_id),
        method: event.method,
        provider_id: event.provider_id,
        instance_id: event.instance_id,
        transport: event.transport,
        request_origin: event.request_origin,
        result: result(fact),
        failovers: event.failover_count,
        diagnostic: projection.diagnostic,
        candidate_admission_count: Map.fetch!(fact, :candidate_admission_count),
        dispatch_count: Map.fetch!(fact, :dispatch_count)
      }
    )
  end

  defp emit_request_telemetry(event) do
    fact = event.fact
    result = result(fact)

    :telemetry.execute(
      [:lasso, :rpc, :request, :stop],
      %{duration: div(Map.fetch!(fact, :elapsed_us), 1_000)},
      %{
        chain_id: Map.fetch!(fact, :chain_id),
        method: event.method,
        strategy: Map.fetch!(fact, :routing_intent),
        provider_id: event.provider_id,
        instance_id: event.instance_id,
        transport: event.transport,
        request_origin: event.request_origin,
        result: result,
        status: result,
        failovers: event.failover_count
      }
    )
  end

  defp validate!(%__MODULE__{} = event) do
    if event.version != @version, do: raise(ArgumentError, "unsupported version")
    unless request_terminal?(event.fact), do: raise(ArgumentError, "invalid request terminal")

    provider_id = ExecutionFact.optional_bounded!(event.provider_id, :provider_id)
    instance_id = ExecutionFact.optional_bounded!(event.instance_id, :instance_id)

    transport =
      case event.transport do
        nil -> nil
        value -> ExecutionFact.transport!(value)
      end

    if is_nil(provider_id) != is_nil(transport),
      do: raise(ArgumentError, "provider and transport must be present together")

    if is_nil(provider_id) and not is_nil(instance_id),
      do: raise(ArgumentError, "instance requires a provider")

    if event.request_origin not in [:client, :system],
      do: raise(ArgumentError, "invalid request origin")

    %{
      event
      | version: @version,
        method: ExecutionFact.bounded!(event.method, :method),
        provider_id: provider_id,
        instance_id: instance_id,
        transport: transport,
        request_origin: event.request_origin,
        failover_count: ExecutionFact.candidate_count!(event.failover_count),
        emitted_at_ms: ExecutionFact.non_negative!(event.emitted_at_ms, :emitted_at_ms)
    }
  end

  defp request_terminal?(%RequestTerminal.UpstreamResponse{}), do: true
  defp request_terminal?(%RequestTerminal.LocalFailure{}), do: true
  defp request_terminal?(%RequestTerminal.Deadline{}), do: true
  defp request_terminal?(%RequestTerminal.CallerAbandonment{}), do: true
  defp request_terminal?(%RequestTerminal.UnsafeIndeterminateExhaustion{}), do: true
  defp request_terminal?(%RequestTerminal.OrdinaryExhaustion{}), do: true
  defp request_terminal?(_fact), do: false

  defp result(%RequestTerminal.UpstreamResponse{attempt: %{kind: :success}}), do: :success
  defp result(_fact), do: :error

  defp route_value(nil, _key), do: nil
  defp route_value(route, key) when is_map(route), do: Map.get(route, key)
end
