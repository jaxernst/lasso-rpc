defmodule LivechainWeb.Dashboard.EndpointHelpers do
  @moduledoc """
  Helper functions for generating RPC endpoint URLs and configurations.
  """

  alias LivechainWeb.Dashboard.Helpers

  @doc "Assign chain endpoints to assigns"
  def assign_chain_endpoints(assigns, chain_name) do
    base_url = LivechainWeb.Endpoint.url()
    chain_id = Helpers.get_chain_id(chain_name)

    endpoints = %{
      chain: chain_name,
      chain_id: chain_id,
      http_strategies: [
        %{
          name: "Fastest (Latency-Optimized)",
          url: "#{base_url}/rpc/fastest/#{chain_id}",
          description: "Routes to fastest provider based on real-time latency"
        },
        %{
          name: "Leaderboard (Performance-Based)",
          url: "#{base_url}/rpc/leaderboard/#{chain_id}",
          description: "Routes using racing-based performance scores"
        },
        %{
          name: "Priority (Configured Order)",
          url: "#{base_url}/rpc/priority/#{chain_id}",
          description: "Routes by configured provider priority"
        },
        %{
          name: "Round Robin",
          url: "#{base_url}/rpc/round-robin/#{chain_id}",
          description: "Distributes load evenly across providers"
        },
        %{
          name: "Debug Mode",
          url: "#{base_url}/rpc/debug/#{chain_id}",
          description: "Enhanced logging and debugging info"
        }
      ]
    }

    Map.put(assigns, :chain_endpoints, endpoints)
  end

  @doc "Get HTTP URL for strategy"
  def get_strategy_http_url(endpoints, strategy) do
    base_url = LivechainWeb.Endpoint.url()
    chain_id = extract_chain_id(endpoints)
    "#{base_url}/rpc/#{String.replace(strategy, "_", "-")}/#{chain_id}"
  end

  @doc "Get WebSocket URL for strategy"
  def get_strategy_ws_url(endpoints, _strategy) do
    base_url = LivechainWeb.Endpoint.url()
    chain_id = extract_chain_id(endpoints)
    ws_url = String.replace(base_url, ~r/^http/, "ws")
    "#{ws_url}/ws/rpc/#{chain_id}"
  end

  @doc "Get HTTP URL for specific provider"
  def get_provider_http_url(endpoints, provider) do
    base_url = LivechainWeb.Endpoint.url()
    chain_id = extract_chain_id(endpoints)
    "#{base_url}/rpc/#{chain_id}/#{provider.id}"
  end

  @doc "Get WebSocket URL for specific provider"
  def get_provider_ws_url(endpoints, provider) do
    base_url = LivechainWeb.Endpoint.url()
    chain_id = extract_chain_id(endpoints)
    ws_url = String.replace(base_url, ~r/^http/, "ws")
    "#{ws_url}/ws/rpc/#{chain_id}?provider=#{provider.id}"
  end

  @doc "Get provider name or fallback to ID"
  def get_provider_name(provider) do
    provider.name || provider.id
  end

  @doc "Check if provider supports WebSocket"
  def provider_supports_websocket(_provider) do
    # For now, assume all providers support WebSocket
    # In the future, this could check provider capabilities
    true
  end

  @doc "Get chain endpoints (non-socket version)"
  def get_chain_endpoints(assigns, chain_name) do
    base_url = LivechainWeb.Endpoint.url()
    chain_id = Helpers.get_chain_id(chain_name)

    %{
      chain: chain_name,
      chain_id: chain_id,
      http_strategies: [
        %{
          name: "Fastest (Latency-Optimized)",
          url: "#{base_url}/rpc/fastest/#{chain_id}",
          description: "Routes to fastest provider based on real-time latency"
        },
        %{
          name: "Leaderboard (Performance-Based)",
          url: "#{base_url}/rpc/leaderboard/#{chain_id}",
          description: "Routes using racing-based performance scores"
        },
        %{
          name: "Priority (Configured Order)",
          url: "#{base_url}/rpc/priority/#{chain_id}",
          description: "Routes by configured provider priority"
        },
        %{
          name: "Round Robin",
          url: "#{base_url}/rpc/round-robin/#{chain_id}",
          description: "Distributes load evenly across providers"
        },
        %{
          name: "Debug Mode",
          url: "#{base_url}/rpc/debug/#{chain_id}",
          description: "Enhanced logging and debugging info"
        }
      ]
    }
  end

  # Prefer explicit chain_id when present; fallback to parsing first strategy URL
  defp extract_chain_id(%{chain_id: id}) when is_binary(id) and byte_size(id) > 0, do: id

  defp extract_chain_id(%{http_strategies: [%{url: url} | _]}) when is_binary(url) do
    url |> String.split("/") |> List.last()
  end

  defp extract_chain_id(_), do: "1"
end
