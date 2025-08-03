defmodule LivechainWeb.Router do
  use LivechainWeb, :router

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

  scope "/", LivechainWeb do
    pipe_through(:browser)

    live("/", OrchestrationLive)
    live("/orchestration", OrchestrationLive)
    live("/network", NetworkLive)
    live("/table", TableLive)
    live("/minimal_state", MinimalStateLive)
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
    get("/chains/:chain_id/blocks/latest", BlockController, :latest)
    get("/chains/:chain_id/blocks/:number", BlockController, :show)

    # Analytics endpoints
    scope "/analytics", as: :analytics do
      get("/overview", AnalyticsController, :overview)
      get("/tokens/volume", AnalyticsController, :token_volume)
      get("/nft/activity", AnalyticsController, :nft_activity)
      get("/chains/comparison", AnalyticsController, :chain_comparison)
      get("/real-time/events", AnalyticsController, :realtime_events)
      get("/performance", AnalyticsController, :performance_metrics)
    end
  end

  # HTTP ethereum JSON-RPC endpoints for onchain app clients
  scope "/rpc", LivechainWeb do
    pipe_through(:api)

    post("/ethereum", RPCController, :ethereum)
    post("/arbitrum", RPCController, :arbitrum)
    post("/polygon", RPCController, :polygon)
    post("/bsc", RPCController, :bsc)
  end

  # WebSocket endpoint for real-time subscriptions
  scope "/ws", LivechainWeb do
    get("/:chain_id", WebSocketController, :connect)
  end
end
