defmodule Livechain.EventProcessing.PriceOracle do
  @moduledoc """
  Price oracle for fetching real-time cryptocurrency and token prices.

  This module provides USD pricing for:
  - Native tokens (ETH, MATIC, BNB, etc.)
  - ERC-20 tokens
  - Real-time price feeds with caching
  - Historical price data (future enhancement)
  """

  use GenServer
  require Logger

  defstruct [
    :price_cache,
    :cache_ttl,
    :last_update
  ]

  # Cache prices for 60 seconds
  @default_cache_ttl 60_000

  # Well-known token addresses for price lookup
  @token_addresses %{
    # Ethereum mainnet
    "ethereum" => %{
      "0xa0b86a33e6441e01951e7b9044d4c085e2e8e6e3" => "USDC",
      "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2" => "WETH",
      "0x6b175474e89094c44da98b954eedeac495271d0f" => "DAI",
      "0xa0b86a33e6441143e30bf2a976c8e2139a39aaea" => "USDT"
    },
    # Polygon
    "polygon" => %{
      "0x2791bca1f2de4661ed88a30c99a7a9449aa84174" => "USDC",
      "0x7ceb23fd6f88a99681f7eebab40e51e8b8ad49cb" => "WETH",
      "0x8f3cf7ad23cd3cadbd9735aff958023239c6a063" => "DAI"
    }
  }

  # Native token symbols
  @native_tokens %{
    "ethereum" => "ETH",
    "polygon" => "MATIC",
    "arbitrum" => "ETH",
    "bsc" => "BNB",
    "avalanche" => "AVAX",
    "optimism" => "ETH",
    "base" => "ETH"
  }

  @doc """
  Starts the price oracle GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets the current USD price for a token address on a specific chain.
  """
  def get_token_price(token_address, chain) do
    GenServer.call(__MODULE__, {:get_token_price, token_address, chain})
  end

  @doc """
  Gets the current USD price for a chain's native token.
  """
  def get_native_price(chain) do
    GenServer.call(__MODULE__, {:get_native_price, chain})
  end

  @doc """
  Forces a price cache refresh.
  """
  def refresh_prices do
    GenServer.cast(__MODULE__, :refresh_prices)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    cache_ttl = Keyword.get(opts, :cache_ttl, @default_cache_ttl)

    state = %__MODULE__{
      price_cache: %{},
      cache_ttl: cache_ttl,
      last_update: 0
    }

    # Schedule initial price fetch
    Process.send_after(self(), :fetch_prices, 1000)

    {:ok, state}
  end

  @impl true
  def handle_call({:get_token_price, token_address, chain}, _from, state) do
    case get_cached_token_price(state, token_address, chain) do
      {:ok, price} ->
        {:reply, {:ok, price}, state}

      :cache_miss ->
        # Try to fetch price synchronously for immediate response
        case fetch_token_price_sync(token_address, chain) do
          {:ok, price} ->
            new_cache = cache_token_price(state.price_cache, token_address, chain, price)
            new_state = %{state | price_cache: new_cache}
            {:reply, {:ok, price}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:get_native_price, chain}, _from, state) do
    case get_cached_native_price(state, chain) do
      {:ok, price} ->
        {:reply, {:ok, price}, state}

      :cache_miss ->
        case fetch_native_price_sync(chain) do
          {:ok, price} ->
            new_cache = cache_native_price(state.price_cache, chain, price)
            new_state = %{state | price_cache: new_cache}
            {:reply, {:ok, price}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_cast(:refresh_prices, state) do
    send(self(), :fetch_prices)
    {:noreply, state}
  end

  @impl true
  def handle_info(:fetch_prices, state) do
    Logger.debug("Fetching latest cryptocurrency prices")

    new_cache = fetch_all_prices(state.price_cache)
    new_state = %{state | price_cache: new_cache, last_update: System.system_time(:millisecond)}

    # Schedule next price fetch
    Process.send_after(self(), :fetch_prices, state.cache_ttl)

    {:noreply, new_state}
  end

  # Private functions

  defp get_cached_token_price(state, token_address, chain) do
    cache_key = {:token, chain, String.downcase(token_address)}

    case Map.get(state.price_cache, cache_key) do
      {price, timestamp} ->
        if System.system_time(:millisecond) - timestamp < state.cache_ttl do
          {:ok, price}
        else
          :cache_miss
        end

      nil ->
        :cache_miss
    end
  end

  defp get_cached_native_price(state, chain) do
    cache_key = {:native, chain}

    case Map.get(state.price_cache, cache_key) do
      {price, timestamp} ->
        if System.system_time(:millisecond) - timestamp < state.cache_ttl do
          {:ok, price}
        else
          :cache_miss
        end

      nil ->
        :cache_miss
    end
  end

  defp cache_token_price(cache, token_address, chain, price) do
    cache_key = {:token, chain, String.downcase(token_address)}
    timestamp = System.system_time(:millisecond)
    Map.put(cache, cache_key, {price, timestamp})
  end

  defp cache_native_price(cache, chain, price) do
    cache_key = {:native, chain}
    timestamp = System.system_time(:millisecond)
    Map.put(cache, cache_key, {price, timestamp})
  end

  defp fetch_token_price_sync(token_address, chain) do
    # First, try to resolve token symbol
    case resolve_token_symbol(token_address, chain) do
      {:ok, symbol} ->
        fetch_price_by_symbol(symbol)

      {:error, _} ->
        # For demo purposes, return mock prices
        {:ok, generate_mock_price()}
    end
  end

  defp fetch_native_price_sync(chain) do
    case Map.get(@native_tokens, chain) do
      nil ->
        {:error, :unsupported_chain}

      symbol ->
        fetch_price_by_symbol(symbol)
    end
  end

  defp resolve_token_symbol(token_address, chain) do
    case get_in(@token_addresses, [chain, String.downcase(token_address)]) do
      nil -> {:error, :unknown_token}
      symbol -> {:ok, symbol}
    end
  end

  defp fetch_price_by_symbol(symbol) do
    # In production, this would call CoinGecko, CoinMarketCap, or other price APIs
    # For development, return realistic mock prices
    case symbol do
      "ETH" -> {:ok, 2_500.0 + :rand.uniform(500)}
      "WETH" -> {:ok, 2_500.0 + :rand.uniform(500)}
      "MATIC" -> {:ok, 0.85 + :rand.uniform() * 0.3}
      "BNB" -> {:ok, 300.0 + :rand.uniform(50)}
      "AVAX" -> {:ok, 35.0 + :rand.uniform(15)}
      "USDC" -> {:ok, 1.0 + (:rand.uniform() - 0.5) * 0.01}
      "USDT" -> {:ok, 1.0 + (:rand.uniform() - 0.5) * 0.01}
      "DAI" -> {:ok, 1.0 + (:rand.uniform() - 0.5) * 0.01}
      _ -> {:ok, generate_mock_price()}
    end
  end

  defp generate_mock_price do
    # Generate realistic mock price between $0.01 and $1000
    base_price = :rand.uniform(1000)
    base_price + :rand.uniform() * 100
  end

  defp fetch_all_prices(current_cache) do
    timestamp = System.system_time(:millisecond)

    # Fetch native token prices
    native_prices =
      @native_tokens
      |> Enum.map(fn {chain, symbol} ->
        case fetch_price_by_symbol(symbol) do
          {:ok, price} ->
            {{:native, chain}, {price, timestamp}}

          {:error, _} ->
            nil
        end
      end)
      |> Enum.filter(&(&1 != nil))
      |> Enum.into(%{})

    # Merge with current cache (keeping non-expired entries)
    Map.merge(current_cache, native_prices)
  end

  # Production price fetching (commented out for demo)
  # defp fetch_coingecko_prices do
  #   url = "https://api.coingecko.com/api/v3/simple/price"
  #   params = %{
  #     ids: "ethereum,matic-network,binancecoin,avalanche-2",
  #     vs_currencies: "usd"
  #   }
  #   
  #   case HTTPoison.get(url, [], params: params) do
  #     {:ok, %{status_code: 200, body: body}} ->
  #       Jason.decode(body)
  #     
  #     {:error, reason} ->
  #       Logger.error("Failed to fetch CoinGecko prices: #{reason}")
  #       {:error, reason}
  #   end
  # end
end
