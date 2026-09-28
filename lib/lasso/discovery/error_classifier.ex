defmodule Lasso.Discovery.ErrorClassifier do
  @moduledoc """
  Error classification for provider discovery probing.

  Delegates core error classification to `Lasso.Core.Support.ErrorClassification`
  and adds discovery-specific categorization (block range limits, address limits,
  topic complexity, log volume) with extracted metadata.
  """

  alias Lasso.Core.Support.ErrorClassification

  @type error_type ::
          :block_range
          | :address_limit
          | :rate_limit
          | :topic_complexity
          | :log_volume
          | :invalid_params
          | :method_not_found
          | :server_error
          | :unknown

  @spec classify(map()) :: {error_type(), map()}
  def classify(%{"code" => code, "message" => message}) when is_binary(message) do
    msg = String.downcase(message)

    cond do
      code == -32_601 ->
        {:method_not_found, %{code: code}}

      code == -32_602 ->
        {:invalid_params, %{code: code}}

      block_range_error?(msg) ->
        {:block_range, %{code: code, limit: extract_numeric_limit(message)}}

      address_limit_error?(msg) ->
        {:address_limit, %{code: code, limit: extract_numeric_limit(message)}}

      topic_complexity_error?(msg) ->
        {:topic_complexity, %{code: code}}

      log_volume_error?(msg) ->
        {:log_volume, %{code: code}}

      true ->
        map_core_category(ErrorClassification.categorize(code, message), code)
    end
  end

  def classify(%{"code" => code}) when is_integer(code) do
    map_core_category(ErrorClassification.categorize(code, nil), code)
  end

  def classify(_), do: {:unknown, %{}}

  @spec block_range_error?(map() | String.t()) :: boolean()
  def block_range_error?(%{"message" => message}) when is_binary(message),
    do: block_range_error?(String.downcase(message))

  def block_range_error?(message) when is_binary(message) do
    msg = if message == String.downcase(message), do: message, else: String.downcase(message)

    String.contains?(msg, "block range") or
      String.contains?(msg, "range limit") or
      String.contains?(msg, "too many blocks") or
      (String.contains?(msg, "exceed") and
         (String.contains?(msg, "block") or String.contains?(msg, "range"))) or
      (String.contains?(msg, "max") and String.contains?(msg, "block"))
  end

  def block_range_error?(_), do: false

  @spec rate_limit_error?(map() | String.t()) :: boolean()
  def rate_limit_error?(%{"code" => code}) when code in [429, -32_005], do: true

  def rate_limit_error?(%{"message" => message}) when is_binary(message),
    do: rate_limit_error?(message)

  def rate_limit_error?(message) when is_binary(message) do
    msg = String.downcase(message)

    String.contains?(msg, "rate limit") or
      String.contains?(msg, "too many requests") or
      String.contains?(msg, "throttle") or
      String.contains?(msg, "429")
  end

  def rate_limit_error?(_), do: false

  @spec address_limit_error?(map() | String.t()) :: boolean()
  def address_limit_error?(%{"message" => message}) when is_binary(message),
    do: address_limit_error?(String.downcase(message))

  def address_limit_error?(message) when is_binary(message) do
    msg = if message == String.downcase(message), do: message, else: String.downcase(message)

    String.contains?(msg, "address") and
      (String.contains?(msg, "limit") or
         String.contains?(msg, "too many") or
         String.contains?(msg, "exceed"))
  end

  def address_limit_error?(_), do: false

  @spec topic_complexity_error?(map() | String.t()) :: boolean()
  def topic_complexity_error?(%{"message" => message}) when is_binary(message),
    do: topic_complexity_error?(String.downcase(message))

  def topic_complexity_error?(message) when is_binary(message) do
    msg = if message == String.downcase(message), do: message, else: String.downcase(message)

    String.contains?(msg, "topic") and
      (String.contains?(msg, "limit") or
         String.contains?(msg, "too many") or
         String.contains?(msg, "complex") or
         String.contains?(msg, "exceed"))
  end

  def topic_complexity_error?(_), do: false

  @spec log_volume_error?(map() | String.t()) :: boolean()
  def log_volume_error?(%{"message" => message}) when is_binary(message),
    do: log_volume_error?(String.downcase(message))

  def log_volume_error?(message) when is_binary(message) do
    msg = if message == String.downcase(message), do: message, else: String.downcase(message)

    (String.contains?(msg, "log") and String.contains?(msg, "limit")) or
      String.contains?(msg, "too many logs") or
      (String.contains?(msg, "result") and String.contains?(msg, "limit")) or
      (String.contains?(msg, "response") and String.contains?(msg, "too large"))
  end

  def log_volume_error?(_), do: false

  @spec invalid_param_error?(map() | String.t()) :: boolean()
  def invalid_param_error?(%{"code" => -32_602}), do: true

  def invalid_param_error?(%{"message" => message}) when is_binary(message),
    do: invalid_param_error?(message)

  def invalid_param_error?(message) when is_binary(message) do
    msg = String.downcase(message)

    (String.contains?(msg, "invalid") and
       (String.contains?(msg, "param") or String.contains?(msg, "block"))) or
      String.contains?(msg, "unsupported") or
      String.contains?(msg, "unknown block")
  end

  def invalid_param_error?(_), do: false

  @doc "Returns a provider's Retry-After delay in milliseconds, when present."
  @spec parse_retry_after([{String.t(), String.t()}] | nil, String.t() | nil) ::
          non_neg_integer() | nil
  def parse_retry_after(headers, body), do: retry_after_header(headers) || retry_after_body(body)

  defp retry_after_header(nil), do: nil

  defp retry_after_header(headers) when is_list(headers) do
    case List.keyfind(headers, "retry-after", 0) do
      {_, value} -> parse_retry_after_value(String.trim(value))
      nil -> nil
    end
  end

  defp parse_retry_after_value(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds * 1_000
      _ -> parse_http_date_retry_after(value)
    end
  end

  defp parse_http_date_retry_after(value) do
    case :httpd_util.convert_request_date(String.to_charlist(value)) do
      {{year, month, day}, {hour, min, sec}} ->
        naive = NaiveDateTime.from_erl!({{year, month, day}, {hour, min, sec}})
        dt = DateTime.from_naive!(naive, "Etc/UTC")
        delay_ms = DateTime.diff(dt, DateTime.utc_now(), :millisecond)
        if delay_ms > 0, do: delay_ms, else: nil

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp retry_after_body(nil), do: nil
  defp retry_after_body(""), do: nil

  defp retry_after_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"retry_after" => seconds}} when is_number(seconds) and seconds >= 0 ->
        round(seconds * 1_000)

      _ ->
        nil
    end
  end

  defp map_core_category(:rate_limit, code), do: {:rate_limit, %{code: code}}
  defp map_core_category(:invalid_params, code), do: {:invalid_params, %{code: code}}
  defp map_core_category(:method_not_found, code), do: {:method_not_found, %{code: code}}

  defp map_core_category(category, code)
       when category in [:server_error, :unclassified_server_error, :internal_error],
       do: {:server_error, %{code: code}}

  defp map_core_category(:block_not_available, code), do: {:invalid_params, %{code: code}}
  defp map_core_category(_category, code), do: {:unknown, %{code: code}}

  defp extract_numeric_limit(message) do
    case Regex.run(~r/(\d+)/, message) do
      [_, num] -> String.to_integer(num)
      _ -> nil
    end
  end
end
