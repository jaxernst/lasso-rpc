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
  alias Lasso.RPC.Channel
  alias Lasso.RPC.Providers.Capabilities

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
    safe_validate_params?(
      channel.provider_id,
      method,
      params,
      channel.profile,
      channel.chain
    )
  end

  # Private Implementation

  defp do_filter_channels(channels, method) do
    {capable, filtered} =
      Enum.split_with(channels, fn %{provider_id: id, profile: profile, chain: chain} ->
        caps = lookup_capabilities(profile, chain, id)

        try do
          :ok == Capabilities.supports_method?(method, caps)
        rescue
          e ->
            Logger.error("Capabilities crash in supports_method?: #{id}, #{Exception.message(e)}")

            :telemetry.execute([:lasso, :capabilities, :crash], %{count: 1}, %{
              provider_id: id,
              phase: :method_filter,
              exception: Exception.format(:error, e, __STACKTRACE__)
            })

            true
        end
      end)

    apply_safety_check(capable, filtered, channels, method)
  end

  defp safe_validate_params?(provider_id, method, params, profile, chain) do
    ctx = %{provider_id: provider_id, profile: profile, chain: chain}
    caps = lookup_capabilities(profile, chain, provider_id)

    try do
      Capabilities.validate_params(method, params, caps, ctx)
      |> handle_validation_result(provider_id, method)
    rescue
      e ->
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
  end

  defp lookup_capabilities(profile, chain, provider_id)
       when is_binary(profile) and is_binary(chain) and is_binary(provider_id) do
    case Lasso.Config.ConfigStore.get_provider(profile, chain, provider_id) do
      {:ok, provider_config} -> provider_config.capabilities
      _ -> nil
    end
  end

  defp lookup_capabilities(_profile, _chain, _provider_id), do: nil

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
