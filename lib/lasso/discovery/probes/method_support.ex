defmodule Lasso.Discovery.Probes.MethodSupport do
  @moduledoc """
  Probes RPC provider method support.

  Tests which JSON-RPC methods a provider supports by making
  minimal requests and analyzing the responses.
  """

  alias Lasso.Config.MethodConstraints
  alias Lasso.Discovery.{ErrorClassifier, MethodEvidence, ProbeEngine, TestParams}
  alias Lasso.Discovery.Response, as: HttpClient
  alias Lasso.RPC.MethodRegistry

  @levels %{
    critical: [:core],
    # `:filters` carries `eth_getLogs`, the most-used non-core method and the
    # one whose block-range limit the router enforces. Verifying the limit
    # while leaving support unverified was an odd gap, so it is probed by
    # default.
    standard: [:core, :state, :network, :eip1559, :mempool, :filters],
    full: [
      :core,
      :state,
      :network,
      :eip1559,
      :eip4844,
      :mempool,
      :filters,
      :extended_reads,
      :debug,
      :trace,
      :txpool
      # :subscriptions excluded — eth_subscribe/eth_unsubscribe are transport-dependent
      # and meaningless over HTTP. Subscription support is probed via WebSocket.probe/1.
    ]
  }

  @type method_status ::
          :supported | :recognized | :unsupported | :unknown | :timeout | :unverifiable
  @type method_result :: %{
          optional(:error_type) => atom(),
          method: String.t(),
          status: method_status(),
          duration_ms: non_neg_integer(),
          category: atom(),
          error: String.t() | nil,
          error_code: integer() | nil
        }

  @doc """
  Probes method support for a provider URL.

  ## Options

    * `:level` - Probe level: :critical, :standard, :full (default: :standard)
    * `:timeout` - Request timeout in ms (default: 8000)
    * `:concurrent` - Max concurrent requests in normal mode (default: 3)
    * `:on_progress` - Optional `fn method, result -> :ok end` callback
    * `:on_throttle` - Optional `fn info -> :ok end` called when slow-mode engages

  ## Returns

  List of method results, or `{:aborted, :auth_required | :quota_exhausted}`.
  """
  @spec probe(String.t(), keyword()) :: [method_result()] | {:aborted, atom()}
  def probe(url, opts \\ []) do
    level = Keyword.get(opts, :level, :standard)
    timeout = Keyword.get(opts, :timeout, 8_000)
    concurrent = Keyword.get(opts, :concurrent, 3)
    on_progress = Keyword.get(opts, :on_progress)
    on_throttle = Keyword.get(opts, :on_throttle)

    context = probe_context(url, timeout)

    probe_method = fn method ->
      probe_http_method(url, method, timeout,
        context: context,
        provider_capabilities: Keyword.get(opts, :provider_capabilities, %{})
      )
    end

    methods = get_methods_for_level(level)
    chunks = Enum.chunk_every(methods, concurrent)

    # Signal a rate-limit the instant a single request returns 429, rather than
    # waiting for the chunk to finish — so the probe budget extends before a slow
    # chunk can burn the normal phase cap. Threaded as the progress callback.
    progress = build_progress_callback(on_progress, on_throttle)

    dispatch_chunks(chunks, probe_method, timeout, concurrent, progress, false, [])
  end

  defp build_progress_callback(nil, nil), do: nil

  defp build_progress_callback(on_progress, on_throttle) do
    fn method, result ->
      if on_progress, do: on_progress.(method, result)

      if on_throttle && throttle_signal?(result) do
        on_throttle.(%{retry_after_ms: nil, phase: :methods})
      end
    end
  end

  defp throttle_signal?({:ok, result}) when is_map(result), do: rate_limited_result?(result)
  defp throttle_signal?(_), do: false

  defp dispatch_chunks([], probe_method, timeout, _concurrent, _progress, slow, acc) do
    finalize_results(acc, probe_method, timeout, slow)
  end

  defp dispatch_chunks(
         [chunk | rest],
         probe_method,
         timeout,
         concurrent,
         progress,
         slow_mode,
         acc
       ) do
    effective_concurrent = if slow_mode, do: 1, else: concurrent

    chunk_results =
      ProbeEngine.run(
        chunk,
        probe_method,
        concurrent: effective_concurrent,
        timeout: timeout,
        on_progress: progress
      )
      |> Enum.map(&to_method_result(&1, timeout))

    cond do
      majority_auth?(chunk_results) ->
        {:aborted, :auth_required}

      Enum.any?(chunk_results, &quota_exhausted_result?/1) ->
        {:aborted, :quota_exhausted}

      not slow_mode and Enum.any?(chunk_results, &rate_limited_result?/1) ->
        # The budget was already extended per-request via the progress callback;
        # here we only drop the remaining chunks to slow-mode concurrency.
        dispatch_chunks(
          rest,
          probe_method,
          timeout,
          concurrent,
          progress,
          true,
          acc ++ chunk_results
        )

      true ->
        pace_if_needed(slow_mode)

        dispatch_chunks(
          rest,
          probe_method,
          timeout,
          concurrent,
          progress,
          slow_mode,
          acc ++ chunk_results
        )
    end
  end

  # One retry pass for transiently-failed methods. A `:timeout` or `:unknown`
  # result is often a slow response or a momentary blip, not a real provider
  # signal — re-probing once before finalizing damps the run-to-run noise. Auth
  # failures are excluded: they are deterministic, a retry cannot change them.
  #
  # The retry is capped at half the method set: when most methods need a retry
  # the provider is systemically failing, not blipping — retrying the whole set
  # cannot make a broken provider consistent and risks the phase running past
  # its budget. Methods beyond the cap keep their first-pass result.
  defp finalize_results(results, probe_method, timeout, slow_mode) do
    {to_retry, settled} =
      Enum.split_with(results, fn r ->
        r.status in [:timeout, :unknown] and not auth_result?(r) and
          not rate_limited_result?(r) and not quota_exhausted_result?(r)
      end)

    if to_retry == [] do
      results
    else
      {retry_now, retry_skipped} = Enum.split(to_retry, max(div(length(results), 2), 1))

      retried =
        Enum.map(retry_now, fn r ->
          if slow_mode, do: Process.sleep(1_000)
          probe_result = probe_method.(r.method)
          to_method_result({r.method, probe_result}, timeout)
        end)

      settled ++ retried ++ retry_skipped
    end
  end

  defp pace_if_needed(true), do: Process.sleep(1_000)
  defp pace_if_needed(false), do: :ok

  defp majority_auth?(results) do
    auth_count = Enum.count(results, &auth_result?/1)
    auth_count > 0 and auth_count >= div(length(results), 2) + 1
  end

  defp auth_result?(%{error_type: :auth_error}), do: true
  defp auth_result?(%{error_type: _}), do: false
  defp auth_result?(%{error_code: code}) when code in [401, 403], do: true

  defp auth_result?(%{status: :unknown, error: error}) when is_binary(error) do
    msg = String.downcase(error)

    String.contains?(msg, "auth") or
      String.contains?(msg, "unauthorized") or
      String.contains?(msg, "forbidden") or
      String.contains?(msg, "401") or
      String.contains?(msg, "403")
  end

  defp auth_result?(_), do: false

  # A bare HTTP 429 with no JSON-RPC body is classified with `error: "rate_limit"`
  # — the underscore form derived from the `kind` atom. `rate_limit_error?/1`
  # matches the space form, so normalize underscores before the check.
  defp rate_limited_result?(%{error_type: :rate_limit}), do: true
  defp rate_limited_result?(%{error_type: _}), do: false

  defp rate_limited_result?(%{status: :unknown, error: error}) when is_binary(error) do
    error
    |> String.replace("_", " ")
    |> ErrorClassifier.rate_limit_error?()
  end

  defp rate_limited_result?(_), do: false

  defp quota_exhausted_result?(%{error_type: :rate_limit, error: error}),
    do: ErrorClassifier.quota_exhausted?(error)

  defp quota_exhausted_result?(%{error_type: _}), do: false
  defp quota_exhausted_result?(%{error_code: 402}), do: true

  defp quota_exhausted_result?(%{error: error}) when is_binary(error),
    do: ErrorClassifier.quota_exhausted?(error)

  defp quota_exhausted_result?(_), do: false

  defp to_method_result({method, probe_result}, timeout) do
    category = MethodRegistry.method_category(method)

    result =
      case probe_result do
        {:ok, map} ->
          map

        {:error, reason} ->
          %{status: :unknown, error: inspect(reason), duration_ms: 0, error_code: nil}

        {:timeout, _} ->
          %{status: :timeout, error: "Timeout", duration_ms: timeout, error_code: nil}

        map when is_map(map) ->
          map
      end

    Map.merge(result, %{method: method, category: category})
  end

  @doc """
  Probes a single method via HTTP.

  Returns a map with :status, :duration_ms, and error details if any.
  """
  @unverifiable_methods MethodRegistry.unverifiable_methods()

  @spec probe_http_method(String.t(), String.t(), non_neg_integer(), keyword()) :: map()
  def probe_http_method(url, method, timeout, opts \\ [])

  def probe_http_method(_url, method, _timeout, _opts) when method in @unverifiable_methods do
    %{status: :unverifiable, duration_ms: 0, error: nil, error_code: nil}
  end

  def probe_http_method(url, method, timeout, opts) do
    params = TestParams.params_for(method, Keyword.get(opts, :context, %{}))
    start_time = System.monotonic_time(:millisecond)

    result =
      HttpClient.request_decoded(
        %{url: url},
        method,
        params,
        timeout: timeout
      )

    duration = System.monotonic_time(:millisecond) - start_time
    classify_response(result, duration, method, Keyword.get(opts, :provider_capabilities, %{}))
  end

  defp probe_context(url, timeout) do
    case HttpClient.request_decoded(
           %{url: url},
           "eth_getBlockByNumber",
           ["latest", false],
           timeout: timeout
         ) do
      {:ok, %{"result" => block}} when is_map(block) ->
        if MethodEvidence.classify("eth_getBlockByNumber", block) == :supported do
          transaction =
            case Map.get(block, "transactions", []) do
              [hash | _] when is_binary(hash) -> if MethodEvidence.data?(hash, 32), do: hash
              _ -> nil
            end

          %{
            block_hash: block["hash"],
            block_number: block["number"],
            transaction_hash: transaction
          }
        else
          %{}
        end

      _ ->
        %{}
    end
  end

  @doc """
  Returns the methods to probe for a given level.

  Methods the proxy refuses outright are excluded. Lasso answers those with
  `-32601` before selection runs, so a provider's support for them cannot change
  any routing decision and probing them would spend quota to learn nothing.
  """
  @spec get_methods_for_level(atom()) :: [String.t()]
  def get_methods_for_level(level) do
    categories = Map.get(@levels, level, @levels.standard)

    categories
    |> Enum.flat_map(&MethodRegistry.category_methods/1)
    |> Enum.reject(&MethodConstraints.disallowed?/1)
  end

  @doc """
  Groups probe results by status.
  """
  @spec group_by_status([method_result()]) :: %{
          recognized: [method_result()],
          supported: [method_result()],
          unsupported: [method_result()],
          unknown: [method_result()],
          timeout: [method_result()],
          unverifiable: [method_result()]
        }
  def group_by_status(results) do
    Enum.group_by(results, & &1.status)
    |> Map.put_new(:recognized, [])
    |> Map.put_new(:supported, [])
    |> Map.put_new(:unsupported, [])
    |> Map.put_new(:unknown, [])
    |> Map.put_new(:timeout, [])
    |> Map.put_new(:unverifiable, [])
  end

  @doc """
  Counts results by status.
  """
  @spec count_by_status([method_result()]) :: %{
          recognized: integer(),
          supported: integer(),
          unsupported: integer(),
          unknown: integer(),
          timeout: integer(),
          unverifiable: integer()
        }
  def count_by_status(results) do
    grouped = group_by_status(results)

    %{
      supported: length(grouped.supported),
      recognized: length(grouped.recognized),
      unsupported: length(grouped.unsupported),
      unknown: length(grouped.unknown),
      timeout: length(grouped.timeout),
      unverifiable: length(grouped.unverifiable)
    }
  end

  @doc """
  Groups results by method category.
  """
  @spec group_by_category([method_result()]) :: %{atom() => [method_result()]}
  def group_by_category(results) do
    Enum.group_by(results, & &1.category)
  end

  @doc """
  Identifies categories where every routable method is definitively unsupported.

  These are candidates for blocking at the category level in adapters.
  """
  @spec find_blocked_categories([method_result()]) :: [atom()]
  def find_blocked_categories(results) do
    unsupported_methods =
      results
      |> Enum.filter(&(&1.status == :unsupported))
      |> Enum.map(& &1.method)

    unsupported_methods
    |> Enum.map(&MethodRegistry.method_category/1)
    |> Enum.uniq()
    |> Enum.filter(fn cat ->
      category_methods =
        Enum.reject(MethodRegistry.category_methods(cat), &MethodConstraints.disallowed?/1)

      if category_methods != [] do
        unsupported_in_cat = Enum.count(category_methods, &(&1 in unsupported_methods))
        unsupported_in_cat == length(category_methods)
      else
        false
      end
    end)
  end

  @doc """
  Identifies individual unsupported methods not covered by blocked categories.
  """
  @spec find_unsupported_methods([method_result()], [atom()]) :: [String.t()]
  def find_unsupported_methods(results, blocked_categories) do
    results
    |> Enum.filter(&(&1.status == :unsupported))
    |> Enum.reject(&(&1.category in blocked_categories))
    |> Enum.map(& &1.method)
  end

  @doc """
  Identifies methods with unknown/timeout status not covered by blocked categories.
  """
  @spec find_unknown_methods([method_result()], [atom()]) :: [String.t()]
  def find_unknown_methods(results, blocked_categories) do
    results
    |> Enum.filter(&(&1.status in [:unknown, :timeout, :recognized, :error]))
    |> Enum.reject(&(&1.category in blocked_categories))
    |> Enum.map(& &1.method)
  end

  @doc """
  Methods that were reported as unverifiable rather than probed.

  Kept separate from `find_unknown_methods/2` so the report can say "cannot be
  verified" instead of "inconclusive, reprobe to confirm" — reprobing an
  unverifiable method can never change its result.
  """
  @spec find_unverifiable_methods([method_result()]) :: [String.t()]
  def find_unverifiable_methods(results) do
    results
    |> Enum.filter(&(&1.status == :unverifiable))
    |> Enum.map(& &1.method)
  end

  # Classifies HTTP response into a status
  defp classify_response(result, duration, method, capabilities) do
    case result do
      {:ok, %{"result" => value}} ->
        status = MethodEvidence.classify(method, value)

        error =
          case status do
            :supported -> nil
            :recognized -> "Method recognized; a successful read was not verified"
            :unknown -> "Invalid result shape for #{method}"
          end

        %{status: status, duration_ms: duration, error: error, error_code: nil}

      {:ok, %{"error" => error}} when is_map(error) ->
        classify_jsonrpc_error(error, duration, capabilities)

      # Many providers return HTTP 4xx (especially 403) with a JSON-RPC
      # error body for "method not found"/"method unsupported" — Base
      # mainnet does this for `debug_*`/`trace_*`/`txpool_*`. Decode the
      # body and feed it back through the JSON-RPC classifier so those
      # land as `:unsupported` instead of an opaque `:unknown` with
      # `error: "client_error"`.
      #
      {:error, {:rate_limit, %{body: body}}} ->
        case decode_jsonrpc_error(body) do
          {:ok, error_obj} ->
            error_obj
            |> classify_jsonrpc_error(duration, capabilities)
            |> Map.merge(%{status: :unknown, error_type: :rate_limit})

          :no_jsonrpc ->
            %{status: :unknown, duration_ms: duration, error: "rate_limit", error_code: 429}
        end

      {:error, {:rate_limit, _payload}} ->
        %{status: :unknown, duration_ms: duration, error: "rate_limit", error_code: 429}

      {:error, {:client_error, %{body: body} = payload}} ->
        case decode_jsonrpc_error(body) do
          {:ok, error_obj} ->
            classify_jsonrpc_error(error_obj, duration, capabilities)

          :no_jsonrpc ->
            %{
              status: :unknown,
              duration_ms: duration,
              error: "client_error",
              error_code: Map.get(payload, :status)
            }
        end

      {:error, {reason, _payload}} ->
        %{status: :unknown, duration_ms: duration, error: "#{reason}", error_code: nil}

      {:error, reason} ->
        %{status: :unknown, duration_ms: duration, error: inspect(reason), error_code: nil}

      _ ->
        %{
          status: :unknown,
          duration_ms: duration,
          error: "Malformed RPC response",
          error_code: nil
        }
    end
  end

  defp classify_jsonrpc_error(error, duration, capabilities) when is_map(error) do
    code = Map.get(error, "code")
    message = Map.get(error, "message", inspect(error))
    {error_type, _meta} = ErrorClassifier.classify(error, capabilities)

    status =
      case error_type do
        :method_not_found -> :unsupported
        :invalid_params -> :recognized
        :execution_error -> :recognized
        :block_range -> :recognized
        :address_limit -> :recognized
        :log_volume -> :recognized
        :topic_complexity -> :recognized
        :state_unavailable -> :recognized
        :rate_limit -> :unknown
        :auth_error -> :unknown
        :server_error -> :unknown
        :unknown -> :unknown
      end

    %{
      status: status,
      duration_ms: duration,
      error: message,
      error_code: code,
      error_type: error_type
    }
  end

  defp decode_jsonrpc_error(body) when is_binary(body) do
    case Lasso.Discovery.Response.decode(body, 1) do
      {:ok, %{"error" => error}} when is_map(error) -> {:ok, error}
      _ -> :no_jsonrpc
    end
  end

  defp decode_jsonrpc_error(_), do: :no_jsonrpc
end
