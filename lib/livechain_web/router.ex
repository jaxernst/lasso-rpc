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

  # Admin API endpoints
  scope "/api/admin", LivechainWeb.Admin do
    pipe_through(:api)

    # Chain configuration management
    resources("/chains", ChainController, except: [:new, :edit]) do
      post("/test", ChainController, :test_connectivity, as: :test)
    end

    # Chain validation endpoint
    post("/chains/validate", ChainController, :validate)
    
    # Backup management
    get("/chains/backups", ChainController, :list_backups)
    post("/chains/backup", ChainController, :create_backup)
  end

  # HTTP JSON-RPC endpoints with enhanced logging
  scope "/rpc", LivechainWeb do
    pipe_through(:api_with_logging)

    # Strategy-specific endpoints for different routing approaches
    # Use fastest provider based on latency
    post("/fastest/:chain_id", RPCController, :rpc_fastest)
    # Use cheapest provider (default to free providers)
    post("/cheapest/:chain_id", RPCController, :rpc_cheapest)
    # Use priority-ordered providers
    post("/priority/:chain_id", RPCController, :rpc_priority)
    # Round-robin provider selection
    post("/round-robin/:chain_id", RPCController, :rpc_round_robin)

    # Provider override endpoints - directly target specific providers
    post("/provider/:provider_id/:chain_id", RPCController, :rpc_provider_override)
    # Alternative format
    post("/:chain_id/:provider_id", RPCController, :rpc_provider_override)
  end
end