defmodule LassoWeb.Dashboard.EndpointHelpers do
  @moduledoc """
  Helper functions for generating RPC endpoint URLs and configurations.

  Generates endpoint URLs that match the actual Phoenix routes defined in router.ex and endpoint.ex.
  All URLs use chain names (e.g., "ethereum", "base") not chain IDs (e.g., "1", "8453").
  """

  alias LassoWeb.Dashboard.Helpers
  require Logger

  # Available routing strategies (must match router.ex and endpoint.ex)
  @available_strategies ["round-robin", "latency-weighted", "fastest"]

  @doc """
  Returns list of available routing strategies.
  These match the actual routes defined in the router.
  """
  def available_strategies, do: @available_strategies

  @doc """
  Get comprehensive chain endpoints structure with all available routes.
  Returns a map with HTTP and WebSocket URLs for all strategies.
  """
  def get_chain_endpoints(profile, chain_name) do
    base_url = LassoWeb.Endpoint.url()
    ws_base_url = String.replace(base_url, ~r/^http/, "ws")
    chain_id = Helpers.get_chain_id(profile, chain_name)

    %{
      chain: chain_name,
      chain_id: chain_id,
      profile: profile,
      base_url: base_url,
      ws_base_url: ws_base_url,
      # Base endpoints (use default strategy configured in config.exs)
      http_base: "#{base_url}/rpc/profile/#{profile}/#{chain_name}",
      ws_base: "#{ws_base_url}/ws/rpc/profile/#{profile}/#{chain_name}",
      # Strategy-specific endpoints
      strategies:
        Enum.map(@available_strategies, fn strategy ->
          %{
            name: strategy,
            display_name: strategy_display_name(strategy),
            icon: strategy_icon(strategy),
            description: strategy_description(strategy),
            http_url: "#{base_url}/rpc/profile/#{profile}/#{strategy}/#{chain_name}",
            ws_url: "#{ws_base_url}/ws/rpc/profile/#{profile}/#{strategy}/#{chain_name}"
          }
        end)
    }
  end

  @doc "Get HTTP URL for strategy"
  def get_strategy_http_url(endpoints, strategy) do
    chain = extract_chain_name(endpoints)
    profile = endpoints.profile
    base_url = Map.get(endpoints, :base_url, LassoWeb.Endpoint.url())
    "#{base_url}/rpc/profile/#{profile}/#{strategy}/#{chain}"
  end

  @doc "Get WebSocket URL for strategy"
  def get_strategy_ws_url(endpoints, strategy) do
    chain = extract_chain_name(endpoints)
    profile = endpoints.profile

    ws_base_url =
      Map.get(endpoints, :ws_base_url) ||
        String.replace(LassoWeb.Endpoint.url(), ~r/^http/, "ws")

    "#{ws_base_url}/ws/rpc/profile/#{profile}/#{strategy}/#{chain}"
  end

  @doc "Get HTTP URL for specific provider"
  def get_provider_http_url(endpoints, provider) do
    chain = extract_chain_name(endpoints)
    profile = endpoints.profile
    base_url = Map.get(endpoints, :base_url, LassoWeb.Endpoint.url())
    provider_id = Map.get(provider, :id)
    "#{base_url}/rpc/profile/#{profile}/provider/#{provider_id}/#{chain}"
  end

  @doc "Get WebSocket URL for specific provider"
  def get_provider_ws_url(endpoints, provider) do
    chain = extract_chain_name(endpoints)
    profile = endpoints.profile

    ws_base_url =
      Map.get(endpoints, :ws_base_url) ||
        String.replace(LassoWeb.Endpoint.url(), ~r/^http/, "ws")

    provider_id = Map.get(provider, :id)
    "#{ws_base_url}/ws/rpc/profile/#{profile}/provider/#{provider_id}/#{chain}"
  end

  @doc "Get provider name or fallback to ID"
  def get_provider_name(provider) do
    Map.get(provider, :name) || Map.get(provider, :id)
  end

  @doc "Check if provider supports WebSocket"
  def provider_supports_websocket(provider) do
    # Check if provider has WebSocket support based on type or ws_url
    provider_type = Map.get(provider, :type)
    ws_url = Map.get(provider, :ws_url)

    provider_type in [:websocket, :both] or
      (not is_nil(ws_url) and ws_url != "")
  end

  # Extract chain name from endpoints map
  defp extract_chain_name(%{chain: chain}) when is_binary(chain), do: chain
  defp extract_chain_name(_), do: "ethereum"

  def strategy_display_name("round-robin"), do: "Load Balanced"
  def strategy_display_name("latency-weighted"), do: "Latency Weighted"
  def strategy_display_name("fastest"), do: "Fastest"
  def strategy_display_name(other), do: other |> String.replace("-", " ") |> String.capitalize()

  # Strategy icons
  defp strategy_icon("fastest"), do: "⚡"
  defp strategy_icon("round-robin"), do: "🔄"
  defp strategy_icon("latency-weighted"), do: "⚖️"
  defp strategy_icon(_), do: "🎯"

  # Strategy descriptions
  defp strategy_description("round-robin") do
    "Distributes requests evenly across all available providers — good for general purpose workloads"
  end

  defp strategy_description("latency-weighted") do
    "Load balanced favoring faster providers — good for high-throughput workloads like indexing and backfilling"
  end

  defp strategy_description("fastest") do
    "Routes all requests to the single fastest provider — best suited for low-volume, latency-sensitive calls"
  end

  defp strategy_description(_), do: "Strategy-based routing"
end
