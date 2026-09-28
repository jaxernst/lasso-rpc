defmodule Lasso.Discovery.ErrorClassifier do
  @moduledoc """
  Error classification for provider discovery probing.

  Delegates core error classification to `Lasso.Core.Support.ErrorClassification`
  and adds discovery-specific categorization (block range limits, address limits,
  topic complexity, log volume) with extracted metadata.

  ## Shared constants

  `rate_limit_codes/0` returns the EIP-1474 code-only compatibility fallback.
  Message and structured evidence retain precedence over that fallback.
  """

  alias Lasso.Core.Support.ErrorClassification

  @rate_limit_codes [-32_005]

  @type error_type ::
          :block_range
          | :address_limit
          | :rate_limit
          | :topic_complexity
          | :log_volume
          | :invalid_params
          | :method_not_found
          | :execution_error
          | :auth_error
          | :state_unavailable
          | :server_error
          | :unknown

  @spec classify(map()) :: {error_type(), map()}
  def classify(%{"code" => code, "message" => message} = error)
      when is_integer(code) and is_binary(message) do
    message = String.slice(message, 0, 4096)
    msg = String.downcase(message)
    core_category = ErrorClassification.categorize(code, message, Map.get(error, "data"))

    cond do
      core_category in [
        :execution_revert,
        :rate_limit,
        :parse_error,
        :invalid_request,
        :auth_error,
        :server_error,
        :internal_error,
        :network_error
      ] ->
        map_core_category(core_category, code)

      code == -32_601 ->
        {:method_not_found, %{code: code}}

      core_category == :invalid_params and
          ErrorClassification.categorize(nil, message) == :invalid_params ->
        {:invalid_params, %{code: code}}

      unsupported_method_message?(message) or namespace_disabled_message?(message) ->
        {:method_not_found, %{code: code}}

      block_range_error?(msg) ->
        {:block_range, %{code: code, limit: extract_numeric_limit(message)}}

      address_limit_error?(msg) ->
        {:address_limit, %{code: code, limit: extract_numeric_limit(message)}}

      topic_complexity_error?(msg) ->
        {:topic_complexity, %{code: code}}

      log_volume_error?(msg) ->
        {:log_volume, %{code: code}}

      state_unavailable?(message) ->
        {:state_unavailable, %{code: code}}

      true ->
        map_core_category(core_category, code)
    end
  end

  def classify(%{"code" => code} = error) when is_integer(code) do
    map_core_category(ErrorClassification.categorize(code, nil, Map.get(error, "data")), code)
  end

  def classify(_), do: {:unknown, %{}}

  @doc "Applies the same provider policy as request routing to ambiguous probe errors."
  @spec classify(map(), map()) :: {error_type(), map()}
  def classify(%{"code" => code} = error, %{error_rules: [_ | _]} = capabilities)
      when is_integer(code) do
    message = Map.get(error, "message")
    data = Map.get(error, "data")
    baseline = ErrorClassification.categorize(code, message, data)

    final =
      Lasso.Core.Support.ErrorClassifier.classify(code, message,
        provider_id: "discovery",
        provider_capabilities: capabilities,
        data: data,
        shared_instance?: false
      )

    if final.category == baseline,
      do: classify(error),
      else: map_core_category(final.category, code)
  end

  def classify(error, _capabilities), do: classify(error)

  @doc """
  Returns the EIP-1474 limit-exceeded compatibility code. Provider-specific
  numeric codes need message evidence or an attributed provider rule.
  """
  @spec rate_limit_codes() :: [integer()]
  def rate_limit_codes, do: @rate_limit_codes

  @doc """
  Returns true when an HTTP status or error body indicates the provider's quota
  is exhausted (a daily/monthly cap or spent credits) — a condition where waiting
  out a probe cannot help.

  Deliberately conservative. A bare "rate limit exceeded" or "too many requests"
  is transient throttling, not quota exhaustion, and must NOT match here — a
  false quota classification aborts the probe instead of entering slow-mode,
  defeating the adaptive-budget feature. Only unambiguous windowed-cap or credit
  signals match:

  - HTTP 402 (payment required / credits spent)
  - a message naming a daily/monthly window, spent credits, an exhausted quota,
    or an exceeded plan
  """
  @spec quota_exhausted?(map() | integer() | String.t()) :: boolean()
  defdelegate quota_exhausted?(value), to: ErrorClassification

  @doc """
  Parses the `Retry-After` value from an HTTP response, preferring the response
  header (integer seconds or HTTP-date) over a JSON body field, then falling back
  to `nil`. Returns milliseconds when a value is found.

  `headers` is a list of `{name, value}` tuples (Finch format, lowercase names).
  `body` is the raw response body binary (may be nil/empty).
  """
  @spec parse_retry_after([{String.t(), String.t()}] | nil, String.t() | nil) ::
          non_neg_integer() | nil
  def parse_retry_after(headers, body) do
    from_header(headers) || from_body(body)
  end

  defp from_header(nil), do: nil

  defp from_header(headers) when is_list(headers) do
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
    charlist = String.to_charlist(value)

    case :httpd_util.convert_request_date(charlist) do
      {{year, month, day}, {hour, min, sec}} ->
        naive = NaiveDateTime.from_erl!({{year, month, day}, {hour, min, sec}})
        dt = DateTime.from_naive!(naive, "Etc/UTC")
        now = DateTime.utc_now()
        ms = DateTime.diff(dt, now, :millisecond)
        if ms > 0, do: ms, else: nil

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp from_body(nil), do: nil
  defp from_body(""), do: nil

  defp from_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"retry_after" => seconds}} when is_number(seconds) and seconds >= 0 ->
        round(seconds * 1_000)

      _ ->
        nil
    end
  end

  @doc """
  Checks if an error message indicates a method is not supported,
  using message content rather than error code. Handles providers that
  use non-standard codes for unsupported methods (QuickNode, Infura, Alchemy).
  """
  @spec unsupported_method_message?(String.t()) :: boolean()
  def unsupported_method_message?(message) when is_binary(message) do
    msg = String.downcase(message)

    (String.contains?(msg, "method") and
       (String.contains?(msg, "not found") or
          String.contains?(msg, "not available") or
          String.contains?(msg, "not supported") or
          String.contains?(msg, "not exist") or
          String.contains?(msg, "does not exist"))) or
      String.contains?(msg, "unknown method") or
      String.contains?(msg, "unsupported method")
  end

  def unsupported_method_message?(_), do: false

  @doc """
  Whether a message says a whole namespace or API is switched off.

  Distinct from `unsupported_method_message?/1`, which requires the word
  "method". Providers commonly answer a `debug_*`/`trace_*` call with
  "debug namespace disabled" and no mention of a method, which is a definitive
  unsupported signal rather than an ambiguous one.
  """
  @spec namespace_disabled_message?(String.t()) :: boolean()
  def namespace_disabled_message?(message) when is_binary(message) do
    msg = String.downcase(message)

    (String.contains?(msg, "namespace") and
       (String.contains?(msg, "disabled") or String.contains?(msg, "not enabled"))) or
      String.contains?(msg, "api is disabled") or
      String.contains?(msg, "api not enabled")
  end

  def namespace_disabled_message?(_), do: false

  @doc """
  Whether an error explicitly says historical data is no longer retained.

  A **secondary** signal for archive detection. Error wording varies across
  execution clients, hosted providers, and proxies that rewrite upstream
  messages, so this cannot be the discriminator — depth is established by
  comparing a node against itself in `Lasso.Discovery.Probes.Limits`. This only
  adds coverage for nodes that prune so aggressively the comparison's control
  read fails too.

  Deliberately narrow, and phrases that occur for reasons other than retention
  are excluded on purpose: "block not found" also answers a block above head,
  and a bare "not found" appears in unrelated failures. A missed phrasing costs
  a verdict; a false match removes a working provider from historical routing,
  so the matcher errs toward missing.
  """
  @spec state_unavailable?(map() | String.t()) :: boolean()
  def state_unavailable?(%{"message" => message}) when is_binary(message),
    do: state_unavailable?(message)

  def state_unavailable?(message) when is_binary(message) do
    msg = String.downcase(message)

    # Geth and derivatives
    # Erigon, Reth, Nethermind, and hosted rewrites
    # Plan-gated archive access: the data exists but this endpoint won't serve
    # it, which is the same outcome for routing.
    String.contains?(msg, "missing trie node") or
      String.contains?(msg, "header not found") or
      String.contains?(msg, "state is not available") or
      String.contains?(msg, "state not available") or
      String.contains?(msg, "state unavailable") or
      String.contains?(msg, "no state available") or
      String.contains?(msg, "pruned") or
      (String.contains?(msg, "archive") and
         (String.contains?(msg, "not") or String.contains?(msg, "upgrade") or
            String.contains?(msg, "plan") or String.contains?(msg, "require"))) or
      (String.contains?(msg, "historical") and
         (String.contains?(msg, "not") or String.contains?(msg, "unavailable")))
  end

  def state_unavailable?(_), do: false

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
  def rate_limit_error?(error) when is_map(error),
    do:
      ErrorClassification.categorize(
        Map.get(error, "code"),
        Map.get(error, "message"),
        Map.get(error, "data")
      ) == :rate_limit

  def rate_limit_error?(message) when is_binary(message) do
    ErrorClassification.categorize(nil, message) == :rate_limit
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

  defp map_core_category(:rate_limit, code), do: {:rate_limit, %{code: code}}
  defp map_core_category(:auth_error, code), do: {:auth_error, %{code: code}}
  defp map_core_category(:requires_archival, code), do: {:state_unavailable, %{code: code}}
  defp map_core_category(:invalid_params, code), do: {:invalid_params, %{code: code}}
  defp map_core_category(:method_not_found, code), do: {:method_not_found, %{code: code}}
  defp map_core_category(:execution_revert, code), do: {:execution_error, %{code: code}}

  defp map_core_category(category, code)
       when category in [:server_error, :unclassified_server_error, :internal_error],
       do: {:server_error, %{code: code}}

  defp map_core_category(:block_not_available, code), do: {:invalid_params, %{code: code}}
  defp map_core_category(:capability_violation, code), do: {:unknown, %{code: code}}
  defp map_core_category(_category, code), do: {:unknown, %{code: code}}

  defp extract_numeric_limit(message) do
    case Regex.run(~r/(\d+)/, message) do
      [_, num] -> String.to_integer(num)
      _ -> nil
    end
  end
end
