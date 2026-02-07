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

  alias Lasso.Config.{MethodConstraints, MethodPolicy}
  alias Lasso.RPC.RequestOptions
  alias LassoWeb.Plugs.RequestTimingPlug

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
    profile = Map.get(conn.assigns, :profile_slug, "default")
    strategy = resolve_strategy_from_conn(conn, overrides)
    provider_override = resolve_provider_from_conn(conn, overrides)
    transport = resolve_transport(method, resolve_transport_preference_from_conn(conn, overrides))

    build_and_validate(
      %RequestOptions{
        profile: profile,
        strategy: strategy,
        provider_override: provider_override,
        transport: transport,
        failover_on_override: overrides[:failover_on_override] || false,
        timeout_ms: overrides[:timeout_ms] || MethodPolicy.timeout_for(method),
        request_id: overrides[:request_id] || Logger.metadata()[:request_id],
        plug_start_time: RequestTimingPlug.get_start_time(conn)
      },
      overrides[:request_context],
      method
    )
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
    profile = overrides[:profile] || params["profile"] || "default"
    strategy = resolve_strategy_from_map(params, overrides)
    provider_override = resolve_provider_from_map(params, overrides)

    transport =
      resolve_transport(method, resolve_transport_preference_from_map(params, overrides))

    build_and_validate(
      %RequestOptions{
        profile: profile,
        strategy: strategy,
        provider_override: provider_override,
        transport: transport,
        failover_on_override: overrides[:failover_on_override] || false,
        timeout_ms: overrides[:timeout_ms] || MethodPolicy.timeout_for(method),
        request_id: overrides[:request_id]
      },
      overrides[:request_context],
      method
    )
  end

  # Strategy resolution

  defp resolve_strategy_from_conn(conn, overrides) do
    overrides[:strategy] ||
      conn.assigns[:provider_strategy] ||
      parse_strategy(conn.params["strategy"]) ||
      default_strategy()
  end

  defp resolve_strategy_from_map(params, overrides) do
    overrides[:strategy] ||
      parse_strategy(params["strategy"]) ||
      default_strategy()
  end

  # Provider resolution

  defp resolve_provider_from_conn(conn, overrides) do
    overrides[:provider_override] ||
      header(conn, "x-lasso-provider") ||
      conn.params["provider_override"] ||
      conn.params["provider_id"]
  end

  defp resolve_provider_from_map(params, overrides) do
    overrides[:provider_override] || params["provider_override"] || params["provider_id"]
  end

  # Transport resolution

  defp resolve_transport_preference_from_conn(conn, overrides) do
    overrides[:transport] ||
      parse_transport(header(conn, "x-lasso-transport")) ||
      parse_transport(conn.params["transport"])
  end

  defp resolve_transport_preference_from_map(params, overrides) do
    overrides[:transport] || parse_transport(params["transport"])
  end

  defp resolve_transport(method, preference) do
    case MethodConstraints.required_transport_for(method) do
      :ws -> :ws
      _ -> preference
    end
  end

  defp parse_transport("http"), do: :http
  defp parse_transport("ws"), do: :ws
  defp parse_transport("both"), do: :both
  defp parse_transport(_), do: nil

  # Finalization

  defp build_and_validate(opts, request_context, method) do
    opts = put_request_context(opts, request_context)

    case RequestOptions.validate(opts, method) do
      :ok -> opts
      {:error, reason} -> raise ArgumentError, "Invalid RequestOptions: #{reason}"
    end
  end

  # Utilities

  @spec header(Plug.Conn.t(), String.t()) :: String.t() | nil
  defp header(conn, key), do: conn |> Plug.Conn.get_req_header(key) |> List.first()

  @spec parse_strategy(String.t()) :: RequestOptions.strategy() | nil
  defp parse_strategy("priority"), do: :priority
  defp parse_strategy("round_robin"), do: :round_robin
  defp parse_strategy("fastest"), do: :fastest
  defp parse_strategy("latency_weighted"), do: :latency_weighted
  defp parse_strategy(nil), do: nil
  defp parse_strategy(_), do: nil

  @spec default_strategy() :: RequestOptions.strategy()
  defp default_strategy,
    do: Application.get_env(:lasso, :provider_selection_strategy, :round_robin)

  @spec put_request_context(RequestOptions.t(), any()) :: RequestOptions.t()
  defp put_request_context(%RequestOptions{} = o, nil), do: o
  defp put_request_context(%RequestOptions{} = o, ctx), do: Map.put(o, :request_context, ctx)
end
