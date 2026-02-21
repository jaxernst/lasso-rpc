defmodule Lasso.RPC.RequestOptions do
  @moduledoc """
  Canonical, typed options for executing a JSON-RPC request through the pipeline.

  This replaces ad-hoc keyword lists with an explicit struct to improve clarity,
  type-safety, and future extensibility.
  """

  alias Lasso.Config.MethodConstraints

  @type strategy :: :fastest | :priority | :load_balanced | :latency_weighted
  @type transport :: :http | :ws | :both | nil

  @enforce_keys [:timeout_ms]
  defstruct profile: "default",
            account_id: nil,
            strategy: :load_balanced,
            provider_override: nil,
            transport: nil,
            failover_on_override: false,
            timeout_ms: 30_000,
            request_id: nil,
            request_context: nil,
            # Plug-level start time for accurate E2E measurement (microseconds)
            plug_start_time: nil

  @type t :: %__MODULE__{
          profile: String.t(),
          account_id: String.t() | nil,
          strategy: strategy,
          provider_override: String.t() | nil,
          transport: transport,
          failover_on_override: boolean,
          timeout_ms: non_neg_integer,
          request_id: String.t() | nil,
          request_context: any() | nil,
          plug_start_time: integer() | nil
        }

  @doc """
  Validate RequestOptions for a given method.

  Returns `:ok` if valid, or `{:error, reason}` if validation fails.

  Validates:
  - Strategy is a known strategy atom
  - Transport requirements for method (e.g., WS-only methods can't use HTTP)
  - timeout_ms is positive
  """
  @spec validate(t, String.t()) :: :ok | {:error, String.t()}
  def validate(%__MODULE__{} = opts, method) when is_binary(method) do
    with :ok <- validate_strategy(opts.strategy),
         :ok <- validate_transport(opts, method) do
      validate_timeout(opts.timeout_ms)
    end
  end

  defp validate_strategy(strategy)
       when strategy in [:fastest, :priority, :load_balanced, :round_robin, :latency_weighted],
       do: :ok

  defp validate_strategy(strategy),
    do:
      {:error,
       "Invalid strategy: #{inspect(strategy)}. Must be one of: :fastest, :priority, :load_balanced, :latency_weighted"}

  defp validate_transport(%__MODULE__{transport: transport}, method) do
    required = MethodConstraints.required_transport_for(method)

    cond do
      is_nil(required) ->
        :ok

      required == :ws and transport == :http ->
        {:error, "Method #{method} requires WebSocket transport, but HTTP was specified"}

      true ->
        :ok
    end
  end

  defp validate_timeout(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0, do: :ok

  defp validate_timeout(timeout_ms),
    do: {:error, "timeout_ms must be a positive integer, got: #{inspect(timeout_ms)}"}

  @doc """
  Convert to legacy keyword options for backward compatibility.

  Note: This function is provided for backward compatibility only.
  The pipeline now uses the struct directly via normalize_opts/1.
  """
  @spec to_keyword(t) :: keyword()
  def to_keyword(%__MODULE__{} = o) do
    [
      strategy: o.strategy,
      provider_override: o.provider_override,
      transport: o.transport,
      failover_on_override: o.failover_on_override,
      timeout_ms: o.timeout_ms,
      request_id: o.request_id,
      request_context: o.request_context,
      plug_start_time: o.plug_start_time
    ]
  end
end
