defmodule Livechain.EventProcessing.EventClassifier do
  @moduledoc """
  Classifies blockchain events based on their content and structure.

  This module analyzes raw blockchain messages and determines their event type,
  which is used for routing, processing, and enrichment decisions.
  """

  require Logger

  # ERC-20 Transfer event signature: Transfer(address,address,uint256)
  @erc20_transfer_signature "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

  # ERC-721 Transfer event signature: Transfer(address,address,uint256)
  @erc721_transfer_signature "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

  # ERC-1155 TransferSingle event signature
  @erc1155_transfer_single_signature "0xc3d58168c5ae7397731d063d5bbf3d657854427343f4c083240f7aacaa2d0f62"

  @doc """
  Classifies a blockchain event based on its content.

  Returns an atom representing the event type:
  - :block - New block events
  - :transaction - Transaction events
  - :erc20_transfer - ERC-20 token transfers
  - :native_transfer - Native ETH/MATIC transfers
  - :nft_transfer - NFT transfers (ERC-721/ERC-1155)
  - :contract_call - Contract interaction
  - :unknown - Unclassified events
  """
  def classify(event) when is_map(event) do
    cond do
      is_block_event?(event) ->
        :block

      is_transaction_event?(event) ->
        :transaction

      is_erc20_transfer?(event) ->
        :erc20_transfer

      is_native_transfer?(event) ->
        :native_transfer

      is_nft_transfer?(event) ->
        :nft_transfer

      is_contract_call?(event) ->
        :contract_call

      true ->
        classify_by_content(event)
    end
  end

  def classify(_event), do: :unknown

  # Private classification functions

  defp is_block_event?(event) do
    # Check for block-like structure
    case event do
      %{"result" => %{"hash" => hash, "number" => number}} when is_binary(hash) and is_binary(number) ->
        String.starts_with?(hash, "0x") and String.starts_with?(number, "0x")

      %{"params" => %{"result" => %{"hash" => hash, "number" => number}}} when is_binary(hash) and is_binary(number) ->
        String.starts_with?(hash, "0x") and String.starts_with?(number, "0x")

      _ ->
        false
    end
  end

  defp is_transaction_event?(event) do
    # Check for transaction-like structure
    case event do
      %{"result" => %{"transactionHash" => tx_hash}} when is_binary(tx_hash) ->
        String.starts_with?(tx_hash, "0x")

      %{"params" => %{"result" => tx_hash}} when is_binary(tx_hash) ->
        String.starts_with?(tx_hash, "0x") and String.length(tx_hash) == 66

      _ ->
        false
    end
  end

  defp is_erc20_transfer?(event) do
    case get_log_topics(event) do
      [topic0 | _] when topic0 == @erc20_transfer_signature ->
        # Additional check: ERC-20 transfers have exactly 3 topics (event signature + from + to)
        case get_log_topics(event) do
          [_, _, _] -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  defp is_native_transfer?(event) do
    # Native transfers in transaction logs have value but no topics/data
    case event do
      %{"params" => %{"result" => %{"value" => value}}} when is_binary(value) ->
        # Has value but no logs/topics indicates native transfer
        not has_contract_logs?(event) and value != "0x0"

      _ ->
        false
    end
  end

  defp is_nft_transfer?(event) do
    case get_log_topics(event) do
      [topic0 | _] when topic0 in [@erc721_transfer_signature, @erc1155_transfer_single_signature] ->
        # Additional checks to distinguish from ERC-20
        case get_log_topics(event) do
          # ERC-721: Transfer(address,address,uint256) with 4 topics (including token ID)
          [_, _, _, _] -> true
          # ERC-1155: TransferSingle signature
          [@erc1155_transfer_single_signature | _] -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  defp is_contract_call?(event) do
    # Has transaction data or logs indicating contract interaction
    case event do
      %{"params" => %{"result" => %{"input" => input}}} when is_binary(input) ->
        String.length(input) > 10  # More than just "0x" + 4-byte selector

      _ ->
        has_contract_logs?(event)
    end
  end

  defp classify_by_content(event) do
    # Fallback classification based on structure
    cond do
      has_contract_logs?(event) ->
        :contract_call

      Map.has_key?(event, "result") or Map.has_key?(event, "params") ->
        :blockchain_event

      true ->
        :unknown
    end
  end

  # Helper functions

  defp get_log_topics(event) do
    case event do
      %{"params" => %{"result" => %{"topics" => topics}}} when is_list(topics) ->
        topics

      %{"result" => %{"topics" => topics}} when is_list(topics) ->
        topics

      _ ->
        []
    end
  end

  defp has_contract_logs?(event) do
    case event do
      %{"params" => %{"result" => %{"logs" => logs}}} when is_list(logs) and length(logs) > 0 ->
        true

      %{"result" => %{"logs" => logs}} when is_list(logs) and length(logs) > 0 ->
        true

      _ ->
        false
    end
  end

  @doc """
  Gets additional classification metadata for an event.
  """
  def get_metadata(event, event_type) do
    base_metadata = %{
      type: event_type,
      timestamp: System.system_time(:millisecond),
      chain: extract_chain(event)
    }

    case event_type do
      :erc20_transfer ->
        Map.merge(base_metadata, extract_erc20_metadata(event))

      :nft_transfer ->
        Map.merge(base_metadata, extract_nft_metadata(event))

      :block ->
        Map.merge(base_metadata, extract_block_metadata(event))

      _ ->
        base_metadata
    end
  end

  defp extract_chain(event) do
    # Try to extract chain from livechain metadata
    case event do
      %{"_livechain_meta" => %{"chain_name" => chain}} ->
        chain

      _ ->
        "unknown"
    end
  end

  defp extract_erc20_metadata(event) do
    topics = get_log_topics(event)

    case topics do
      [_signature, from_topic, to_topic] ->
        %{
          from: "0x" <> String.slice(from_topic, -40..-1),
          to: "0x" <> String.slice(to_topic, -40..-1),
          token_address: get_log_address(event),
          amount: get_log_data(event)
        }

      _ ->
        %{}
    end
  end

  defp extract_nft_metadata(event) do
    topics = get_log_topics(event)

    case topics do
      [_signature, from_topic, to_topic, token_id_topic] ->
        %{
          from: "0x" <> String.slice(from_topic, -40..-1),
          to: "0x" <> String.slice(to_topic, -40..-1),
          contract_address: get_log_address(event),
          token_id: token_id_topic
        }

      _ ->
        %{}
    end
  end

  defp extract_block_metadata(event) do
    case event do
      %{"result" => block_data} ->
        %{
          block_number: Map.get(block_data, "number"),
          block_hash: Map.get(block_data, "hash"),
          timestamp: Map.get(block_data, "timestamp"),
          transaction_count: get_transaction_count(block_data)
        }

      %{"params" => %{"result" => block_data}} ->
        %{
          block_number: Map.get(block_data, "number"),
          block_hash: Map.get(block_data, "hash"),
          timestamp: Map.get(block_data, "timestamp"),
          transaction_count: get_transaction_count(block_data)
        }

      _ ->
        %{}
    end
  end

  defp get_log_address(event) do
    case event do
      %{"params" => %{"result" => %{"address" => address}}} ->
        address

      %{"result" => %{"address" => address}} ->
        address

      _ ->
        nil
    end
  end

  defp get_log_data(event) do
    case event do
      %{"params" => %{"result" => %{"data" => data}}} ->
        data

      %{"result" => %{"data" => data}} ->
        data

      _ ->
        nil
    end
  end

  defp get_transaction_count(block_data) do
    case Map.get(block_data, "transactions") do
      transactions when is_list(transactions) ->
        length(transactions)

      _ ->
        0
    end
  end
end
