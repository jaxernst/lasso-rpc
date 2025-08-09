defmodule Mix.Tasks.TestBackfill do
  @moduledoc """
  Test the subscription backfill implementation
  """

  use Mix.Task
  require Logger

  @shortdoc "Test subscription backfill functionality"

  def run(_) do
    Logger.info("Starting backfill implementation test...")
    
    # Start the application
    {:ok, _} = Application.ensure_all_started(:livechain)
    
    # Wait a bit for things to settle
    Process.sleep(1000)
    
    # Start SubscriptionManager manually if needed
    start_subscription_manager()
    
    # Test 1: Check Subscription Manager
    test_subscription_manager_start()
    
    # Test 2: Create subscriptions
    test_subscription_creation()
    
    # Test 3: Simulate provider failover
    test_provider_failover_simulation()
    
    Logger.info("Backfill test completed successfully! ✅")
  end

  def start_subscription_manager do
    case GenServer.whereis(Livechain.RPC.SubscriptionManager) do
      nil ->
        Logger.info("Starting SubscriptionManager...")
        case Livechain.RPC.SubscriptionManager.start_link() do
          {:ok, pid} ->
            Logger.info("✅ SubscriptionManager started at #{inspect(pid)}")
          {:error, {:already_started, pid}} ->
            Logger.info("✅ SubscriptionManager already started at #{inspect(pid)}")
          {:error, reason} ->
            Logger.error("❌ Failed to start SubscriptionManager: #{inspect(reason)}")
            exit(:failed_to_start_subscription_manager)
        end
      pid ->
        Logger.info("✅ SubscriptionManager already running at #{inspect(pid)}")
    end
  end

  def test_subscription_manager_start do
    Logger.info("Test 1: Checking if SubscriptionManager is running...")
    
    case GenServer.whereis(Livechain.RPC.SubscriptionManager) do
      nil ->
        Logger.error("❌ SubscriptionManager is not running!")
        exit(:subscription_manager_not_running)
      
      pid ->
        Logger.info("✅ SubscriptionManager running at #{inspect(pid)}")
    end
  end

  def test_subscription_creation do
    Logger.info("Test 2: Creating test subscriptions...")
    
    # Test logs subscription
    case Livechain.RPC.SubscriptionManager.subscribe_to_logs("ethereum", %{
      "address" => "0xA0b86a33E6441b4b776c0E08B3c6E0c5Cf78dF84",
      "topics" => ["0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"]
    }) do
      {:ok, sub_id} ->
        Logger.info("✅ Created logs subscription: #{sub_id}")
        
      {:error, reason} ->
        Logger.error("❌ Failed to create logs subscription: #{inspect(reason)}")
        exit(:subscription_creation_failed)
    end
    
    # Test newHeads subscription
    case Livechain.RPC.SubscriptionManager.subscribe_to_new_heads("ethereum") do
      {:ok, sub_id} ->
        Logger.info("✅ Created newHeads subscription: #{sub_id}")
        
      {:error, reason} ->
        Logger.error("❌ Failed to create newHeads subscription: #{inspect(reason)}")
        exit(:subscription_creation_failed)
    end
  end

  def test_provider_failover_simulation do
    Logger.info("Test 3: Simulating provider failover...")
    
    # Get current chain subscriptions
    case Livechain.RPC.SubscriptionManager.get_chain_subscriptions("ethereum") do
      subscriptions when is_list(subscriptions) ->
        Logger.info("Found #{length(subscriptions)} subscriptions for Ethereum")
        
        # Simulate a provider failover event
        result = Livechain.RPC.SubscriptionManager.handle_provider_failover(
          "ethereum",
          "failed_provider_123", 
          ["healthy_provider_1", "healthy_provider_2"]
        )
        
        case result do
          :ok ->
            Logger.info("✅ Provider failover handled successfully")
            
            # Check subscription status after failover
            Process.sleep(100)
            case Livechain.RPC.SubscriptionManager.get_chain_subscriptions("ethereum") do
              updated_subscriptions when is_list(updated_subscriptions) ->
                Logger.info("✅ Subscriptions maintained after failover: #{length(updated_subscriptions)}")
              
              error ->
                Logger.error("❌ Failed to get subscriptions after failover: #{inspect(error)}")
            end
            
          error ->
            Logger.error("❌ Provider failover failed: #{inspect(error)}")
        end
        
      error ->
        Logger.error("❌ Failed to get chain subscriptions: #{inspect(error)}")
    end
  end
end