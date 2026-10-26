defmodule Lasso.RPC.ProviderKnowledge.TemplateOutcomeObservation do
  @moduledoc "Bounded request-level template witnesses delivered away from execution."

  alias Lasso.Core.ProjectionDispatcher
  alias Lasso.RPC.{AttemptTerminal, Channel, MethodRegistry, RequestAnalysis}
  alias Lasso.RPC.Learning.Subject
  alias Lasso.RPC.ProviderKnowledge.TemplateObservation

  @dispatcher Lasso.ExecutionProjectionDispatcher
  @version 3
  @max_payload_bytes 4_096
  @max_attempts 16
  @methods Map.new(MethodRegistry.all_methods(), &{&1, true})

  @spec lane_options() :: keyword()
  def lane_options do
    [
      capacity: 512,
      byte_capacity: 512 * @max_payload_bytes,
      scope_capacity: 32,
      scope_byte_capacity: 32 * @max_payload_bytes,
      shards: 1,
      max_payload_bytes: @max_payload_bytes,
      max_age_ms: 60_000,
      audit_interval_ms: 1_000,
      sink: &__MODULE__.deliver/2
    ]
  end

  @spec capture(
          map(),
          Channel.t(),
          term(),
          map() | nil,
          map(),
          {non_neg_integer(), integer()} | nil
        ) :: map()
  def capture(
        %{template_attempts: attempts} = ctx,
        %Channel{learning_subject: %Subject{id: subject}, instance_id: instance_id} = channel,
        %AttemptTerminal.Response{kind: :application_error, error_code: code},
        %{fingerprint: fingerprint},
        projection,
        {epoch, dispatched_at_ms}
      )
      when is_integer(code) and is_binary(fingerprint) and is_binary(instance_id) and
             is_integer(epoch) and epoch >= 0 and is_integer(dispatched_at_ms) and
             length(attempts) < @max_attempts do
    if TemplateObservation.enabled?(channel.profile) do
      attempt = %{
        profile: channel.profile,
        subject: subject,
        instance_id: instance_id,
        epoch: epoch,
        sharing_scope: channel.learning_subject.sharing_scope,
        dispatch_index: ctx.execution_envelope.dispatch_count,
        shadow_eligible:
          projection.fallback_eligible and projection.diagnostic == :ambiguous_application_error,
        error_code: code,
        fingerprint: fingerprint
      }

      %{ctx | template_attempts: [attempt | attempts]}
    else
      ctx
    end
  end

  def capture(ctx, _channel, _fact, _prepared, _projection, _dispatch), do: ctx

  @spec record(:ok | :error, map()) :: term()
  def record(_status, %{template_attempts: []}), do: :not_dispatched

  def record(status, ctx) when status in [:ok, :error] do
    record(status, ctx, enabled_attempts(ctx.template_attempts))
  end

  defp record(_status, _ctx, []), do: :not_dispatched

  defp record(status, ctx, attempts) do
    packet = %{
      nonce: request_nonce(ctx),
      chain_id: ctx.chain_id,
      method: method(ctx.method),
      shape: shape(ctx.method, ctx.params),
      completion: completion(status, ctx),
      dispatch_count: ctx.execution_envelope.dispatch_count,
      attempts: Enum.reverse(attempts),
      observed_at_ms: System.system_time(:millisecond)
    }

    ProjectionDispatcher.enqueue_lazy(
      @dispatcher,
      :provider_outcomes,
      {hd(packet.attempts).profile, ctx.chain_id},
      fn -> encode(packet) end
    )
  end

  @spec encode(map()) :: {:ok, binary()} | {:error, :invalid | :too_large}
  def encode(packet) do
    if valid?(packet) do
      payload = :erlang.term_to_binary({@version, packet})
      if byte_size(payload) <= @max_payload_bytes, do: {:ok, payload}, else: {:error, :too_large}
    else
      {:error, :invalid}
    end
  end

  @spec decode(binary()) :: {:ok, map()} | {:error, :invalid | :too_large}
  def decode(payload) when is_binary(payload) and byte_size(payload) <= @max_payload_bytes do
    case :erlang.binary_to_term(payload, [:safe]) do
      {@version, packet} -> if(valid?(packet), do: {:ok, packet}, else: {:error, :invalid})
      _ -> {:error, :invalid}
    end
  rescue
    _ -> {:error, :invalid}
  end

  def decode(_), do: {:error, :too_large}

  @spec deliver(term(), binary()) :: :ok
  def deliver(_scope, payload) do
    case decode(payload) do
      {:ok, packet} ->
        deliver_packet(packet, enabled_attempts(packet.attempts))

      _ ->
        raise "invalid template outcome witness payload"
    end
  end

  defp enabled_attempts(attempts),
    do: Enum.filter(attempts, &TemplateObservation.enabled?(&1.profile))

  defp deliver_packet(_packet, []), do: :ok

  defp deliver_packet(packet, attempts) do
    case adapter().observe(%{packet | attempts: attempts}) do
      :ok -> :ok
      {:error, :stale_epoch} -> :ok
      _ -> raise "template outcome witness delivery failed"
    end
  end

  defp adapter,
    do: Application.get_env(:lasso, :provider_knowledge_template_outcomes, __MODULE__.None)

  defp request_nonce(ctx) do
    :crypto.hash(:sha256, ctx.execution_envelope.execution_nonce)
    |> Base.url_encode64(padding: false)
  end

  defp method(value) when is_binary(value),
    do: if(Map.has_key?(@methods, value), do: value, else: "other")

  defp method(_), do: "other"

  defp shape("eth_getLogs", params) do
    case RequestAnalysis.analyze("eth_getLogs", params).block_range do
      span when is_integer(span) and span > 0 -> "logs_span"
      _ -> "logs_other"
    end
  end

  defp shape(_method, _params), do: "other"

  defp valid?(
         %{
           nonce: nonce,
           chain_id: chain_id,
           method: method,
           shape: shape,
           completion: completion,
           dispatch_count: dispatch_count,
           attempts: attempts,
           observed_at_ms: at_ms
         } = packet
       ) do
    map_size(packet) == 8 and is_binary(nonce) and
      String.match?(nonce, ~r/\A[A-Za-z0-9_-]{43}\z/) and is_integer(chain_id) and
      chain_id > 0 and is_binary(method) and
      (method == "other" or Map.has_key?(@methods, method)) and
      shape in ["logs_span", "logs_other", "other"] and
      completion in [:success, :exhausted, :incomplete] and
      is_integer(dispatch_count) and dispatch_count in 1..16 and
      is_integer(at_ms) and at_ms > 0 and is_list(attempts) and
      length(attempts) in 1..@max_attempts and
      Enum.all?(attempts, &(valid_attempt?(&1) and &1.dispatch_index <= dispatch_count))
  end

  defp valid?(_), do: false

  defp valid_attempt?(
         %{
           profile: profile,
           subject: subject,
           instance_id: instance_id,
           epoch: epoch,
           sharing_scope: sharing_scope,
           dispatch_index: dispatch_index,
           shadow_eligible: shadow_eligible,
           error_code: code,
           fingerprint: fingerprint
         } = attempt
       ) do
    map_size(attempt) == 9 and is_binary(profile) and byte_size(profile) in 1..128 and
      is_binary(subject) and byte_size(subject) in 1..128 and is_binary(instance_id) and
      byte_size(instance_id) in 1..128 and is_integer(epoch) and epoch >= 0 and
      valid_scope?(sharing_scope) and is_integer(dispatch_index) and dispatch_index in 1..16 and
      is_boolean(shadow_eligible) and
      is_integer(code) and
      code in -2_147_483_648..2_147_483_647 and is_binary(fingerprint) and
      String.match?(fingerprint, ~r/\A[A-Za-z0-9_-]{43}\z/)
  end

  defp valid_attempt?(_), do: false

  defp valid_scope?(:curated), do: true
  defp valid_scope?({:account, id}), do: is_binary(id) and byte_size(id) in 1..128
  defp valid_scope?({:profile, id}), do: is_binary(id) and byte_size(id) in 1..128
  defp valid_scope?(_), do: false

  defp completion(:ok, _ctx), do: :success

  defp completion(:error, %{terminal_reason: reason})
       when reason in [:providers_exhausted, :no_candidates],
       do: :exhausted

  defp completion(:error, _ctx), do: :incomplete
end

defmodule Lasso.RPC.ProviderKnowledge.TemplateOutcomeObservation.None do
  @moduledoc "Local template outcome delivery without an external adapter."

  @spec observe(map()) :: :ok
  def observe(_packet), do: :ok
end
