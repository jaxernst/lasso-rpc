defmodule Lasso.RPC.RequestOptions do
  @moduledoc """
  Canonical, typed options for executing a JSON-RPC request through the pipeline.

  This replaces ad-hoc keyword lists with an explicit struct to improve clarity,
  type-safety, and future extensibility.
  """

  alias Lasso.Config.MethodConstraints

  @type strategy :: :fastest | :priority | :load_balanced | :balanced_fast
  @type transport :: :http | :ws | :both | nil
  @type request_origin :: :client | :system
  @type ingress_transport :: :http | :ws | :unavailable | :not_applicable

  @default_profile Lasso.Config.ProfileValidator.default_profile()

  @enforce_keys [:timeout_ms]
  defstruct profile: @default_profile,
            requested_profile: nil,
            account_id: nil,
            strategy: :load_balanced,
            provider_override: nil,
            # Internal owned backfill: borrow this captured route without reselection.
            captured_channel: nil,
            transport: nil,
            # Actual ingress, independent of the upstream transport preference.
            ingress_transport: :unavailable,
            failover_on_override: false,
            timeout_ms: 30_000,
            request_id: nil,
            jsonrpc_id: nil,
            jsonrpc_id_present?: false,
            request_origin: :client,
            observation_activity: nil,
            capability_revalidation: nil,
            request_context: nil,
            # Plug-level start time for accurate E2E measurement (microseconds)
            plug_start_time: nil

  @type t :: %__MODULE__{
          profile: String.t(),
          requested_profile: String.t() | nil,
          account_id: String.t() | nil,
          strategy: strategy,
          provider_override: String.t() | nil,
          captured_channel: Lasso.RPC.Channel.t() | {:unavailable, map()} | nil,
          transport: transport,
          ingress_transport: ingress_transport(),
          failover_on_override: boolean,
          timeout_ms: non_neg_integer,
          request_id: String.t() | nil,
          jsonrpc_id: number() | String.t() | nil,
          jsonrpc_id_present?: boolean(),
          request_origin: request_origin(),
          observation_activity:
            :head | :diagnostic_head | :diagnostic_identity | :revalidation | nil,
          capability_revalidation: Lasso.RPC.ProviderKnowledge.Revalidation.t() | nil,
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
         :ok <- validate_transport(opts, method),
         :ok <- validate_timeout(opts.timeout_ms),
         :ok <- validate_jsonrpc_id_presence(opts.jsonrpc_id_present?),
         :ok <- validate_observation_activity(opts.observation_activity, opts.request_origin),
         :ok <- validate_revalidation(opts) do
      validate_request_origin(opts.request_origin)
    end
  end

  defp validate_strategy(strategy)
       when strategy in [:fastest, :priority, :load_balanced, :balanced_fast],
       do: :ok

  defp validate_strategy(strategy),
    do:
      {:error,
       "Invalid strategy: #{inspect(strategy)}. Must be one of: :fastest, :priority, :load_balanced, :balanced_fast"}

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

  defp validate_jsonrpc_id_presence(value) when is_boolean(value), do: :ok

  defp validate_jsonrpc_id_presence(value),
    do: {:error, "jsonrpc_id_present? must be a boolean, got: #{inspect(value)}"}

  defp validate_request_origin(value) when value in [:client, :system], do: :ok

  defp validate_request_origin(value),
    do: {:error, "request_origin must be :client or :system, got: #{inspect(value)}"}

  defp validate_observation_activity(nil, _origin), do: :ok

  defp validate_observation_activity(activity, :system)
       when activity in [:head, :diagnostic_head, :diagnostic_identity, :revalidation],
       do: :ok

  defp validate_observation_activity(_, _), do: {:error, "Invalid observation activity"}

  defp validate_revalidation(%{capability_revalidation: nil}), do: :ok

  defp validate_revalidation(%{
         capability_revalidation: token,
         request_origin: :system,
         observation_activity: :revalidation,
         provider_override: provider,
         failover_on_override: false
       })
       when is_binary(provider) do
    if Lasso.RPC.ProviderKnowledge.Revalidation.valid?(token),
      do: :ok,
      else: {:error, "Invalid capability revalidation"}
  end

  defp validate_revalidation(_), do: {:error, "Invalid capability revalidation"}

  @doc """
  Convert to legacy keyword options for backward compatibility.

  Note: This function is provided for backward compatibility only.
  The pipeline now uses the struct directly via normalize_opts/1.
  """
  @spec to_keyword(t) :: keyword()
  def to_keyword(%__MODULE__{} = o) do
    [
      strategy: o.strategy,
      profile: o.profile,
      requested_profile: o.requested_profile,
      provider_override: o.provider_override,
      transport: o.transport,
      ingress_transport: o.ingress_transport,
      failover_on_override: o.failover_on_override,
      timeout_ms: o.timeout_ms,
      request_id: o.request_id,
      jsonrpc_id: o.jsonrpc_id,
      jsonrpc_id_present?: o.jsonrpc_id_present?,
      request_origin: o.request_origin,
      observation_activity: o.observation_activity,
      capability_revalidation: o.capability_revalidation,
      request_context: o.request_context,
      plug_start_time: o.plug_start_time
    ]
  end
end
