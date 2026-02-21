defmodule Lasso.Discovery.ErrorClassifier do
  @moduledoc """
  Unified error classification for provider discovery probing.

  Analyzes JSON-RPC error responses to identify specific error categories
  like rate limits, block range limits, and capability violations.
  Used by both method probing and limit discovery tasks.
  """

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

  @doc """
  Classifies an error response into a category with metadata.

  Returns `{error_type, metadata}` where metadata may include extracted limits
  or additional context.

  ## Examples

      iex> ErrorClassifier.classify(%{"code" => -32601, "message" => "Method not found"})
      {:method_not_found, %{code: -32601}}

      iex> ErrorClassifier.classify(%{"code" => -32005, "message" => "rate limit exceeded"})
      {:rate_limit, %{code: -32005}}
  """
  @spec classify(map()) :: {error_type(), map()}
  def classify(%{"code" => code, "message" => message}) when is_binary(message) do
    cond do
      code == -32_601 ->
        {:method_not_found, %{code: code}}

      code == -32_602 ->
        {:invalid_params, %{code: code}}

      code in [429, -32_005] or rate_limit_error?(message) ->
        {:rate_limit, %{code: code}}

      block_range_error?(message) ->
        {:block_range, %{code: code, limit: extract_numeric_limit(message)}}

      address_limit_error?(message) ->
        {:address_limit, %{code: code, limit: extract_numeric_limit(message)}}

      topic_complexity_error?(message) ->
        {:topic_complexity, %{code: code}}

      log_volume_error?(message) ->
        {:log_volume, %{code: code}}

      invalid_param_error?(message) ->
        {:invalid_params, %{code: code}}

      code >= -32_099 and code <= -32_000 ->
        {:server_error, %{code: code}}

      true ->
        {:unknown, %{code: code}}
    end
  end

  def classify(%{"code" => code}) when is_integer(code) do
    cond do
      code == -32_601 -> {:method_not_found, %{code: code}}
      code == -32_602 -> {:invalid_params, %{code: code}}
      code in [429, -32_005] -> {:rate_limit, %{code: code}}
      code >= -32_099 and code <= -32_000 -> {:server_error, %{code: code}}
      true -> {:unknown, %{code: code}}
    end
  end

  def classify(_), do: {:unknown, %{}}

  @doc """
  Checks if an error indicates a block range limit was exceeded.
  """
  @spec block_range_error?(map() | String.t()) :: boolean()
  def block_range_error?(%{"message" => message}) when is_binary(message) do
    block_range_error?(message)
  end

  def block_range_error?(message) when is_binary(message) do
    msg = String.downcase(message)

    String.contains?(msg, "block range") or
      String.contains?(msg, "range limit") or
      String.contains?(msg, "too many blocks") or
      (String.contains?(msg, "exceed") and
         (String.contains?(msg, "block") or String.contains?(msg, "range"))) or
      (String.contains?(msg, "max") and String.contains?(msg, "block"))
  end

  def block_range_error?(_), do: false

  @doc """
  Checks if an error indicates a rate limit was hit.
  """
  @spec rate_limit_error?(map() | String.t()) :: boolean()
  def rate_limit_error?(%{"code" => code}) when code in [429, -32_005], do: true

  def rate_limit_error?(%{"message" => message}) when is_binary(message) do
    rate_limit_error?(message)
  end

  def rate_limit_error?(message) when is_binary(message) do
    msg = String.downcase(message)

    String.contains?(msg, "rate limit") or
      String.contains?(msg, "too many requests") or
      String.contains?(msg, "throttle") or
      String.contains?(msg, "429")
  end

  def rate_limit_error?(_), do: false

  @doc """
  Checks if an error indicates an address count limit was exceeded.
  """
  @spec address_limit_error?(map() | String.t()) :: boolean()
  def address_limit_error?(%{"message" => message}) when is_binary(message) do
    address_limit_error?(message)
  end

  def address_limit_error?(message) when is_binary(message) do
    msg = String.downcase(message)

    String.contains?(msg, "address") and
      (String.contains?(msg, "limit") or
         String.contains?(msg, "too many") or
         String.contains?(msg, "exceed"))
  end

  def address_limit_error?(_), do: false

  @doc """
  Checks if an error indicates topic filter complexity limits.
  """
  @spec topic_complexity_error?(map() | String.t()) :: boolean()
  def topic_complexity_error?(%{"message" => message}) when is_binary(message) do
    topic_complexity_error?(message)
  end

  def topic_complexity_error?(message) when is_binary(message) do
    msg = String.downcase(message)

    String.contains?(msg, "topic") and
      (String.contains?(msg, "limit") or
         String.contains?(msg, "too many") or
         String.contains?(msg, "complex") or
         String.contains?(msg, "exceed"))
  end

  def topic_complexity_error?(_), do: false

  @doc """
  Checks if an error indicates log volume/result size limits.
  """
  @spec log_volume_error?(map() | String.t()) :: boolean()
  def log_volume_error?(%{"message" => message}) when is_binary(message) do
    log_volume_error?(message)
  end

  def log_volume_error?(message) when is_binary(message) do
    msg = String.downcase(message)

    (String.contains?(msg, "log") and String.contains?(msg, "limit")) or
      String.contains?(msg, "too many logs") or
      (String.contains?(msg, "result") and String.contains?(msg, "limit")) or
      (String.contains?(msg, "response") and String.contains?(msg, "too large"))
  end

  def log_volume_error?(_), do: false

  @doc """
  Checks if an error indicates invalid parameters.
  """
  @spec invalid_param_error?(map() | String.t()) :: boolean()
  def invalid_param_error?(%{"code" => -32_602}), do: true

  def invalid_param_error?(%{"message" => message}) when is_binary(message) do
    invalid_param_error?(message)
  end

  def invalid_param_error?(message) when is_binary(message) do
    msg = String.downcase(message)

    (String.contains?(msg, "invalid") and
       (String.contains?(msg, "param") or String.contains?(msg, "block"))) or
      String.contains?(msg, "unsupported") or
      String.contains?(msg, "unknown block")
  end

  def invalid_param_error?(_), do: false

  # Attempts to extract a numeric limit from an error message
  defp extract_numeric_limit(message) do
    case Regex.run(~r/(\d+)/, message) do
      [_, num] -> String.to_integer(num)
      _ -> nil
    end
  end
end
