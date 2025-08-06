defmodule Livechain.EventProcessing.EventEnricher do
  @moduledoc """
  Enriches blockchain events with additional metadata and context.

  This module adds valuable context to raw blockchain events including:
  - Contract metadata and labels
  - Token information (name, symbol, decimals)
  - Address labels and known entities
  - Transaction context and gas information
  - Cross-chain event correlation
  """

  require Logger

  alias Livechain.EventProcessing.{EventClassifier, ContractRegistry, TokenRegistry}

  @doc """
  Enriches a blockchain event with additional metadata based on its type.
  """
  def enrich(event, event_type) do
    event
    |> add_base_enrichment(event_type)
    |> add_type_specific_enrichment(event_type)
    |> add_contract_metadata()
    |> add_timing_metadata()
  end

  # Base enrichment for all events
  defp add_base_enrichment(event, event_type) do
    metadata = EventClassifier.get_metadata(event, event_type)

    Map.merge(event, %{
      __enriched: true,
      __enriched_at: System.system_time(:millisecond),
      type: event_type,
      chain: metadata.chain,
      classification_metadata: metadata
    })
  end

  # Type-specific enrichment
  defp add_type_specific_enrichment(event, :erc20_transfer) do
    enrich_erc20_transfer(event)
  end

  defp add_type_specific_enrichment(event, :nft_transfer) do
    enrich_nft_transfer(event)
  end

  defp add_type_specific_enrichment(event, :block) do
    enrich_block_event(event)
  end

  defp add_type_specific_enrichment(event, :transaction) do
    enrich_transaction_event(event)
  end

  defp add_type_specific_enrichment(event, _type), do: event

  # ERC-20 transfer enrichment
  defp enrich_erc20_transfer(event) do
    metadata = event.classification_metadata

    token_info =
      case metadata.token_address do
        nil -> %{}
        address -> get_token_info(address, event.chain)
      end

    parsed_amount = parse_token_amount(metadata.amount, token_info.decimals || 18)

    event
    |> Map.merge(%{
      token_address: metadata.token_address,
      from_address: metadata.from,
      to_address: metadata.to,
      amount: metadata.amount,
      amount_formatted: parsed_amount,
      token_info: token_info
    })
    |> add_address_labels()
  end

  # NFT transfer enrichment
  defp enrich_nft_transfer(event) do
    metadata = event.classification_metadata

    contract_info =
      case metadata.contract_address do
        nil -> %{}
        address -> get_nft_contract_info(address, event.chain)
      end

    event
    |> Map.merge(%{
      contract_address: metadata.contract_address,
      from_address: metadata.from,
      to_address: metadata.to,
      token_id: metadata.token_id,
      contract_info: contract_info
    })
    |> add_nft_metadata()
    |> add_address_labels()
  end

  # Block event enrichment
  defp enrich_block_event(event) do
    metadata = event.classification_metadata

    event
    |> Map.merge(%{
      block_number: metadata.block_number,
      block_hash: metadata.block_hash,
      block_timestamp: metadata.timestamp,
      transaction_count: metadata.transaction_count
    })
    |> add_block_analysis()
  end

  # Transaction event enrichment
  defp enrich_transaction_event(event) do
    event
    |> add_transaction_metadata()
    |> add_gas_analysis()
  end

  # Contract metadata enrichment
  defp add_contract_metadata(event) do
    contracts_to_lookup = extract_contract_addresses(event)

    contract_metadata =
      contracts_to_lookup
      |> Enum.map(fn address ->
        {address, get_contract_metadata(address, event.chain)}
      end)
      |> Enum.into(%{})

    Map.put(event, :contract_metadata, contract_metadata)
  end

  # Timing metadata
  defp add_timing_metadata(event) do
    now = System.system_time(:millisecond)

    # Calculate processing latency from original message timestamp
    processing_latency =
      case get_original_timestamp(event) do
        nil -> nil
        original_timestamp -> now - original_timestamp
      end

    Map.merge(event, %{
      processed_at: now,
      processing_latency_ms: processing_latency
    })
  end

  # Helper functions

  defp get_token_info(address, chain) do
    # In production, this would query a token registry or on-chain data
    # For now, return mock data for known tokens
    case String.downcase(address) do
      # USDC on Ethereum
      "0xa0b86a33e6441e01951e7b9044d4c085e2e8e6e3" ->
        %{name: "USD Coin", symbol: "USDC", decimals: 6}

      # WETH on Ethereum  
      "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2" ->
        %{name: "Wrapped Ether", symbol: "WETH", decimals: 18}

      _ ->
        # Would query TokenRegistry.get_token_info(address, chain) in production
        %{name: "Unknown Token", symbol: "UNK", decimals: 18}
    end
  end

  defp get_nft_contract_info(address, chain) do
    # In production, this would query NFT metadata
    %{
      name: "Unknown Collection",
      symbol: "UNK",
      # or "ERC1155"
      type: "ERC721"
    }
  end

  defp parse_token_amount(nil, _decimals), do: "0"

  defp parse_token_amount(amount_hex, decimals) when is_binary(amount_hex) do
    try do
      amount_hex
      |> String.trim_leading("0x")
      |> Integer.parse(16)
      |> case do
        {amount_int, ""} ->
          amount_int
          |> Decimal.new()
          |> Decimal.div(Decimal.new(10) |> Decimal.power(decimals))
          |> Decimal.to_string()

        _ ->
          "0"
      end
    rescue
      _ -> "0"
    end
  end

  defp add_address_labels(event) do
    # Add human-readable labels for known addresses
    labels = %{}

    # Would query address registry in production
    # labels = AddressRegistry.get_labels([event.from_address, event.to_address])

    Map.put(event, :address_labels, labels)
  end

  defp add_nft_metadata(event) do
    # In production, would fetch NFT metadata from IPFS/HTTP
    nft_metadata = %{
      name: "Token #{event.token_id}",
      description: "NFT Token",
      image: nil
    }

    Map.put(event, :nft_metadata, nft_metadata)
  end

  defp add_block_analysis(event) do
    # Add block-level analysis
    analysis = %{
      is_high_activity: event.transaction_count > 100,
      block_size_category: categorize_block_size(event.transaction_count)
    }

    Map.put(event, :block_analysis, analysis)
  end

  defp add_transaction_metadata(event) do
    # Extract transaction details from the event
    case event do
      %{"params" => %{"result" => tx_data}} ->
        Map.merge(event, %{
          transaction_hash: Map.get(tx_data, "hash"),
          from_address: Map.get(tx_data, "from"),
          to_address: Map.get(tx_data, "to"),
          value: Map.get(tx_data, "value"),
          gas_limit: Map.get(tx_data, "gas"),
          gas_price: Map.get(tx_data, "gasPrice")
        })

      _ ->
        event
    end
  end

  defp add_gas_analysis(event) do
    case {Map.get(event, :gas_limit), Map.get(event, :gas_price)} do
      {gas_limit, gas_price} when is_binary(gas_limit) and is_binary(gas_price) ->
        try do
          gas_limit_int = String.to_integer(String.trim_leading(gas_limit, "0x"), 16)
          gas_price_int = String.to_integer(String.trim_leading(gas_price, "0x"), 16)

          max_fee = gas_limit_int * gas_price_int

          gas_analysis = %{
            gas_limit_int: gas_limit_int,
            gas_price_gwei: gas_price_int / 1_000_000_000,
            max_fee_eth: max_fee / 1_000_000_000_000_000_000,
            gas_tier: categorize_gas_price(gas_price_int)
          }

          Map.put(event, :gas_analysis, gas_analysis)
        rescue
          _ -> event
        end

      _ ->
        event
    end
  end

  defp extract_contract_addresses(event) do
    # Extract all contract addresses mentioned in the event
    addresses = []

    addresses =
      case Map.get(event, :token_address) do
        nil -> addresses
        addr -> [addr | addresses]
      end

    addresses =
      case Map.get(event, :contract_address) do
        nil -> addresses
        addr -> [addr | addresses]
      end

    addresses =
      case Map.get(event, :to_address) do
        nil -> addresses
        addr -> [addr | addresses]
      end

    Enum.uniq(addresses)
  end

  defp get_contract_metadata(address, chain) do
    # In production, would query ContractRegistry
    %{
      name: "Unknown Contract",
      verified: false,
      is_token: false,
      is_nft: false
    }
  end

  defp get_original_timestamp(event) do
    case event do
      %{"_livechain_meta" => %{"received_at" => timestamp}} ->
        timestamp

      _ ->
        nil
    end
  end

  defp categorize_block_size(tx_count) do
    cond do
      tx_count < 10 -> :small
      tx_count < 50 -> :medium
      tx_count < 200 -> :large
      true -> :mega
    end
  end

  defp categorize_gas_price(gas_price_wei) do
    gas_price_gwei = gas_price_wei / 1_000_000_000

    cond do
      gas_price_gwei < 10 -> :low
      gas_price_gwei < 30 -> :medium
      gas_price_gwei < 100 -> :high
      true -> :extreme
    end
  end
end
