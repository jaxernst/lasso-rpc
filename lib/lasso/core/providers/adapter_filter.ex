defmodule Lasso.RPC.Providers.AdapterFilter do
  @moduledoc """
  Filters provider channels by method-level capability and validates request parameters.

  Method-level filtering builds the candidate list. Parameter validation is deferred
  to the execution path where it fits into failover logic:

  1. Filter channels by method support (this module)
  2. Selection returns ordered method-capable channels
  3. Execution validates params for selected channel before request
  4. If params invalid → failover to next channel
  """

  require Logger
  alias Lasso.Config.MethodConstraints
  alias Lasso.RPC.Channel
  alias Lasso.RPC.ProviderKnowledge
  alias Lasso.RPC.Providers.AdapterHelpers

  @doc """
  Filters channels to only those whose providers support the method.

  Returns `{:ok, capable, filtered}` where:
  - `capable` is the list of channels that support the method
  - `filtered` is the list of channels that were filtered out (method unsupported)
  """
  @spec filter_channels([Channel.t()], String.t()) ::
          {:ok, capable :: [Channel.t()], filtered :: [Channel.t()]} | {:error, term()}
  def filter_channels(channels, method) when is_list(channels) and is_binary(method) do
    :telemetry.span([:lasso, :capabilities, :filter], %{method: method}, fn ->
      result = do_filter_channels(channels, method)

      metadata = %{
        method: method,
        total_candidates: length(channels),
        filtered_count:
          case result do
            {:ok, _capable, filtered} -> length(filtered)
            _ -> 0
          end
      }

      {result, metadata}
    end)
  end

  @doc """
  Validates parameters for a specific channel.

  This is called during request execution to validate params for the selected channel.
  If validation fails, the execution path should failover to the next channel.

  Returns `:ok` if params are valid, `{:error, reason}` otherwise.
  """
  @spec validate_params(Channel.t(), String.t(), term()) :: :ok | {:error, term()}
  def validate_params(%Channel{} = channel, method, params) do
    safe_validate_params?(channel, method, params)
  end

  @doc false
  @spec method_supported?(Channel.t(), String.t()) :: boolean()
  def method_supported?(%Channel{} = channel, method) when is_binary(method) do
    not MethodConstraints.disallowed?(method) and provider_supports_method?(channel, method)
  end

  # Private Implementation

  defp do_filter_channels(channels, method) do
    if MethodConstraints.disallowed?(method) do
      {:ok, [], channels}
    else
      filter_by_provider_capabilities(channels, method)
    end
  end

  defp filter_by_provider_capabilities(channels, method) do
    {capable, filtered} = Enum.split_with(channels, &method_supported?(&1, method))

    apply_safety_check(capable, filtered, channels, method)
  end

  defp provider_supports_method?(%Channel{provider_id: id} = channel, method) do
    caps = lookup_capabilities(channel)

    try do
      scope = ProviderKnowledge.capability_scope(channel, caps, method)
      not ProviderKnowledge.method_refused?(scope, method)
    rescue
      error ->
        Logger.error("Capabilities crash in supports_method?: #{id}, #{Exception.message(error)}")

        :telemetry.execute([:lasso, :capabilities, :crash], %{count: 1}, %{
          provider_id: id,
          phase: :method_filter,
          exception: Exception.format(:error, error, __STACKTRACE__)
        })

        true
    end
  end

  defp safe_validate_params?(
         %Channel{provider_id: provider_id, profile: profile, chain_id: chain_id} = channel,
         method,
         params
       ) do
    ctx = %{provider_id: provider_id, profile: profile, chain_id: chain_id}
    caps = lookup_capabilities(channel)
    scope = ProviderKnowledge.capability_scope(channel, caps, method)

    validate_knowledge_limits(method, params, scope, ctx)
    |> handle_validation_result(provider_id, method)
  rescue
    e in [RuntimeError, ArgumentError, FunctionClauseError, MatchError, KeyError] ->
      Logger.error(
        "Capabilities crash in validate_params: #{provider_id}, #{Exception.message(e)}, stacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}"
      )

      :telemetry.execute([:lasso, :capabilities, :crash], %{count: 1}, %{
        provider_id: provider_id,
        phase: :param_validation,
        exception: Exception.format(:error, e, __STACKTRACE__)
      })

      {:error, :adapter_crash}
  end

  defp lookup_capabilities(%Channel{provider_capabilities: capabilities})
       when capabilities != :unbound,
       do: capabilities

  defp lookup_capabilities(%Channel{
         profile: profile,
         chain_id: chain_id,
         provider_id: provider_id
       })
       when is_binary(profile) and is_integer(chain_id) and chain_id > 0 and
              is_binary(provider_id) do
    case Lasso.Config.ConfigStore.get_provider(profile, chain_id, provider_id) do
      {:ok, provider_config} -> provider_config.capabilities
      _ -> nil
    end
  end

  defp lookup_capabilities(%Channel{}), do: nil

  defp validate_knowledge_limits(method, params, scope, ctx) do
    with :ok <- validate_span_limit(method, params, scope, ctx) do
      validate_historical_depth(method, params, scope, ctx)
    end
  end

  defp validate_span_limit("eth_getLogs", params, scope, ctx) do
    case ProviderKnowledge.span_limit(scope, :logs) do
      {:ok, %{value: limit}} when is_integer(limit) ->
        AdapterHelpers.validate_block_range(validation_params(params), ctx, limit)

      _ ->
        :ok
    end
  end

  defp validate_span_limit(_method, _params, _scope, _ctx), do: :ok

  defp validate_historical_depth(method, params, scope, ctx) do
    case ProviderKnowledge.historical_depth(scope, :state) do
      {:ok, %{value: limit}} when is_integer(limit) ->
        AdapterHelpers.validate_block_age(method, validation_params(params), ctx, limit)

      _ ->
        :ok
    end
  end

  defp validation_params(params) when is_map(params), do: [params]
  defp validation_params(params), do: params

  defp handle_validation_result(:ok, _provider_id, _method), do: :ok

  defp handle_validation_result({:error, reason} = err, provider_id, method) do
    :telemetry.execute([:lasso, :capabilities, :param_reject], %{count: 1}, %{
      provider_id: provider_id,
      method: method,
      reason: reason
    })

    err
  end

  defp handle_validation_result(other, provider_id, _method) do
    Logger.warning("Invalid validation result for #{provider_id}: #{inspect(other)}")
    :ok
  end

  defp apply_safety_check([], _filtered, [_ | _] = all_channels, method) do
    Logger.warning("No providers support #{method}, allowing all (fail-open)")

    :telemetry.execute([:lasso, :capabilities, :safety_override], %{count: 1}, %{
      reason: :zero_capable,
      method: method
    })

    {:ok, all_channels, []}
  end

  defp apply_safety_check(capable, filtered, _all, _method) do
    {:ok, capable, filtered}
  end
end
