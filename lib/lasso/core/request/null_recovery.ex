defmodule Lasso.RPC.NullRecovery do
  @moduledoc """
  One extra send for a client's missing numeric block, authorized only by
  fresh evidence of N on another physical instance in the current phase scope.
  The original answer and provenance survive an unavailable or failed alternate.
  """

  alias Lasso.JSONRPC.Error
  alias Lasso.RPC.{Channel, ExecutionEnvelope, MissingBlock}
  alias Lasso.RPC.Response.Success
  alias Lasso.RPC.Selection.HeadSuitability

  defmodule State do
    @moduledoc "The original missing answer held while its alternate is sent."

    @enforce_keys [:height, :original, :original_channel, :original_fact]
    defstruct @enforce_keys ++ [:caller_guard]

    @type t :: %__MODULE__{
            height: non_neg_integer(),
            original: Success.t() | Error.t(),
            original_channel: Channel.t(),
            original_fact: term(),
            caller_guard: Lasso.Core.Request.ExecutionScope.CallerGuard.t() | nil
          }
  end

  @return_margin_ms 25
  @minimum_alternate_ms 25

  @doc "Assesses the current scope snapshot without projecting a future height."
  @spec assess(map(), Channel.t(), term(), HeadSuitability.t() | nil) ::
          :ordinary | {:declined, atom()} | {:recover, non_neg_integer(), MapSet.t()}
  def assess(ctx, %Channel{} = channel, result, head) do
    with :client <- ctx.opts.request_origin,
         nil <- ctx.head_policy,
         nil <- ctx.null_recovery,
         height when is_integer(height) <- MissingBlock.height(ctx),
         true <- missing?(ctx, result, head, channel) do
      routes = alternates(head, height, channel)

      if MapSet.size(routes) == 0,
        do: {:declined, :no_fresh_evidence},
        else: {:recover, height, routes}
    else
      _ordinary -> :ordinary
    end
  end

  @doc "The method-specific missing-answer predicate."
  @spec missing?(map(), term(), HeadSuitability.t() | nil, Channel.t()) :: boolean()
  def missing?(ctx, %Success{} = result, head, channel),
    do: MissingBlock.missing?(ctx, {:ok, result}, head, channel)

  def missing?(_ctx, %Error{category: :block_not_available}, _head, _channel), do: true
  def missing?(_ctx, _result, _head, _channel), do: false

  @doc "Whether the held error still owns its response bytes during retry setup."
  @spec holds_original?(map(), term()) :: boolean()
  def holds_original?(%{null_recovery: %State{original: %Error{} = original}}, error),
    do: original == error

  def holds_original?(_ctx, _error), do: false

  # Routes on other physical instances whose fresh observation reached the block.
  defp alternates(%HeadSuitability{evidence: evidence}, height, channel) do
    for {{instance_id, _transport} = route, %{fresh?: true, height: observed}} <- evidence,
        instance_id != channel.instance_id and is_integer(observed) and observed >= height,
        into: MapSet.new(),
        do: route
  end

  defp alternates(_head, _height, _channel), do: MapSet.new()

  @doc "Why an alternate cannot be sent within the request's existing limits, if so."
  @spec denial(ExecutionEnvelope.t()) :: atom() | nil
  def denial(%ExecutionEnvelope{} = envelope) do
    cond do
      envelope.extra_send == :spent ->
        :extra_send_spent

      envelope.dispatch_count >= envelope.dispatch_limit ->
        :dispatch_budget_denied

      ExecutionEnvelope.remaining_ms(envelope) < @minimum_alternate_ms + @return_margin_ms ->
        :deadline_denied

      true ->
        nil
    end
  end

  @doc "Spends the extra send and keeps a return margin inside the request deadline."
  @spec reserve(ExecutionEnvelope.t()) :: ExecutionEnvelope.t()
  def reserve(%ExecutionEnvelope{} = envelope) do
    {:ok, envelope} = ExecutionEnvelope.spend_extra_send(envelope)
    ExecutionEnvelope.cap_deadline(envelope, envelope.deadline_us - @return_margin_ms * 1_000)
  end

  @doc "Reports a recovery decision over the original missing answer."
  @spec decision(map(), atom()) :: :ok
  def decision(ctx, result), do: MissingBlock.decision(ctx, result)
end
