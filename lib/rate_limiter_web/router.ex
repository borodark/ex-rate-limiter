defmodule RateLimiterWeb.Router do
  use RateLimiterWeb, :router

  import Phoenix.LiveDashboard.Router
  import Phoenix.LiveView.Router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {RateLimiterWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  # LiveDashboard for monitoring and metrics
  scope "/" do
    pipe_through :browser

    live_dashboard "/dashboard",
      metrics: RateLimiterWeb.Telemetry,
      additional_pages: [
        os_mon: Phoenix.LiveDashboard.OSMonPage
      ]
  end

  scope "/api/v1", RateLimiterWeb do
    pipe_through :api

    get "/health", RateLimitController, :health
    post "/ratelimit", RateLimitController, :check
    post "/configure", RateLimitController, :configure
    post "/configure-client", RateLimitController, :configure_client
    get "/client-config/:client_id", RateLimitController, :get_client_config
    delete "/client-config/:client_id", RateLimitController, :reset_client_config
  end
end
