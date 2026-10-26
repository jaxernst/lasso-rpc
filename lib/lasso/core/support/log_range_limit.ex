defmodule Lasso.Core.Support.LogRangeLimit do
  @moduledoc """
  Converts `eth_getLogs` range and result limits into one client action.

  Provider wording and local response envelopes vary. An upstream's own limit
  differs between upstreams, so the pipeline tries the remaining candidates first
  and returns this error, whose action is to reduce the block range, only when
  none of them served the request. Lasso's local response cap applies to every
  upstream alike, so it is returned at once.
  """

  alias Lasso.Core.Support.ErrorClassification
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
  @argument_validation_patterns [
    "invalid argument",
    "cannot unmarshal",
    "unable to decode",
    "invalid hex",
    "odd length hex",
    "hex string without 0x prefix",
    "invalid address",
    "wrong number of arguments",
    "missing value for required argument",
    "abi: cannot marshal"
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

  @doc "Whether a translated limit belongs to the upstream rather than to Lasso's response cap."
  @spec upstream_limit?(term(), keyword()) :: boolean()
  def upstream_limit?(reason, opts \\ []),
    do: not local_response_too_large?(JError.from(reason, opts))

  defp local_response_too_large?(%JError{category: :local_capacity_rejection, data: data})
       when is_map(data) do
    Map.get(data, :reason) == :response_too_large or
      Map.get(data, "reason") == "response_too_large"
  end

  defp local_response_too_large?(_error), do: false

  defp provider_range_limit?(%JError{category: category, message: message} = error)
       when category in @provider_categories and is_binary(message) do
    bounded_message = message |> String.slice(0, 4_096) |> String.downcase()

    not ErrorClassification.invalid_request_plan_restriction?(error.code, message, error.data) and
      not Enum.any?(@argument_validation_patterns, &String.contains?(bounded_message, &1)) and
      Enum.any?(@patterns, &String.contains?(bounded_message, &1))
  end

  defp provider_range_limit?(_error), do: false
end
