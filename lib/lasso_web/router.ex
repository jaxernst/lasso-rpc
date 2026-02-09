defmodule LassoWeb.Router do
  use LassoWeb, :router
  require Logger

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {LassoWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  # Profile-aware RPC pipeline (resolves profile from URL or defaults to "default")
  pipeline :api_with_profile do
    plug(:accepts, ["json"])
    plug(LassoWeb.Plugs.ProfileResolverPlug)
    plug(LassoWeb.Plugs.ObservabilityPlug)
  end

  scope "/", LassoWeb do
    pipe_through(:browser)

    live("/", HomeLive)
    live("/dashboard", Dashboard, :index)
    live("/dashboard/:profile", Dashboard, :show)
  end

  scope "/api", LassoWeb do
    pipe_through(:api)

    # Health and status endpoints
    get("/health", HealthController, :health)
    get("/metrics/:chain", MetricsController, :metrics)

    # Chain endpoints
    get("/chains", ChainController, :index)
  end

  # HTTP JSON-RPC endpoints
  scope "/rpc", LassoWeb do
    pipe_through(:api_with_profile)

    # Legacy endpoints (no profile slug - uses "default" profile)
    # Strategy-specific endpoints
    post("/fastest/:chain_id", RPCController, :rpc_fastest)
    post("/round-robin/:chain_id", RPCController, :rpc_round_robin)
    post("/latency-weighted/:chain_id", RPCController, :rpc_latency_weighted)

    # Provider override endpoints
    post("/provider/:provider_id/:chain_id", RPCController, :rpc_provider_override)
    post("/:chain_id/:provider_id", RPCController, :rpc_provider_override)

    # Base endpoint (catch-all for legacy routes)
    post("/:chain_id", RPCController, :rpc_base)

    # Profile-aware endpoints (explicit profile namespace in URL)
    scope "/profile/:profile" do
      # Strategy-specific endpoints
      post("/fastest/:chain_id", RPCController, :rpc_fastest)
      post("/round-robin/:chain_id", RPCController, :rpc_round_robin)
      post("/latency-weighted/:chain_id", RPCController, :rpc_latency_weighted)

      # Provider override endpoints
      post("/provider/:provider_id/:chain_id", RPCController, :rpc_provider_override)
      post("/:chain_id/:provider_id", RPCController, :rpc_provider_override)

      # Base endpoint (catch-all for profile-aware routes)
      post("/:chain_id", RPCController, :rpc_base)
    end
  end
end
