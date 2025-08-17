defmodule Livechain.Debug.ChainDebug do
  @moduledoc """
  Debug utilities for inspecting chain manager and supervisor state.
  """

  require Logger
  alias Livechain.RPC.ChainRegistry

  def debug_all_chains do
    Logger.info("=== Chain Debug Report ===")
    
    case ChainRegistry.get_status() do
      status when is_map(status) ->
        Logger.info("Total configured chains: #{status.total_configured_chains}")
        Logger.info("Active chain supervisors: #{status.running_chains}")
        
        if Map.has_key?(status, :chains) and is_list(status.chains) do
          status.chains
          |> Enum.each(fn chain_info ->
            debug_chain(chain_info.name, chain_info.status)
          end)
        else
          Logger.info("No chain status information available")
        end
        
      error ->
        Logger.error("Failed to get chain manager status: #{inspect(error)}")
    end
    
    Logger.info("=== End Chain Debug Report ===")
  end

  defp debug_chain(chain_name, chain_status) do
    Logger.info("Chain: #{chain_name}")
    Logger.info("  Status: #{inspect(chain_status)}")
    
    # Test if we can get available providers
    case ChainManager.get_available_providers(chain_name) do
      {:ok, providers} ->
        Logger.info("  Available providers: #{inspect(providers)}")
      {:error, reason} ->
        Logger.info("  Failed to get providers: #{inspect(reason)}")
    end
    
    # Test a simple RPC call
    case ChainManager.get_block_number(chain_name) do
      {:ok, block_number} ->
        Logger.info("  Latest block: #{block_number}")
      {:error, reason} ->
        Logger.info("  Failed to get block number: #{inspect(reason)}")
    end
  end

  def test_arbitrum_directly do
    Logger.info("=== Testing Arbitrum RPC URLs directly ===")
    
    urls = [
      "https://arb1.arbitrum.io/rpc",
      "https://arbitrum-one.public.blastapi.io"
    ]
    
    Enum.each(urls, fn url ->
      test_rpc_url(url)
    end)
  end

  defp test_rpc_url(url) do
    Logger.info("Testing: #{url}")
    
    body = Jason.encode!(%{
      jsonrpc: "2.0",
      method: "eth_blockNumber",
      params: [],
      id: 1
    })
    
    case Finch.build(:post, url, [{"Content-Type", "application/json"}], body)
         |> Finch.request(Livechain.Finch, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: response_body}} ->
        Logger.info("  ✓ Success: #{response_body}")
      {:ok, %{status: status, body: response_body}} ->
        Logger.info("  ✗ HTTP #{status}: #{response_body}")
      {:error, reason} ->
        Logger.info("  ✗ Error: #{inspect(reason)}")
    end
  end
end