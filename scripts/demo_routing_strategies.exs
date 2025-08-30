#!/usr/bin/env elixir

# Demo script to showcase all 4 routing strategies in Livechain
# Run with: elixir scripts/demo_routing_strategies.exs

Mix.install([
  {:jason, "~> 1.4"},
  {:finch, "~> 0.18"}
])

defmodule LivechainDemo do
  @base_url "http://localhost:4000"
  
  def start do
    IO.puts """
    🚀 Livechain Routing Strategy Demo
    ==================================
    
    This demo showcases Livechain's 4 routing strategies:
    
    1. 💰 CHEAPEST - Prefers free providers over paid ones
    2. ⚡ FASTEST  - Routes to providers with best performance
    3. 📊 PRIORITY - Uses static configuration priorities  
    4. 🔄 ROUND_ROBIN - Load balances across all providers
    
    Starting Finch HTTP client...
    """
    
    {:ok, _} = Finch.start_link(name: DemoFinch)
    
    # Test each strategy
    test_strategy("cheapest", "💰")
    test_strategy("fastest", "⚡")  
    test_strategy("priority", "📊")
    test_strategy("round-robin", "🔄")
    
    IO.puts """
    ✅ Demo complete! 
    
    Key takeaways:
    - Each strategy may route to different providers
    - FASTEST strategy uses real performance data
    - CHEAPEST prefers public/free providers
    - All strategies include automatic failover
    
    Try the endpoints yourself:
    curl -X POST #{@base_url}/rpc/cheapest/ethereum -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\",\"params\":[],\"id\":1}'
    """
  end
  
  defp test_strategy(strategy, emoji) do
    url = "#{@base_url}/rpc/#{strategy}/ethereum"
    
    payload = %{
      "jsonrpc" => "2.0",
      "method" => "eth_blockNumber",
      "params" => [],
      "id" => 1
    }
    
    IO.puts "\\n#{emoji} Testing #{String.upcase(strategy)} strategy..."
    IO.puts "   Endpoint: #{url}"
    
    case make_request(url, payload) do
      {:ok, response} ->
        block_number = get_in(response, ["result"])
        IO.puts "   ✅ Success: Block #{block_number}"
        
      {:error, reason} ->
        IO.puts "   ❌ Failed: #{inspect(reason)}"
    end
    
    # Small delay between requests
    Process.sleep(500)
  end
  
  defp make_request(url, payload) do
    headers = [{"content-type", "application/json"}]
    body = Jason.encode!(payload)
    
    case Finch.build(:post, url, headers, body) 
         |> Finch.request(DemoFinch, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, json} -> {:ok, json}
          {:error, _} -> {:error, :invalid_json}
        end
        
      {:ok, %{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{body}"}
        
      {:error, reason} ->
        {:error, reason}
    end
  end
end

# Check if Livechain is running
case System.cmd("curl", ["-s", "http://localhost:4000/api/health"], stderr_to_stdout: true) do
  {response, 0} ->
    case Jason.decode(response) do
      {:ok, %{"status" => "ok"}} ->
        LivechainDemo.start()
        
      _ ->
        IO.puts """
        ❌ Livechain is not responding properly.
        
        Please start Livechain first:
        mix phx.server
        
        Then run this demo again.
        """
        
    end
    
  _ ->
    IO.puts """
    ❌ Cannot connect to Livechain at http://localhost:4000
    
    Please start Livechain first:
    mix phx.server
    
    Then run this demo again.
    """
end