defmodule Lasso.RPC.ProviderKnowledge.Evidence do
  @moduledoc "Body-free, bounded facts about one dispatched provider attempt."

  alias Lasso.RPC.{AttemptTerminal, BoundedIdentifier, Channel, MethodRegistry, RequestAnalysis}
  alias Lasso.RPC.Learning.Subject
  alias Lasso.RPC.RoutingEvidence.Workload

  @version 1
  @max_bytes 2_048
  @methods MethodRegistry.all_methods()
  @outcomes [
    :success,
    :application_error,
    :invalid_response,
    :transport_failure,
    :deadline,
    :cancelled
  ]

  @enforce_keys [
    :subject,
    :instance_id,
    :provider_family,
    :profile_class,
    :profile,
    :chain_id,
    :transport,
    :partition,
    :method,
    :shape,
    :outcome,
    :latency_us,
    :dispatch_certainty,
    :execution_safety,
    :ordinal,
    :request_nonce,
    :epoch,
    :origin_node,
    :observed_at_ms
  ]
  defstruct @enforce_keys ++
              [
                :historical_height,
                :historical_target?,
                :shape_value,
                :historical_resource,
                :historical_age,
                :constraint_kind,
                :scoped_constraint?,
                :result_verification,
                :error_category,
                :error_code,
                :template_fingerprint,
                :qualification,
                :dispatched_at_ms,
                :revalidation_partition
              ]

  @type t :: %__MODULE__{}

  @spec dispatched?(AttemptTerminal.t()) :: boolean()
  def dispatched?(fact), do: not is_nil(outcome(fact))

  @spec from_attempt(Channel.t(), map(), AttemptTerminal.t(), atom(), keyword()) :: t() | nil
  def from_attempt(channel, ctx, fact, qualification, opts \\ [])

  def from_attempt(
        %Channel{learning_subject: %Subject{} = subject} = channel,
        ctx,
        fact,
        qualification,
        opts
      ) do
    case outcome(fact) do
      nil ->
        nil

      outcome ->
        identity = fact.identity
        head_height = Keyword.get(opts, :head_height) || captured_head(ctx, identity, opts)
        analysis = RequestAnalysis.analyze(ctx.method, ctx.params, consensus_height: head_height)
        shape = shape(ctx.method, ctx.params, analysis, head_height)

        facts =
          captured_facts(ctx, identity) || RequestAnalysis.block_facts(ctx.method, ctx.params)

        height = Lasso.RPC.RequestFacts.numeric_interval(facts)

        historical_age =
          if height && is_integer(head_height) && head_height >= elem(height, 0),
            do: head_height - elem(height, 0),
            else: historical_age(analysis, head_height)

        evidence = %__MODULE__{
          subject: subject.id,
          instance_id: bounded(channel.instance_id),
          provider_family: family(subject),
          profile_class: profile_class(subject),
          profile: bounded(identity.profile),
          chain_id: identity.chain_id,
          transport: identity.transport,
          partition: Workload.decode(identity.workload_key),
          method: BoundedIdentifier.encode(ctx.method),
          shape: shape,
          shape_value: shape_value(shape, ctx.params, analysis, head_height),
          historical_height: height,
          historical_target?:
            analysis.requires_archival or historical_target?(facts, head_height),
          historical_resource:
            if(height,
              do: facts.resource,
              else: if(historical_age, do: analysis.historical_resource)
            ),
          historical_age: historical_age,
          # Preserve the upstream's narrower typed restriction even when it
          # cannot qualify a historical-depth observation (for example at latest).
          scoped_constraint?: not is_nil(Keyword.get(opts, :constraint_kind)),
          constraint_kind:
            constraint_kind(
              Keyword.get(opts, :constraint_kind),
              if(height, do: %{analysis | historical_height: elem(height, 1)}, else: analysis),
              opts
            ),
          result_verification: Keyword.get(opts, :result_verification),
          outcome: outcome,
          latency_us: latency(fact),
          dispatch_certainty: certainty(fact),
          execution_safety: identity.execution_safety,
          ordinal: identity.dispatch_count,
          request_nonce: bounded(ctx.execution_envelope.execution_nonce),
          epoch: Keyword.get(opts, :epoch, 0),
          dispatched_at_ms: Keyword.get(opts, :dispatched_at_ms),
          origin_node: bounded(Keyword.get(opts, :origin_node, Atom.to_string(Node.self()))),
          observed_at_ms: Keyword.get(opts, :observed_at_ms, System.system_time(:millisecond)),
          error_category: Map.get(fact, :error_category),
          error_code: Map.get(fact, :error_code),
          template_fingerprint: Keyword.get(opts, :template_fingerprint),
          qualification: qualification
        }

        %{
          evidence
          | revalidation_partition:
              Lasso.RPC.ProviderKnowledge.Revalidation.partition(evidence, Map.get(ctx, :opts))
        }
    end
  end

  def from_attempt(%Channel{}, _ctx, _fact, _qualification, _opts), do: nil

  @spec encode(t()) :: {:ok, binary()} | {:error, :invalid | :too_large}
  def encode(%__MODULE__{} = evidence) do
    if valid?(evidence) do
      payload = :erlang.term_to_binary({@version, evidence})
      if byte_size(payload) <= @max_bytes, do: {:ok, payload}, else: {:error, :too_large}
    else
      {:error, :invalid}
    end
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, :invalid | :too_large}
  def decode(payload) when is_binary(payload) and byte_size(payload) <= @max_bytes do
    case :erlang.binary_to_term(payload, [:safe]) do
      {@version, %__MODULE__{} = evidence} ->
        if valid?(evidence), do: {:ok, evidence}, else: {:error, :invalid}

      _ ->
        {:error, :invalid}
    end
  rescue
    ArgumentError -> {:error, :invalid}
  end

  def decode(payload) when is_binary(payload), do: {:error, :too_large}

  defp valid?(evidence) do
    valid_identity?(evidence) and valid_outcome?(evidence) and valid_metadata?(evidence) and
      (is_nil(Map.get(evidence, :revalidation_partition)) or
         (evidence.partition == :system_state and
            Map.get(evidence, :revalidation_partition) == :client_state and
            evidence.method in ["eth_getCode", "eth_call"] and
            evidence.historical_resource == :state))
  end

  defp valid_identity?(evidence) do
    Enum.all?(
      [
        evidence.subject,
        evidence.instance_id,
        evidence.profile,
        evidence.request_nonce,
        evidence.origin_node
      ],
      &bounded_binary?/1
    ) and
      is_binary(evidence.provider_family) and byte_size(evidence.provider_family) <= 64 and
      evidence.profile_class in [:managed, :custom] and
      is_integer(evidence.chain_id) and evidence.chain_id > 0 and
      evidence.transport in [:http, :ws] and evidence.partition in Workload.partitions() and
      (evidence.method == :other or BoundedIdentifier.valid?(evidence.method))
  end

  defp valid_outcome?(evidence) do
    evidence.historical_target? in [nil, true, false] and
      evidence.scoped_constraint? in [nil, true, false] and
      evidence.outcome in @outcomes and is_integer(evidence.latency_us) and
      evidence.latency_us >= 0 and evidence.dispatch_certainty in [:dispatched, :indeterminate] and
      evidence.qualification in [:accepted, :policy_rejected] and
      (is_nil(evidence.error_code) or is_integer(evidence.error_code)) and
      evidence.constraint_kind in [
        nil,
        :block_range,
        :archival,
        :quota_exhaustion,
        :result_volume
      ] and
      evidence.historical_resource in [
        nil,
        :blocks,
        :balance,
        :state,
        :logs,
        :receipts,
        :proofs,
        :traces
      ] and
      evidence.result_verification in [nil, :non_empty, :known_answer, :missing] and
      (is_nil(evidence.template_fingerprint) or bounded_binary?(evidence.template_fingerprint))
  end

  defp valid_metadata?(evidence) do
    Lasso.RPC.ProviderKnowledge.Stats.Bracket.valid_height?(Map.get(evidence, :historical_height)) and
      is_integer(evidence.ordinal) and evidence.ordinal > 0 and
      is_integer(evidence.epoch) and evidence.epoch >= 0 and
      (is_nil(Map.get(evidence, :dispatched_at_ms)) or
         (is_integer(Map.get(evidence, :dispatched_at_ms)) and
            Map.get(evidence, :dispatched_at_ms) >= 0)) and
      is_integer(evidence.observed_at_ms) and evidence.observed_at_ms >= 0 and
      (is_nil(evidence.shape_value) or
         (is_integer(evidence.shape_value) and evidence.shape_value >= 0 and
            evidence.shape_value <= 9_223_372_036_854_775_807)) and
      (is_nil(evidence.historical_age) or
         (is_integer(evidence.historical_age) and evidence.historical_age >= 0 and
            evidence.historical_age <= 9_223_372_036_854_775_807))
  end

  defp captured_head(
         %{
           method: method,
           request_facts: %Lasso.RPC.RequestFacts{
             profile: profile,
             chain_id: chain,
             method: method,
             reference: {:qualified, head, %{valid_through_ms: valid_through}}
           }
         },
         %{profile: profile, chain_id: chain},
         opts
       ) do
    if Keyword.get(opts, :dispatched_at_ms, System.system_time(:millisecond)) <= valid_through,
      do: head.height
  end

  defp captured_head(_ctx, _identity, _opts), do: nil

  @doc "Whether a capability error establishes refusal beyond a historical block target."
  @spec method_refusal?(t() | nil) :: boolean()
  def method_refusal?(
        %__MODULE__{
          outcome: :application_error,
          error_category: :capability,
          constraint_kind: nil,
          error_code: code
        } = evidence
      )
      when code in [-32_601, -32_004] do
    evidence.historical_target? != true and evidence.scoped_constraint? != true
  end

  def method_refusal?(_evidence), do: false

  # Only head/blockless requests can establish a method-wide refusal. An
  # unresolved fixed height or hash cannot establish that the method fails at
  # head. Check both range ends. Omitted bounds cannot establish head either:
  # clients differ on whether a trace_filter with no bounds starts at genesis.
  defp historical_target?(%{range: {from, to}}, head),
    do:
      from == :omitted or to == :omitted or historical_selector?(from, head) or
        historical_selector?(to, head)

  defp historical_target?(%{block: block}, head), do: historical_selector?(block, head)
  defp historical_target?(_facts, _head), do: false

  defp historical_selector?({:number, height}, head) when is_integer(head), do: height != head
  defp historical_selector?({:tag, tag, _}, _head) when tag in [:latest, :pending], do: false
  defp historical_selector?(selector, _head) when selector in [nil, :omitted], do: false
  defp historical_selector?(_selector, _head), do: true

  defp captured_facts(ctx, identity) do
    case Map.get(ctx, :request_facts) do
      %Lasso.RPC.RequestFacts{
        profile: profile,
        chain_id: chain,
        method: method,
        block_facts: facts
      }
      when profile == identity.profile and chain == identity.chain_id and method == ctx.method ->
        facts

      nil ->
        Map.get(ctx, :block_facts)

      _ ->
        nil
    end
  end

  defp outcome(%AttemptTerminal.Response{kind: :success}), do: :success
  defp outcome(%AttemptTerminal.Response{kind: :application_error}), do: :application_error
  defp outcome(%AttemptTerminal.InvalidResponse{}), do: :invalid_response
  defp outcome(%AttemptTerminal.TransportFailure{}), do: :transport_failure

  defp outcome(%AttemptTerminal.Deadline{dispatch_certainty: certainty})
       when certainty != :not_dispatched,
       do: :deadline

  defp outcome(%AttemptTerminal.Cancelled{dispatch_certainty: certainty})
       when certainty != :not_dispatched,
       do: :cancelled

  defp outcome(_), do: nil

  defp latency(%{io_duration_us: value}) when is_integer(value), do: value
  defp latency(%{censoring_boundary_us: value}) when is_integer(value), do: value
  defp latency(_), do: 0

  defp certainty(%{dispatch_certainty: value}), do: value
  defp certainty(_), do: :dispatched

  defp shape("eth_getLogs", [filter], %{block_range: span}, _head) when is_map(filter) do
    anchor =
      if is_binary(filter["blockHash"]),
        do: :hash,
        else: if(filter["fromBlock"] == "latest", do: :latest, else: :number)

    {:logs_span, anchor, band(span)}
  end

  defp shape(_method, _params, %{historical_resource: resource, historical_height: height}, head)
       when not is_nil(resource) and is_integer(height) and is_integer(head) and head >= height,
       do: {:historical_age, resource, band(head - height)}

  defp shape(_method, _params, %{historical_resource: resource}, _head) when not is_nil(resource),
    do: {:historical_age, resource, :unknown}

  defp shape(_method, _params, _analysis, _head), do: :other

  defp shape_value({:logs_span, :number, _band}, [filter], %{block_range: span}, _head)
       when is_map(filter) and is_integer(span) do
    with {:ok, from} <- block_number(filter["fromBlock"]),
         {:ok, to} <- block_number(filter["toBlock"]),
         true <- to >= from do
      span
    else
      _ -> nil
    end
  end

  defp shape_value(
         {:historical_age, _resource, _band},
         _params,
         %{historical_height: height},
         head
       )
       when is_integer(height) and is_integer(head) and head >= height,
       do: head - height

  defp shape_value(_shape, _params, _analysis, _head), do: nil

  defp historical_age(%{historical_height: height}, head)
       when is_integer(height) and is_integer(head) and head >= height,
       do: head - height

  defp historical_age(_analysis, _head), do: nil

  defp constraint_kind(:archival, %{historical_height: height}, opts) do
    case Keyword.get(opts, :provider_head_height) do
      provider_head
      when is_integer(provider_head) and is_integer(height) and provider_head >= height ->
        :archival

      _ ->
        nil
    end
  end

  defp constraint_kind(kind, _analysis, _opts), do: kind

  defp block_number("earliest"), do: {:ok, 0}

  defp block_number("0x" <> hex) do
    case Integer.parse(hex, 16) do
      {number, ""} -> {:ok, number}
      _ -> :error
    end
  end

  defp block_number(_), do: :error

  defp band(nil), do: :unknown
  defp band(0), do: 0

  defp band(value) when is_integer(value) and value > 0,
    do: min(:erlang.floor(:math.log2(value)) + 1, 31)

  @doc "The finite method key shared by feedback and serving lookups."
  @spec method_key(binary()) :: binary() | :other
  def method_key(method) when is_binary(method),
    do: if(method in @methods, do: method, else: :other)

  defp family(%Subject{sharing_scope: :curated}), do: "managed"
  defp family(%Subject{}), do: "custom"
  defp profile_class(%Subject{sharing_scope: :curated}), do: :managed
  defp profile_class(%Subject{}), do: :custom
  defp bounded(value) when is_binary(value), do: BoundedIdentifier.encode(value)
  defp bounded(_), do: "unknown"
  defp bounded_binary?(value), do: is_binary(value) and byte_size(value) in 1..128
end
