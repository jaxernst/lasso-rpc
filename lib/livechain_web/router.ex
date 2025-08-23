defmodule LivechainWeb.Router do
  use LivechainWeb, :router
  require Logger

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {LivechainWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  # Debug pipeline for RPC endpoints
  pipeline :api_with_logging do
    plug(Plug.Logger, log: :info)
    plug(:accepts, ["json"])
  end

  scope "/", LivechainWeb do
    pipe_through(:browser)

    live("/", Dashboard)
    live("/orchestration", OrchestrationLive)
    live("/network", NetworkLive)
    live("/table", TableLive)
  end

  scope "/api", LivechainWeb do
    pipe_through(:api)

    # Health and status endpoints
    get("/health", HealthController, :health)
    get("/status", StatusController, :status)
    get("/metrics", MetricsController, :metrics)

    # Chain endpoints
    get("/chains", ChainController, :index)
    get("/chains/:chain_id/status", ChainController, :status)
  end

  # HTTP JSON-RPC endpoints with enhanced logging
  scope "/rpc", LivechainWeb do
    pipe_through(:api_with_logging)

    # Strategy-specific endpoints for different routing approaches
    post("/fastest/:chain_id", RPCController, :rpc_fastest)       # Use fastest provider based on latency
    post("/cheapest/:chain_id", RPCController, :rpc_cheapest)     # Use cheapest provider (if cost data available)
    post("/priority/:chain_id", RPCController, :rpc_priority)     # Use priority-ordered providers
    post("/leaderboard/:chain_id", RPCController, :rpc_leaderboard) # Use leaderboard-based selection (default)
    post("/round-robin/:chain_id", RPCController, :rpc_round_robin) # Round-robin provider selection
    
    # Provider override endpoints - directly target specific providers
    post("/provider/:provider_id/:chain_id", RPCController, :rpc_provider_override)
    post("/:chain_id/:provider_id", RPCController, :rpc_provider_override)  # Alternative format
    
    # Fallback tolerance endpoints
    post("/no-failover/:chain_id", RPCController, :rpc_no_failover) # Disable failover for testing
    post("/aggressive/:chain_id", RPCController, :rpc_aggressive)    # More aggressive failover settings
    
    # Development/debugging endpoints
    post("/debug/:chain_id", RPCController, :rpc_debug)          # Enhanced logging and debugging
    post("/benchmark/:chain_id", RPCController, :rpc_benchmark)  # Force benchmarking mode
    
    # Legacy endpoints for backward compatibility
    post("/:strategy/:chain_id", RPCController, :rpc)
    post("/:chain_id", RPCController, :rpc)
  end
end
