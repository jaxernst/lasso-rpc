defmodule Lasso.RPC.ExecutionFact.Codec do
  @moduledoc "Bounded JSON codec for version-one tagged execution facts."

  alias Lasso.RPC.{AdmissionTerminal, AttemptIdentity, LateObservation}
  alias Lasso.RPC.AttemptTerminal
  alias Lasso.RPC.RequestTerminal

  @schema "lasso.execution-fact"
  @major 1
  @minor 0
  @max_bytes 4_096

  @spec encode(struct()) :: {:ok, binary()} | {:error, :fact_too_large | :unsupported_fact}
  def encode(fact) do
    with {:ok, tagged} <- encode_fact(fact),
         {:ok, json} <- Jason.encode(envelope(tagged)),
         true <- byte_size(json) <= @max_bytes do
      {:ok, json}
    else
      false -> {:error, :fact_too_large}
      {:error, _} = error -> error
    end
  end

  @spec encode!(struct()) :: binary()
  def encode!(fact) do
    case encode(fact) do
      {:ok, json} -> json
      {:error, reason} -> raise ArgumentError, "cannot encode execution fact: #{inspect(reason)}"
    end
  end

  @spec decode(binary()) :: {:ok, struct()} | {:error, term()}
  def decode(json) when is_binary(json) and byte_size(json) <= @max_bytes do
    with {:ok, map} <- Jason.decode(json),
         :ok <- validate_envelope(map),
         {:ok, fact} <- decode_fact(map) do
      {:ok, fact}
    else
      {:error, %Jason.DecodeError{}} -> {:error, :malformed_json}
      {:error, _} = error -> error
    end
  rescue
    ArgumentError -> {:error, :invalid_fact}
    KeyError -> {:error, :invalid_fact}
    FunctionClauseError -> {:error, :invalid_fact}
  end

  def decode(json) when is_binary(json), do: {:error, :fact_too_large}

  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  defp envelope(tagged),
    do:
      Map.merge(
        %{"schema" => @schema, "version" => %{"major" => @major, "minor" => @minor}},
        tagged
      )

  defp validate_envelope(%{
         "schema" => @schema,
         "version" => %{"major" => @major, "minor" => minor}
       })
       when is_integer(minor) and minor >= 0,
       do: :ok

  defp validate_envelope(%{
         "schema" => @schema,
         "version" => %{"major" => major, "minor" => minor}
       })
       when is_integer(major) and is_integer(minor) and minor >= 0,
       do: {:error, :unsupported_major_version}

  defp validate_envelope(_), do: {:error, :invalid_envelope}

  defp encode_fact(%AdmissionTerminal{} = fact) do
    {:ok,
     %{
       "stage" => "admission",
       "variant" => "rejected",
       "request" => request_scope(fact),
       "reason" => Atom.to_string(fact.reason),
       "candidate_admission_count" => fact.candidate_admission_count,
       "dispatch_count" => fact.dispatch_count,
       "elapsed_us" => fact.elapsed_us,
       "retry_after_ms" => fact.retry_after_ms,
       "observed_at" => fact.observed_at
     }}
  end

  defp encode_fact(%AttemptTerminal.PredispatchFailure{} = fact),
    do:
      attempt("predispatch_failure", fact.identity, %{
        "reason" => Atom.to_string(fact.reason),
        "elapsed_us" => fact.elapsed_us
      })

  defp encode_fact(%AttemptTerminal.Response{} = fact) do
    attempt("response", fact.identity, %{
      "kind" => Atom.to_string(fact.kind),
      "io_duration_us" => fact.io_duration_us,
      "error_code" => fact.error_code,
      "error_category" => if(fact.error_category, do: Atom.to_string(fact.error_category)),
      "retry_after_ms" => fact.retry_after_ms
    })
  end

  defp encode_fact(%AttemptTerminal.InvalidResponse{} = fact),
    do:
      attempt("invalid_response", fact.identity, %{
        "reason" => Atom.to_string(fact.reason),
        "io_duration_us" => fact.io_duration_us
      })

  defp encode_fact(%AttemptTerminal.TransportFailure{} = fact),
    do:
      attempt("transport_failure", fact.identity, %{
        "reason" => Atom.to_string(fact.reason),
        "dispatch_certainty" => Atom.to_string(fact.dispatch_certainty),
        "io_duration_us" => fact.io_duration_us
      })

  defp encode_fact(%AttemptTerminal.Deadline{} = fact),
    do:
      attempt("deadline", fact.identity, %{
        "dispatch_certainty" => Atom.to_string(fact.dispatch_certainty),
        "censoring_boundary_us" => fact.censoring_boundary_us
      })

  defp encode_fact(%AttemptTerminal.Cancelled{} = fact),
    do:
      attempt("cancelled", fact.identity, %{
        "reason" => Atom.to_string(fact.reason),
        "dispatch_certainty" => Atom.to_string(fact.dispatch_certainty),
        "censoring_boundary_us" => fact.censoring_boundary_us
      })

  defp encode_fact(%RequestTerminal.UpstreamResponse{} = fact) do
    {:ok, attempt} = encode_fact(fact.attempt)
    request("upstream_response", fact, %{"attempt" => attempt})
  end

  defp encode_fact(%RequestTerminal.LocalFailure{} = fact),
    do: request("local_failure", fact, %{"reason" => Atom.to_string(fact.reason)})

  defp encode_fact(%RequestTerminal.Deadline{} = fact),
    do:
      request("deadline", fact, %{"dispatch_certainty" => Atom.to_string(fact.dispatch_certainty)})

  defp encode_fact(%RequestTerminal.CallerAbandonment{} = fact),
    do:
      request("caller_abandonment", fact, %{
        "dispatch_certainty" => Atom.to_string(fact.dispatch_certainty)
      })

  defp encode_fact(%RequestTerminal.UnsafeIndeterminateExhaustion{} = fact),
    do: request("unsafe_indeterminate_exhaustion", fact, %{})

  defp encode_fact(%RequestTerminal.OrdinaryExhaustion{} = fact),
    do: request("ordinary_exhaustion", fact, %{"reason" => Atom.to_string(fact.reason)})

  defp encode_fact(%LateObservation{} = fact) do
    {:ok,
     %{
       "stage" => "late_observation",
       "variant" => Atom.to_string(fact.kind),
       "request_id" => fact.request_id,
       "attempt_id" => fact.attempt_id,
       "elapsed_us" => fact.elapsed_us,
       "detail" => fact.detail
     }}
  end

  defp encode_fact(_fact), do: {:error, :unsupported_fact}

  defp attempt(variant, identity, body),
    do:
      {:ok,
       Map.merge(
         %{"stage" => "attempt", "variant" => variant, "identity" => identity_map(identity)},
         body
       )}

  defp request(variant, fact, body),
    do:
      {:ok,
       Map.merge(
         %{"stage" => "request", "variant" => variant, "request" => request_common(fact)},
         body
       )}

  defp identity_map(identity) do
    %{
      "request_id" => identity.request_id,
      "attempt_id" => identity.attempt_id,
      "profile" => identity.profile,
      "subject_token" => identity.subject_token,
      "chain_id" => identity.chain_id,
      "upstream_instance_id" => identity.upstream_instance_id,
      "transport" => Atom.to_string(identity.transport),
      "route_generation" => identity.route_generation,
      "circuit_scope" => Atom.to_string(identity.circuit_scope),
      "circuit_epoch" => identity.circuit_epoch,
      "execution_safety" => Atom.to_string(identity.execution_safety),
      "routing_intent" => identity.routing_intent,
      "workload_key" => identity.workload_key,
      "request_budget_ms" => identity.request_budget_ms,
      "candidate_admission_count" => identity.candidate_admission_count,
      "dispatch_count" => identity.dispatch_count
    }
  end

  defp request_scope(fact) do
    %{
      "request_id" => fact.request_id,
      "profile" => fact.profile,
      "subject_token" => fact.subject_token,
      "chain_id" => fact.chain_id,
      "routing_intent" => fact.routing_intent,
      "workload_key" => fact.workload_key
    }
  end

  defp request_common(fact) do
    fact
    |> request_scope()
    |> Map.merge(%{
      "execution_safety" => Atom.to_string(fact.execution_safety),
      "elapsed_us" => fact.elapsed_us,
      "candidate_admission_count" => fact.candidate_admission_count,
      "dispatch_count" => fact.dispatch_count,
      "observed_at" => fact.observed_at
    })
  end

  defp decode_fact(%{"stage" => "admission", "variant" => "rejected", "request" => request} = map) do
    {:ok,
     AdmissionTerminal.new(
       request_attrs(request) ++
         [
           reason: admission_reason(map["reason"]),
           candidate_admission_count: map["candidate_admission_count"],
           dispatch_count: map["dispatch_count"],
           elapsed_us: map["elapsed_us"],
           retry_after_ms: map["retry_after_ms"],
           observed_at: map["observed_at"]
         ]
     )}
  end

  defp decode_fact(%{"stage" => "attempt", "variant" => variant, "identity" => encoded} = map) do
    identity = decode_identity(encoded)
    decode_attempt(variant, identity, map)
  end

  defp decode_fact(%{"stage" => "request", "variant" => variant, "request" => request} = map),
    do: decode_request(variant, request_common_attrs(request), map)

  defp decode_fact(%{"stage" => "late_observation", "variant" => kind} = map) do
    {:ok,
     LateObservation.new(
       request_id: map["request_id"],
       attempt_id: map["attempt_id"],
       kind: late_kind(kind),
       elapsed_us: map["elapsed_us"],
       detail: map["detail"]
     )}
  end

  defp decode_fact(_), do: {:error, :unsupported_discriminator}

  defp decode_attempt("predispatch_failure", identity, map),
    do:
      {:ok,
       AttemptTerminal.PredispatchFailure.new(
         identity,
         predispatch_reason(map["reason"]),
         map["elapsed_us"]
       )}

  defp decode_attempt("response", identity, map),
    do:
      {:ok,
       AttemptTerminal.Response.new(identity, response_kind(map["kind"]), map["io_duration_us"],
         error_code: map["error_code"],
         error_category: response_category(map["error_category"]),
         retry_after_ms: map["retry_after_ms"]
       )}

  defp decode_attempt("invalid_response", identity, map),
    do:
      {:ok,
       AttemptTerminal.InvalidResponse.new(
         identity,
         invalid_response_reason(map["reason"]),
         map["io_duration_us"]
       )}

  defp decode_attempt("transport_failure", identity, map),
    do:
      {:ok,
       AttemptTerminal.TransportFailure.new(
         identity,
         transport_reason(map["reason"]),
         certainty(map["dispatch_certainty"]),
         io_duration_us: map["io_duration_us"]
       )}

  defp decode_attempt("deadline", identity, map),
    do:
      {:ok,
       AttemptTerminal.Deadline.new(
         identity,
         certainty(map["dispatch_certainty"]),
         map["censoring_boundary_us"]
       )}

  defp decode_attempt("cancelled", identity, map),
    do:
      {:ok,
       AttemptTerminal.Cancelled.new(
         identity,
         cancellation_reason(map["reason"]),
         certainty(map["dispatch_certainty"]),
         map["censoring_boundary_us"]
       )}

  defp decode_attempt(_, _, _), do: {:error, :unsupported_discriminator}

  defp decode_request("upstream_response", attrs, %{
         "attempt" => %{"variant" => "response", "identity" => encoded} = attempt_map
       }) do
    with {:ok, %AttemptTerminal.Response{} = attempt} <-
           decode_attempt("response", decode_identity(encoded), attempt_map) do
      {:ok, RequestTerminal.UpstreamResponse.new(attrs, attempt)}
    end
  end

  defp decode_request("local_failure", attrs, map),
    do: {:ok, RequestTerminal.LocalFailure.new(attrs, local_reason(map["reason"]))}

  defp decode_request("deadline", attrs, map),
    do: {:ok, RequestTerminal.Deadline.new(attrs, certainty(map["dispatch_certainty"]))}

  defp decode_request("caller_abandonment", attrs, map),
    do: {:ok, RequestTerminal.CallerAbandonment.new(attrs, certainty(map["dispatch_certainty"]))}

  defp decode_request("unsafe_indeterminate_exhaustion", attrs, _map),
    do: {:ok, RequestTerminal.UnsafeIndeterminateExhaustion.new(attrs)}

  defp decode_request("ordinary_exhaustion", attrs, map),
    do: {:ok, RequestTerminal.OrdinaryExhaustion.new(attrs, exhaustion_reason(map["reason"]))}

  defp decode_request(_, _, _), do: {:error, :unsupported_discriminator}

  defp decode_identity(map) do
    AttemptIdentity.new(
      request_id: map["request_id"],
      attempt_id: map["attempt_id"],
      profile: map["profile"],
      subject_token: map["subject_token"],
      chain_id: map["chain_id"],
      upstream_instance_id: map["upstream_instance_id"],
      transport: transport(map["transport"]),
      route_generation: map["route_generation"],
      circuit_scope: circuit_scope(map["circuit_scope"]),
      circuit_epoch: map["circuit_epoch"],
      execution_safety: safety(map["execution_safety"]),
      routing_intent: map["routing_intent"],
      workload_key: map["workload_key"],
      request_budget_ms: map["request_budget_ms"],
      candidate_admission_count: map["candidate_admission_count"],
      dispatch_count: map["dispatch_count"]
    )
  end

  defp request_attrs(map),
    do: [
      request_id: map["request_id"],
      profile: map["profile"],
      subject_token: map["subject_token"],
      chain_id: map["chain_id"],
      routing_intent: map["routing_intent"],
      workload_key: map["workload_key"]
    ]

  defp request_common_attrs(map),
    do:
      request_attrs(map) ++
        [
          execution_safety: safety(map["execution_safety"]),
          elapsed_us: map["elapsed_us"],
          candidate_admission_count: map["candidate_admission_count"],
          dispatch_count: map["dispatch_count"],
          observed_at: map["observed_at"]
        ]

  defp certainty("not_dispatched"), do: :not_dispatched
  defp certainty("indeterminate"), do: :indeterminate
  defp certainty("dispatched"), do: :dispatched
  defp response_category(nil), do: nil
  defp transport("http"), do: :http
  defp transport("ws"), do: :ws
  defp circuit_scope("broad"), do: :broad
  defp circuit_scope("intent"), do: :intent

  for value <- [
        :replay_safe,
        :raw_transaction_broadcast,
        :upstream_signed,
        :filter_create,
        :filter_affine_read,
        :filter_affine_consume,
        :filter_affine_uninstall,
        :subscription,
        :unknown
      ] do
    defp safety(unquote(Atom.to_string(value))), do: unquote(value)
  end

  for {name, values} <- [
        admission_reason: [
          :deadline,
          :candidate_budget_exhausted,
          :dispatch_budget_exhausted,
          :duplicate_dispatch,
          :circuit_open,
          :admission_unavailable,
          :local_capacity,
          :policy,
          :unsupported_transport,
          :invalid_request,
          :caller_abandoned
        ],
        predispatch_reason: [
          :encode,
          :request_build,
          :pool_unavailable,
          :not_connected,
          :invalid_frame,
          :local
        ],
        response_kind: [:success, :application_error],
        response_category: [:deterministic, :quota, :capability, :provider_failure],
        invalid_response_reason: [
          :invalid_json,
          :invalid_envelope,
          :unsupported_version,
          :id_mismatch,
          :unexpected_notification,
          :unexpected_batch
        ],
        transport_reason: [
          :connection,
          :closed,
          :timeout,
          :protocol,
          :tls,
          :dns,
          :local_capacity,
          :unknown
        ],
        cancellation_reason: [:caller_abandoned, :socket_closed, :owner_shutdown, :superseded],
        local_reason: [
          :invalid_request,
          :unsupported_method,
          :configuration,
          :capacity,
          :internal
        ],
        exhaustion_reason: [
          :providers_exhausted,
          :candidate_budget_exhausted,
          :dispatch_budget_exhausted,
          :admission_unavailable
        ],
        late_kind: [
          :send_started,
          :send_confirmed,
          :not_dispatched,
          :response,
          :invalid_response,
          :transport_failure,
          :predispatch_failure,
          :cancelled,
          :task_exit
        ]
      ],
      value <- values do
    defp unquote(name)(unquote(Atom.to_string(value))), do: unquote(value)
  end
end
