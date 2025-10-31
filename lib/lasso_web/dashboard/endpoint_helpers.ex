defmodule LassoWeb.Dashboard.EndpointHelpers do
  @moduledoc """
  Helper functions for generating RPC endpoint URLs and configurations.

  Generates endpoint URLs that match the actual Phoenix routes defined in router.ex and endpoint.ex.
  All URLs use chain names (e.g., "ethereum", "base") not chain IDs (e.g., "1", "8453").
  """

  alias LassoWeb.Dashboard.Helpers

  # Available routing strategies (must match router.ex and endpoint.ex)
  @available_strategies ["fastest", "round-robin", "latency-weighted"]

  @doc """
  Returns list of available routing strategies.
  These match the actual routes defined in the router.
  """
  def available_strategies, do: @available_strategies

  @doc """
  Get comprehensive chain endpoints structure with all available routes.
  Returns a map with HTTP and WebSocket URLs for all strategies.
  """
  def get_chain_endpoints(_assigns, chain_name) do
    base_url = LassoWeb.Endpoint.url()
    ws_base_url = String.replace(base_url, ~r/^http/, "ws")
    chain_id = Helpers.get_chain_id(chain_name)

    %{
      chain: chain_name,
      chain_id: chain_id,
      base_url: base_url,
      ws_base_url: ws_base_url,
      # Base endpoints (use default strategy configured in config.exs)
      http_base: "#{base_url}/rpc/#{chain_name}",
      ws_base: "#{ws_base_url}/ws/rpc/#{chain_name}",
      # Strategy-specific endpoints
      strategies:
        Enum.map(@available_strategies, fn strategy ->
          %{
            name: strategy,
            display_name: strategy_display_name(strategy),
            icon: strategy_icon(strategy),
            description: strategy_description(strategy),
            http_url: "#{base_url}/rpc/#{strategy}/#{chain_name}",
            ws_url: "#{ws_base_url}/ws/rpc/#{strategy}/#{chain_name}"
          }
        end)
    }
  end

  @doc "Get HTTP URL for strategy"
  def get_strategy_http_url(endpoints, strategy) do
    chain = extract_chain_name(endpoints)
    base_url = Map.get(endpoints, :base_url, LassoWeb.Endpoint.url())
    "#{base_url}/rpc/#{strategy}/#{chain}"
  end

  @doc "Get WebSocket URL for strategy"
  def get_strategy_ws_url(endpoints, strategy) do
    chain = extract_chain_name(endpoints)
    ws_base_url = Map.get(endpoints, :ws_base_url) ||
                  String.replace(LassoWeb.Endpoint.url(), ~r/^http/, "ws")
    "#{ws_base_url}/ws/rpc/#{strategy}/#{chain}"
  end

  @doc "Get HTTP URL for specific provider"
  def get_provider_http_url(endpoints, provider) do
    chain = extract_chain_name(endpoints)
    base_url = Map.get(endpoints, :base_url, LassoWeb.Endpoint.url())
    provider_id = Map.get(provider, :id)
    "#{base_url}/rpc/provider/#{provider_id}/#{chain}"
  end

  @doc "Get WebSocket URL for specific provider"
  def get_provider_ws_url(endpoints, provider) do
    chain = extract_chain_name(endpoints)
    ws_base_url = Map.get(endpoints, :ws_base_url) ||
                  String.replace(LassoWeb.Endpoint.url(), ~r/^http/, "ws")
    provider_id = Map.get(provider, :id)
    "#{ws_base_url}/ws/rpc/provider/#{provider_id}/#{chain}"
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

  # Strategy display names
  defp strategy_display_name("fastest"), do: "Fastest"
  defp strategy_display_name("round-robin"), do: "Round Robin"
  defp strategy_display_name("latency-weighted"), do: "Latency Weighted"
  defp strategy_display_name(other), do: other |> String.replace("-", " ") |> String.capitalize()

  # Strategy icons
  defp strategy_icon("fastest"), do: "⚡"
  defp strategy_icon("round-robin"), do: "🔄"
  defp strategy_icon("latency-weighted"), do: "⚖️"
  defp strategy_icon(_), do: "🎯"

  # Strategy descriptions
  defp strategy_description("fastest") do
    "Routes to the fastest provider based on real-time latency benchmarks"
  end

  defp strategy_description("round-robin") do
    "Distributes requests evenly across all available providers"
  end

  defp strategy_description("latency-weighted") do
    "Weighted random selection favoring providers with low latency and high success rates"
  end

  defp strategy_description(_), do: "Strategy-based routing"
end
