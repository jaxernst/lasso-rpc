defmodule Lasso.Core.Support.LogRangeLimit do
  @moduledoc """
  Converts deterministic `eth_getLogs` range and result limits into one client action.

  Provider wording and local response envelopes vary. A known limit is terminal:
  trying another upstream with the same query spends the request deadline without
  changing the caller's next action, which is to reduce the block range.
  """

  alias Lasso.JSONRPC.Error, as: JError

  @message "eth_getLogs result exceeds a range or size limit; reduce the block range"
  @provider_categories [:capability_violation, :invalid_params, :client_error]
  @patterns [
    "max block range",
    "maximum block range",
    "block range too large",
    "block range exceeded",
    "range too large",
    "range is too large",
    "ranges over",
    "query returned more than",
    "result set too large",
    "result limit exceeded",
    "too many results",
    "too many logs"
  ]

  @spec translate(String.t(), term(), keyword()) :: {:ok, JError.t()} | :not_range_limit
  def translate(method, reason, opts \\ [])

  def translate("eth_getLogs", reason, opts) do
    error = JError.from(reason, opts)

    if local_response_too_large?(error) or provider_range_limit?(error) do
      {:ok,
       JError.new(-32_005, @message,
         data: %{reason: :log_range_too_large, action: :reduce_block_range},
         category: :log_range_limit,
         retriable?: false,
         breaker_penalty?: false,
         provider_id: error.provider_id || Keyword.get(opts, :provider_id),
         source: error.source,
         transport: error.transport || Keyword.get(opts, :transport)
       )}
    else
      :not_range_limit
    end
  end

  def translate(_method, _reason, _opts), do: :not_range_limit

  defp local_response_too_large?(%JError{category: :local_capacity_rejection, data: data})
       when is_map(data) do
    Map.get(data, :reason) == :response_too_large or
      Map.get(data, "reason") == "response_too_large"
  end

  defp local_response_too_large?(_error), do: false

  defp provider_range_limit?(%JError{category: category, message: message})
       when category in @provider_categories and is_binary(message) do
    bounded_message = message |> String.slice(0, 4_096) |> String.downcase()
    Enum.any?(@patterns, &String.contains?(bounded_message, &1))
  end

  defp provider_range_limit?(_error), do: false
end
