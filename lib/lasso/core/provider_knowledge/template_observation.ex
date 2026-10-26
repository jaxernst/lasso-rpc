defmodule Lasso.RPC.ProviderKnowledge.TemplateObservation do
  @moduledoc "Transient, bounded delivery of masked templates to the off-path interpreter."

  alias Lasso.Core.ProjectionDispatcher
  alias Lasso.RPC.{AttemptTerminal, Channel, MethodRegistry, RequestAnalysis}
  alias Lasso.RPC.Learning.Subject
  alias Lasso.RPC.ProviderKnowledge.{Effects, Template}

  @dispatcher Lasso.ExecutionProjectionDispatcher
  @version 2
  @max_payload_bytes 10_240
  @methods Map.new(MethodRegistry.all_methods(), &{&1, true})

  @doc "Capture serves enabled profile effects or the independent evaluation sample."
  @spec enabled?(String.t()) :: boolean()
  def enabled?(profile) do
    Application.get_env(:lasso, :provider_knowledge_eval_sample_enabled, false) == true or
      Effects.classifier_mode(profile) != :off or Effects.request_fault_mode(profile) != :off
  end

  @spec lane_options() :: keyword()
  def lane_options do
    [
      capacity: 128,
      byte_capacity: 128 * @max_payload_bytes,
      scope_capacity: 16,
      scope_byte_capacity: 16 * @max_payload_bytes,
      shards: 1,
      max_payload_bytes: @max_payload_bytes,
      max_age_ms: 60_000,
      audit_interval_ms: 1_000,
      sink: &__MODULE__.deliver/2
    ]
  end

  @spec record(Channel.t(), map(), map(), map() | nil) :: term()
  def record(
        %Channel{learning_subject: %Subject{} = subject} = channel,
        ctx,
        %{
          fact: %AttemptTerminal.Response{kind: :application_error, error_code: code} = fact,
          result: result
        },
        %{template: template, fingerprint: fingerprint, quantity_slots: slots}
      )
      when is_integer(code) do
    if enabled?(channel.profile) do
      packet = %{
        error_code: code,
        fingerprint: fingerprint,
        template: template,
        quantity_slots: slots,
        profile: channel.profile,
        sharing_scope: subject.sharing_scope,
        method: method(ctx.method),
        shape: shape(ctx.method, ctx.params),
        http_status: http_status(result),
        retry_after_ms: fact.retry_after_ms
      }

      ProjectionDispatcher.enqueue_lazy(
        @dispatcher,
        :provider_messages,
        {channel.profile, channel.chain_id},
        fn -> encode(packet) end
      )
    else
      :not_dispatched
    end
  end

  def record(_channel, _ctx, _outcome, _prepared), do: :not_dispatched

  @spec encode(map()) :: {:ok, binary()} | {:error, :invalid | :too_large}
  def encode(packet) when is_map(packet) do
    if valid?(packet) do
      payload = :erlang.term_to_binary({@version, packet})
      if byte_size(payload) <= @max_payload_bytes, do: {:ok, payload}, else: {:error, :too_large}
    else
      {:error, :invalid}
    end
  end

  def encode(_packet), do: {:error, :invalid}

  @spec decode(binary()) :: {:ok, map()} | {:error, :invalid | :too_large}
  def decode(payload) when is_binary(payload) and byte_size(payload) <= @max_payload_bytes do
    case :erlang.binary_to_term(payload, [:safe]) do
      {@version, packet} -> if(valid?(packet), do: {:ok, packet}, else: {:error, :invalid})
      _ -> {:error, :invalid}
    end
  rescue
    _ -> {:error, :invalid}
  end

  def decode(_payload), do: {:error, :too_large}

  @spec deliver(term(), binary()) :: :ok
  def deliver(_scope, payload) do
    with {:ok, packet} <- decode(payload) do
      adapter().observe(packet)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp adapter,
    do: Application.get_env(:lasso, :provider_knowledge_template_observer, __MODULE__.None)

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

  defp http_status({:error, %{http_status: status}}) when is_integer(status), do: status
  defp http_status({:error, %{http_status: status}, _elapsed}) when is_integer(status), do: status
  defp http_status(_), do: nil

  defp valid?(
         %{
           error_code: code,
           fingerprint: fingerprint,
           template: template,
           quantity_slots: slots,
           profile: profile,
           sharing_scope: scope,
           method: method,
           shape: shape,
           http_status: status,
           retry_after_ms: retry_after
         } = packet
       ) do
    map_size(packet) == 10 and is_binary(profile) and byte_size(profile) in 1..128 and
      valid_identity?(code, fingerprint, template) and
      valid_slots?(slots) and valid_scope?(scope) and
      valid_context?(method, shape, status, retry_after)
  end

  defp valid?(_), do: false

  defp valid_identity?(code, fingerprint, template) do
    is_integer(code) and code in -2_147_483_648..2_147_483_647 and
      is_binary(fingerprint) and String.match?(fingerprint, ~r/\A[A-Za-z0-9_-]{43}\z/) and
      is_binary(template) and byte_size(template) in 1..8_192 and String.valid?(template) and
      safe_template?(template, fingerprint)
  end

  defp valid_context?(method, shape, status, retry_after) do
    is_binary(method) and (method == "other" or Map.has_key?(@methods, method)) and
      shape in ["logs_span", "logs_other", "other"] and
      (is_nil(status) or (is_integer(status) and status in 100..599)) and
      (is_nil(retry_after) or (is_integer(retry_after) and retry_after >= 0))
  end

  defp safe_template?(template, fingerprint) do
    case Template.mask(template) do
      {:ok, %{text: ^template, truncated: false}} ->
        digest = :crypto.hash(:sha256, template) |> Base.url_encode64(padding: false)
        digest == fingerprint

      _ ->
        false
    end
  end

  defp valid_slots?(slots) when is_list(slots) and length(slots) <= 32 do
    Enum.all?(slots, fn
      %{kind: kind, value: value} = slot ->
        map_size(slot) == 2 and kind in [:decimal, :hex_quantity] and is_integer(value) and
          value in 0..9_223_372_036_854_775_807

      _ ->
        false
    end)
  end

  defp valid_slots?(_), do: false

  defp valid_scope?(:curated), do: true
  defp valid_scope?({:account, id}), do: is_binary(id) and byte_size(id) <= 128
  defp valid_scope?({:profile, id}), do: is_binary(id) and byte_size(id) <= 128
  defp valid_scope?(_), do: false
end

defmodule Lasso.RPC.ProviderKnowledge.TemplateObservation.None do
  @moduledoc "Local template delivery without an external interpretation adapter."

  @spec observe(map()) :: :ok
  def observe(_packet), do: :ok
end
