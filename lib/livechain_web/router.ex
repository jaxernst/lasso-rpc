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

    # Strategy-specific endpoint (e.g., /rpc/cheapest/ethereum)
    post("/:strategy/:chain_id", RPCController, :rpc)

    # Generic endpoint for any configured chain (backward compatible)
    post("/:chain_id", RPCController, :rpc)
  end
end
