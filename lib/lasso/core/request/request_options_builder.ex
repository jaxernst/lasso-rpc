defmodule Lasso.RPC.RequestOptions.Builder do
  @moduledoc """
  Builds %Lasso.RPC.RequestOptions{} from request context (Plug.Conn or overrides),
  applying precedence and method-specific policies.

  Precedence (highest → lowest):
  - explicit overrides passed to builder
  - headers (X-Lasso-*)
  - params (transport, provider_override/provider_id, strategy)
  - connection assigns (strategy)
  - application defaults
  """

  alias Lasso.RPC.RequestOptions
  alias Lasso.Config.{MethodPolicy, MethodConstraints}

  @type override_opts :: [
          strategy: RequestOptions.strategy(),
          provider_override: String.t(),
          transport: :http | :ws | :both,
          failover_on_override: boolean(),
          timeout_ms: non_neg_integer(),
          request_id: String.t(),
          request_context: any()
        ]

  @doc """
  Builds RequestOptions from a Plug.Conn with explicit precedence.

  ## Precedence (highest → lowest)
  1. Explicit overrides
  2. X-Lasso-* headers
  3. Query/Body parameters
  4. Connection assigns
  5. Application defaults

  Raises `ArgumentError` if constructed options are invalid for the given method.
  """
  @spec from_conn(Plug.Conn.t(), String.t(), override_opts) :: RequestOptions.t()
  def from_conn(%Plug.Conn{} = conn, method, overrides \\ []) when is_binary(method) do
    # Strategy
    strategy =
      cond do
        is_atom(overrides[:strategy]) ->
          overrides[:strategy]

        is_atom(conn.assigns[:provider_strategy]) ->
          conn.assigns[:provider_strategy]

        is_binary(conn.params["strategy"]) ->
          parse_strategy(conn.params["strategy"]) || default_strategy()

        true ->
          default_strategy()
      end

    # Provider override
    provider_override =
      overrides[:provider_override] ||
        header(conn, "x-lasso-provider") ||
        conn.params["provider_override"] ||
        conn.params["provider_id"]

    # Transport preference (precedence: overrides > headers > params)
    transport_header =
      case header(conn, "x-lasso-transport") do
        "http" -> :http
        "ws" -> :ws
        _ -> nil
      end

    transport_param =
      case conn.params["transport"] do
        "http" -> :http
        "ws" -> :ws
        _ -> nil
      end

    preference = overrides[:transport] || transport_header || transport_param

    transport =
      case MethodConstraints.required_transport_for(method) do
        :ws -> :ws
        _ -> preference
      end

    timeout_ms = overrides[:timeout_ms] || MethodPolicy.timeout_for(method)

    # Get request_id from override, or fall back to Logger.metadata (set by Plug.RequestId)
    request_id = overrides[:request_id] || Logger.metadata()[:request_id]
    request_context = overrides[:request_context]

    opts = %RequestOptions{
      strategy: strategy,
      provider_override: provider_override,
      transport: transport,
      failover_on_override: overrides[:failover_on_override] || false,
      timeout_ms: timeout_ms,
      request_id: request_id
    }
    |> put_request_context(request_context)

    # Validate the constructed options
    case RequestOptions.validate(opts, method) do
      :ok ->
        opts

      {:error, reason} ->
        raise ArgumentError, "Invalid RequestOptions: #{reason}"
    end
  end

  @doc """
  Builds RequestOptions from a plain map for non-HTTP contexts.

  Useful for CLI tools, internal services, or tests that don't have a Plug.Conn.

  ## Options (precedence: overrides > params > defaults)
  - `:strategy` - Strategy atom (default: from app config)
  - `:provider_override` / `:provider_id` - Force specific provider
  - `:transport` - Transport preference (:http, :ws, :both)
  - `:failover_on_override` - Retry on other providers if override fails (default: false)
  - `:timeout_ms` - Per-attempt timeout (default: method-specific)
  - `:request_id` - Request tracing ID
  - `:request_context` - RequestContext for observability

  Raises `ArgumentError` if constructed options are invalid for the given method.

  ## Examples

      iex> from_map(%{"strategy" => "fastest", "transport" => "ws"}, "eth_subscribe")
      %RequestOptions{strategy: :fastest, transport: :ws, ...}

      iex> from_map(%{}, "eth_blockNumber", strategy: :priority, timeout_ms: 5000)
      %RequestOptions{strategy: :priority, timeout_ms: 5000, ...}

  """
  @spec from_map(map(), String.t(), override_opts) :: RequestOptions.t()
  def from_map(params, method, overrides \\ [])
      when is_map(params) and is_binary(method) do
    # Strategy (overrides > params > default)
    strategy =
      cond do
        is_atom(overrides[:strategy]) ->
          overrides[:strategy]

        is_binary(params["strategy"]) ->
          parse_strategy(params["strategy"]) || default_strategy()

        true ->
          default_strategy()
      end

    # Provider override
    provider_override =
      overrides[:provider_override] || params["provider_override"] || params["provider_id"]

    # Transport
    transport_param =
      case params["transport"] do
        "http" -> :http
        "ws" -> :ws
        "both" -> :both
        _ -> nil
      end

    preference = overrides[:transport] || transport_param

    transport =
      case MethodConstraints.required_transport_for(method) do
        :ws -> :ws
        _ -> preference
      end

    timeout_ms = overrides[:timeout_ms] || MethodPolicy.timeout_for(method)
    request_id = overrides[:request_id]
    request_context = overrides[:request_context]

    opts =
      %RequestOptions{
        strategy: strategy,
        provider_override: provider_override,
        transport: transport,
        failover_on_override: overrides[:failover_on_override] || false,
        timeout_ms: timeout_ms,
        request_id: request_id
      }
      |> put_request_context(request_context)

    # Validate the constructed options
    case RequestOptions.validate(opts, method) do
      :ok ->
        opts

      {:error, reason} ->
        raise ArgumentError, "Invalid RequestOptions: #{reason}"
    end
  end

  @spec header(Plug.Conn.t(), String.t()) :: String.t() | nil
  defp header(conn, key), do: conn |> Plug.Conn.get_req_header(key) |> List.first()

  @spec parse_strategy(String.t()) :: RequestOptions.strategy() | nil
  defp parse_strategy("priority"), do: :priority
  defp parse_strategy("round_robin"), do: :round_robin
  defp parse_strategy("fastest"), do: :fastest
  defp parse_strategy("cheapest"), do: :cheapest
  defp parse_strategy("latency_weighted"), do: :latency_weighted
  defp parse_strategy(_), do: nil

  @spec default_strategy() :: RequestOptions.strategy()
  defp default_strategy, do: Application.get_env(:lasso, :provider_selection_strategy, :cheapest)

  @spec put_request_context(RequestOptions.t(), any()) :: RequestOptions.t()
  defp put_request_context(%RequestOptions{} = o, nil), do: o
  defp put_request_context(%RequestOptions{} = o, ctx), do: Map.put(o, :request_context, ctx)
end
