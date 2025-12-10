defmodule Lasso.Discovery.Probes.MethodSupport do
  @moduledoc """
  Probes RPC provider method support.

  Tests which JSON-RPC methods a provider supports by making
  minimal requests and analyzing the responses.
  """

  alias Lasso.Discovery.{ErrorClassifier, ProbeEngine, TestParams}
  alias Lasso.RPC.{HttpClient, MethodRegistry}

  @levels %{
    critical: [:core],
    standard: [:core, :state, :network, :eip1559, :mempool],
    full: [
      :core,
      :state,
      :network,
      :eip1559,
      :eip4844,
      :mempool,
      :filters,
      :subscriptions,
      :batch,
      :debug,
      :trace
    ]
  }

  @type method_status :: :supported | :unsupported | :unknown | :timeout
  @type method_result :: %{
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
    * `:timeout` - Request timeout in ms (default: 3000)
    * `:concurrent` - Max concurrent requests (default: 5)
    * `:transport` - :http or :ws (default: :http)

  ## Returns

  List of method results with status and timing information.
  """
  @spec probe(String.t(), keyword()) :: [method_result()]
  def probe(url, opts \\ []) do
    level = Keyword.get(opts, :level, :standard)
    timeout = Keyword.get(opts, :timeout, 3000)
    concurrent = Keyword.get(opts, :concurrent, 5)

    methods = get_methods_for_level(level)

    ProbeEngine.run(
      methods,
      fn method -> probe_http_method(url, method, timeout) end,
      concurrent: concurrent,
      timeout: timeout
    )
    |> Enum.map(fn {method, probe_result} ->
      category = MethodRegistry.method_category(method)

      result =
        case probe_result do
          {:ok, map} ->
            map

          {:error, reason} ->
            %{status: :error, error: inspect(reason), duration_ms: 0, error_code: nil}

          {:timeout, _} ->
            %{status: :timeout, error: "Timeout", duration_ms: timeout, error_code: nil}

          map when is_map(map) ->
            map
        end

      Map.merge(result, %{method: method, category: category})
    end)
  end

  @doc """
  Probes a single method via HTTP.

  Returns a map with :status, :duration_ms, and error details if any.
  """
  @spec probe_http_method(String.t(), String.t(), non_neg_integer()) :: map()
  def probe_http_method(url, method, timeout) do
    params = TestParams.minimal_params_for(method)
    provider_config = %{url: url}
    start_time = System.monotonic_time(:millisecond)

    result = HttpClient.request_decoded(provider_config, method, params, timeout: timeout)

    duration = System.monotonic_time(:millisecond) - start_time
    classify_response(result, duration)
  end

  @doc """
  Returns the methods to probe for a given level.
  """
  @spec get_methods_for_level(atom()) :: [String.t()]
  def get_methods_for_level(level) do
    categories = Map.get(@levels, level, @levels.standard)

    categories
    |> Enum.flat_map(&MethodRegistry.category_methods/1)
  end

  @doc """
  Groups probe results by status.
  """
  @spec group_by_status([method_result()]) :: %{
          supported: [method_result()],
          unsupported: [method_result()],
          unknown: [method_result()],
          timeout: [method_result()]
        }
  def group_by_status(results) do
    Enum.group_by(results, & &1.status)
    |> Map.put_new(:supported, [])
    |> Map.put_new(:unsupported, [])
    |> Map.put_new(:unknown, [])
    |> Map.put_new(:timeout, [])
  end

  @doc """
  Counts results by status.
  """
  @spec count_by_status([method_result()]) :: %{
          supported: integer(),
          unsupported: integer(),
          unknown: integer(),
          timeout: integer()
        }
  def count_by_status(results) do
    grouped = group_by_status(results)

    %{
      supported: length(grouped.supported),
      unsupported: length(grouped.unsupported),
      unknown: length(grouped.unknown),
      timeout: length(grouped.timeout)
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
  Identifies categories where >80% of methods are unsupported.

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
      category_methods = MethodRegistry.category_methods(cat)

      if length(category_methods) > 0 do
        unsupported_in_cat = Enum.count(category_methods, &(&1 in unsupported_methods))
        unsupported_in_cat / length(category_methods) > 0.8
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

  # Classifies HTTP response into a status
  defp classify_response(result, duration) do
    case result do
      {:ok, %{"result" => _result}} ->
        %{status: :supported, duration_ms: duration, error: nil, error_code: nil}

      {:ok, %{"error" => %{"code" => -32_601} = error}} ->
        %{
          status: :unsupported,
          duration_ms: duration,
          error: Map.get(error, "message", "Method not found"),
          error_code: -32_601
        }

      {:ok, %{"error" => %{"code" => -32_602} = error}} ->
        # Invalid params means method exists
        %{
          status: :supported,
          duration_ms: duration,
          error: Map.get(error, "message"),
          error_code: -32_602
        }

      {:ok, %{"error" => error}} when is_map(error) ->
        code = Map.get(error, "code")
        message = Map.get(error, "message", inspect(error))
        {error_type, _meta} = ErrorClassifier.classify(error)

        status =
          case error_type do
            :method_not_found -> :unsupported
            _ -> :unknown
          end

        %{status: status, duration_ms: duration, error: message, error_code: code}

      {:error, {reason, _payload}} ->
        %{status: :unknown, duration_ms: duration, error: "#{reason}", error_code: nil}

      {:error, reason} ->
        %{status: :unknown, duration_ms: duration, error: inspect(reason), error_code: nil}

      {:timeout, _} ->
        %{status: :timeout, duration_ms: duration, error: "Timeout", error_code: nil}
    end
  end
end
