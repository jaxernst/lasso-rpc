defmodule Lasso.RPC.Providers.AdapterFilter do
  @moduledoc """
  Filters provider channels by method-level capability only.

  ## Design Philosophy

  This module performs **only method-level filtering** to build a candidate list.
  Parameter validation is deferred to the execution path where it naturally fits
  into the failover logic:

  1. Filter channels by method support (this module)
  2. Selection returns ordered method-capable channels
  3. Execution validates params for selected channel before request
  4. If params invalid/not supported by provider → failover to next channel
  5. Repeat until success or exhausted

  ## Benefits of Lazy Parameter Validation

  - **Efficiency**: Only 1 parameter validation per request (not N validations)
  - **Natural failover**: Invalid params trigger same failover as request errors
  - **Separation of concerns**: Filter = capability, execution = validation

  ## Crash Safety vs. Fail Fast

  The module takes a balanced approach to error handling:

  - **supports_method?**: Called directly without try/rescue. This is a required
    callback that should never crash. If it does, that's a critical bug that
    needs immediate attention, not silent degradation.

  - **validate_params**: Wrapped in try/rescue during execution phase. This
    callback may deal with complex parameter parsing and we prefer degraded
    service (failover) over complete failure during request handling.

  ## Performance

  Target: <20μs P99 filtering overhead (method checks only, no param parsing)
  - Method check: ~2μs per provider
  - 6 providers: ~13μs total
  """

  require Logger
  alias Lasso.RPC.Providers.AdapterRegistry
  alias Lasso.RPC.Channel

  @doc """
  Filters channels to only those whose adapters support the method.

  Returns `{:ok, capable, filtered}` where:
  - `capable` is the list of channels that support the method
  - `filtered` is the list of channels that were filtered out (method unsupported)

  Returns `{:error, reason}` if filtering failed.

  ## Examples

      iex> channels = [channel1, channel2, channel3]
      iex> AdapterFilter.filter_channels(channels, "eth_getLogs")
      {:ok, [channel1, channel2], [channel3]}
  """
  @spec filter_channels([Channel.t()], String.t()) ::
          {:ok, capable :: [Channel.t()], filtered :: [Channel.t()]} | {:error, term()}
  def filter_channels(channels, method) when is_list(channels) and is_binary(method) do
    # Performance: Use telemetry span for automatic timing
    :telemetry.span([:lasso, :capabilities, :filter], %{method: method}, fn ->
      result = do_filter_channels(channels, method)

      metadata = %{
        method: method,
        total_candidates: length(channels),
        filtered_count:
          case result do
            {:ok, _capable, filtered} -> length(filtered)
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

  ## Examples

      iex> AdapterFilter.validate_params(channel, "eth_getLogs", [%{"address" => [...]}])
      :ok
  """
  @spec validate_params(Channel.t(), String.t(), term()) :: :ok | {:error, term()}
  def validate_params(%Channel{} = channel, method, params) do
    safe_validate_params?(channel.provider_id, method, params, channel.transport)
  end

  # Private Implementation

  defp do_filter_channels(channels, method) do
    {capable, filtered} =
      Enum.split_with(channels, fn %{provider_id: id, transport: t} ->
        adapter = AdapterRegistry.adapter_for(id)
        :ok == adapter.supports_method?(method, t, %{provider_id: id})
      end)

    apply_safety_check(capable, filtered, channels, method)
  end

  # Crash-safe wrapper for validate_params (called during execution)
  defp safe_validate_params?(provider_id, method, params, transport) do
    adapter = AdapterRegistry.adapter_for(provider_id)
    ctx = %{provider_id: provider_id}

    try do
      adapter.validate_params(method, params, transport, ctx)
      |> handle_validation_result(adapter, provider_id, method)
    rescue
      e ->
        Logger.error(
          "Adapter crash in validate_params: #{inspect(adapter)}, #{Exception.message(e)}"
        )

        :telemetry.execute([:lasso, :capabilities, :crash], %{count: 1}, %{
          adapter: adapter,
          provider_id: provider_id,
          phase: :param_validation
        })

        :ok
    end
  end

  defp handle_validation_result(:ok, _adapter, _provider_id, _method), do: :ok

  defp handle_validation_result({:error, reason} = err, adapter, provider_id, method) do
    :telemetry.execute([:lasso, :capabilities, :param_reject], %{count: 1}, %{
      adapter: adapter,
      provider_id: provider_id,
      method: method,
      reason: reason
    })

    err
  end

  defp handle_validation_result(other, adapter, _provider_id, _method) do
    Logger.warning("Invalid validation result from #{inspect(adapter)}: #{inspect(other)}")
    :ok
  end

  # Safety check: Fail open if all providers filtered
  defp apply_safety_check([], _filtered, all_channels, method) when length(all_channels) > 0 do
    Logger.warning("No providers support #{method}, allowing all (fail-open)")

    :telemetry.execute([:lasso, :capabilities, :safety_override], %{count: 1}, %{
      reason: :zero_capable,
      method: method
    })

    {:ok, all_channels, []}
  end

  defp apply_safety_check(capable, filtered, _all, method) do
    if filtered != [], do: log_filtered(filtered, method)
    {:ok, capable, filtered}
  end

  defp log_filtered(filtered, method) do
    providers = Enum.map_join(filtered, ", ", & &1.provider_id)
    Logger.info("Filtered #{length(filtered)} providers for #{method}: #{providers}")
  end
end
