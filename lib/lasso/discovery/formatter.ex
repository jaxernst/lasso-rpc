defmodule Lasso.Discovery.Formatter do
  @moduledoc """
  Output formatters for discovery probe results.

  Supports multiple output formats:
  - `:table` - Human-readable table with status icons
  - `:json` - JSON output for programmatic use
  """

  alias Lasso.Discovery.Probes.MethodSupport

  @divider_width 80

  # Status icons for terminal output
  @status_icons %{
    supported: "~G",
    unsupported: "~R",
    unknown: "~Y",
    timeout: "~Y",
    limited: "~Y",
    unlimited: "~G",
    inconclusive: "~Y",
    tested: "~B",
    not_supported: "~R",
    ok: "~G",
    error: "~R"
  }

  @doc """
  Formats probe results for output.

  ## Options

    * `:format` - Output format: :table, :json (default: :table)
  """
  @spec format(map(), keyword()) :: String.t()
  def format(results, opts \\ []) do
    format_type = Keyword.get(opts, :format, :table)

    case format_type do
      :table -> format_table(results)
      :json -> format_json(results)
      _ -> "Unknown format: #{format_type}"
    end
  end

  @doc """
  Formats results as a human-readable table.
  """
  @spec format_table(map()) :: String.t()
  def format_table(results) do
    sections = [
      format_header(results),
      format_methods_section(results[:methods]),
      format_limits_section(results[:limits]),
      format_websocket_section(results[:websocket]),
      format_summary(results)
    ]

    sections
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  @doc """
  Formats results as JSON.
  """
  @spec format_json(map()) :: String.t()
  def format_json(results) do
    results
    |> prepare_for_json()
    |> Jason.encode!(pretty: true)
  end

  # Header section

  defp format_header(results) do
    timestamp =
      case results[:timestamp] do
        %DateTime{} = dt -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
        _ -> "N/A"
      end

    probes =
      (results[:probes_run] || [])
      |> Enum.map(&Atom.to_string/1)
      |> Enum.join(", ")

    [
      divider(),
      "PROVIDER DISCOVERY RESULTS",
      divider(),
      "URL: #{results[:url] || "N/A"}",
      "Probes: #{probes}",
      "Timestamp: #{timestamp} UTC",
      ""
    ]
    |> Enum.join("\n")
  end

  # Methods section

  defp format_methods_section(nil), do: nil

  defp format_methods_section(methods) when is_list(methods) do
    by_status = MethodSupport.count_by_status(methods)
    by_category = MethodSupport.group_by_category(methods)

    # Summary stats
    stats = [
      "#{status_icon(:supported)} Supported: #{by_status.supported}",
      "#{status_icon(:unsupported)} Unsupported: #{by_status.unsupported}",
      "#{status_icon(:unknown)} Unknown: #{by_status.unknown}",
      "#{status_icon(:timeout)} Timeout: #{by_status.timeout}"
    ]

    # Detailed per-category breakdown
    category_sections =
      by_category
      |> Enum.sort_by(fn {cat, _} -> cat end)
      |> Enum.map(fn {category, cat_methods} ->
        format_category_methods(category, cat_methods)
      end)

    # List unsupported/problem methods explicitly
    problem_methods = methods |> Enum.filter(&(&1.status != :supported))

    problem_section =
      if length(problem_methods) > 0 do
        problem_lines =
          problem_methods
          |> Enum.map(fn m ->
            error_info = if m[:error], do: " - #{m.error}", else: ""
            code_info = if m[:error_code], do: " [#{m.error_code}]", else: ""
            "  #{status_icon(m.status)} #{m.method}#{code_info}#{error_info}"
          end)

        ["", "Problems:", Enum.join(problem_lines, "\n")]
      else
        []
      end

    [
      divider(),
      "METHOD SUPPORT",
      divider(),
      Enum.join(stats, "\n"),
      "",
      "By Category:",
      Enum.join(category_sections, "\n"),
      problem_section,
      ""
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp format_category_methods(category, methods) do
    supported = Enum.count(methods, &(&1.status == :supported))
    total = length(methods)

    # Show individual methods with latency
    method_lines =
      methods
      |> Enum.sort_by(& &1.method)
      |> Enum.map(fn m ->
        icon = status_icon(m.status)
        latency = if m[:duration_ms], do: " (#{m.duration_ms}ms)", else: ""
        "    #{icon} #{m.method}#{latency}"
      end)

    [
      "  #{category}: #{supported}/#{total}",
      Enum.join(method_lines, "\n")
    ]
    |> Enum.join("\n")
  end

  # Limits section

  defp format_limits_section(nil), do: nil

  defp format_limits_section(limits) when is_map(limits) do
    tests =
      limits
      |> Enum.map(fn {test, result} ->
        format_limit_test(test, result)
      end)

    [
      divider(),
      "PROVIDER LIMITS",
      divider(),
      Enum.join(tests, "\n\n"),
      ""
    ]
    |> Enum.join("\n")
  end

  defp format_limit_test(test, result) do
    icon = status_icon(result[:status] || :unknown)
    name = test |> Atom.to_string() |> String.replace("_", " ") |> String.upcase()

    value_line =
      case result[:value] do
        nil -> ""
        v when is_list(v) -> "   Value: #{Enum.join(v, ", ")}"
        v when is_map(v) -> "   Value: #{format_map_value(v)}"
        v -> "   Value: #{v}"
      end

    [
      "#{icon} #{name}",
      "   Status: #{result[:status]}",
      value_line,
      "   -> #{result[:recommendation]}"
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  # WebSocket section

  defp format_websocket_section(nil), do: nil

  defp format_websocket_section(%{connected: false, error: error}) do
    [
      divider(),
      "WEBSOCKET",
      divider(),
      "#{status_icon(:error)} Connection Failed",
      "   Error: #{error}",
      "",
      "   WebSocket probing requires a valid ws:// or wss:// endpoint.",
      "   Some providers only support WebSocket on specific paths (e.g., /ws).",
      ""
    ]
    |> Enum.join("\n")
  end

  defp format_websocket_section(ws) do
    conn_status =
      if ws.connected do
        "#{status_icon(:ok)} Connected"
      else
        "#{status_icon(:error)} Not Connected"
      end

    conn_latency =
      case ws[:connection] do
        %{latency_ms: ms} -> " (#{ms}ms latency)"
        %{status: :error, error: err} -> " - Error: #{err}"
        _ -> ""
      end

    # Unary request results
    unary_lines =
      case ws[:unary_requests] do
        nil ->
          []

        requests when is_map(requests) ->
          ["", "Unary Requests:"] ++
            Enum.map(requests, fn {method, result} ->
              icon = status_icon(result[:status] || :unknown)
              latency = if result[:latency_ms], do: " (#{result.latency_ms}ms)", else: ""
              error = if result[:error], do: " - #{result.error}", else: ""
              "   #{icon} #{method}#{latency}#{error}"
            end)
      end

    # Subscription results
    subscription_lines =
      case ws[:subscriptions] do
        nil ->
          []

        subs when is_map(subs) ->
          ["", "Subscriptions (eth_subscribe):"] ++
            Enum.map(subs, fn {type, result} ->
              icon = status_icon(result[:status] || :unknown)
              details = format_subscription_details(result)
              "   #{icon} #{type}: #{result[:status]}#{details}"
            end)
      end

    [
      divider(),
      "WEBSOCKET",
      divider(),
      "#{conn_status}#{conn_latency}",
      unary_lines,
      subscription_lines,
      ""
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp format_subscription_details(result) do
    parts = []

    parts =
      if result[:subscription_id] do
        parts ++ ["sub_id: #{String.slice(result.subscription_id, 0, 10)}..."]
      else
        parts
      end

    parts =
      cond do
        result[:received_event] == true ->
          parts ++ ["event received"]

        result[:received_event] == false ->
          parts ++ ["no events in wait period"]

        true ->
          parts
      end

    parts =
      if result[:error] do
        parts ++ ["error: #{result.error}"]
      else
        parts
      end

    if length(parts) > 0, do: " (#{Enum.join(parts, ", ")})", else: ""
  end

  # Summary section

  defp format_summary(results) do
    config = Lasso.Discovery.generate_adapter_config(results)

    recommendations = []

    recommendations =
      if config[:max_block_range] do
        recommendations ++ ["- Set max_block_range: #{config.max_block_range}"]
      else
        recommendations
      end

    recommendations =
      if config[:max_addresses] do
        recommendations ++ ["- Set max_addresses: #{config.max_addresses}"]
      else
        recommendations
      end

    recommendations =
      if config[:blocked_categories] && length(config.blocked_categories) > 0 do
        cats = Enum.join(config.blocked_categories, ", ")
        recommendations ++ ["- Block categories: #{cats}"]
      else
        recommendations
      end

    recommendations =
      if config[:unsupported_methods] && length(config.unsupported_methods) > 0 do
        count = length(config.unsupported_methods)
        recommendations ++ ["- #{count} individual unsupported methods"]
      else
        recommendations
      end

    if length(recommendations) > 0 do
      [
        "",
        divider(),
        "RECOMMENDATIONS",
        divider(),
        Enum.join(recommendations, "\n")
      ]
      |> Enum.join("\n")
    else
      [
        "",
        divider(),
        "RECOMMENDATIONS",
        divider(),
        "No custom adapter configuration needed."
      ]
      |> Enum.join("\n")
    end
  end

  # Helpers

  defp divider, do: String.duplicate("=", @divider_width)

  defp status_icon(status) do
    case Map.get(@status_icons, status) do
      "~G" -> "+"
      "~R" -> "x"
      "~Y" -> "?"
      "~B" -> "i"
      _ -> " "
    end
  end

  defp format_map_value(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> "#{k}: #{v}" end)
    |> Enum.join(", ")
  end

  defp prepare_for_json(results) do
    results
    |> Map.update(:timestamp, nil, fn
      %DateTime{} = dt -> DateTime.to_iso8601(dt)
      other -> other
    end)
    |> Map.update(:methods, nil, fn
      methods when is_list(methods) ->
        Enum.map(methods, fn m ->
          m
          |> Map.update(:category, nil, &Atom.to_string/1)
          |> Map.update(:status, nil, &Atom.to_string/1)
        end)

      other ->
        other
    end)
    |> Map.update(:limits, nil, fn
      limits when is_map(limits) ->
        Map.new(limits, fn {k, v} ->
          {Atom.to_string(k), stringify_map_values(v)}
        end)

      other ->
        other
    end)
    |> Map.update(:websocket, nil, fn
      ws when is_map(ws) -> stringify_map_values(ws)
      other -> other
    end)
  end

  defp stringify_map_values(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(v) -> {k, Atom.to_string(v)}
      {k, v} when is_map(v) -> {k, stringify_map_values(v)}
      {k, v} -> {k, v}
    end)
  end

  defp stringify_map_values(other), do: other
end
