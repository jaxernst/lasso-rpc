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
  alias Lasso.RPC.MethodRegistry
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
    do_filter_channels(channels, method)
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
      channel.chain_id,
      provider_capabilities(channel)
    )
  end

  @doc false
  @spec method_supported?(Channel.t(), String.t()) :: boolean()
  def method_supported?(%Channel{provider_id: provider_id} = channel, method)
      when is_binary(method) do
    category = MethodRegistry.method_category(method)

    try do
      :ok == Capabilities.supports_method?(method, category, provider_capabilities(channel))
    rescue
      error ->
        Logger.error(
          "Capabilities crash in supports_method?: #{provider_id}, #{Exception.message(error)}"
        )

        true
    end
  end

  # Private Implementation

  defp do_filter_channels(channels, method) do
    {capable, filtered} =
      Enum.split_with(channels, &method_supported?(&1, method))

    apply_safety_check(capable, filtered, channels, method)
  end

  defp safe_validate_params?(provider_id, method, params, profile, chain_id, caps) do
    ctx = %{provider_id: provider_id, profile: profile, chain_id: chain_id}

    Capabilities.validate_params(method, params, caps, ctx)
    |> handle_validation_result(provider_id, method)
  rescue
    e in [RuntimeError, ArgumentError, FunctionClauseError, MatchError, KeyError] ->
      Logger.error(
        "Capabilities crash in validate_params: #{provider_id}, #{Exception.message(e)}, stacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}"
      )

      {:error, :adapter_crash}
  end

  defp provider_capabilities(%Channel{provider_capabilities: :unbound} = channel) do
    case Lasso.Config.ConfigStore.get_provider(
           channel.profile,
           channel.chain_id,
           channel.provider_id
         ) do
      {:ok, provider_config} -> provider_config.capabilities
      _other -> nil
    end
  end

  defp provider_capabilities(%Channel{provider_capabilities: capabilities}), do: capabilities

  defp handle_validation_result(:ok, _provider_id, _method), do: :ok

  defp handle_validation_result({:error, _reason} = error, _provider_id, _method), do: error

  defp handle_validation_result(other, provider_id, _method) do
    Logger.warning("Invalid validation result for #{provider_id}: #{inspect(other)}")
    :ok
  end

  defp apply_safety_check([], _filtered, [_ | _] = all_channels, method) do
    Logger.warning("No providers support #{method}, allowing all (fail-open)")

    {:ok, all_channels, []}
  end

  defp apply_safety_check(capable, filtered, _all, _method) do
    {:ok, capable, filtered}
  end
end
