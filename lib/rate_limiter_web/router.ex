defmodule RateLimiterWeb.Router do
  use RateLimiterWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api/v1", RateLimiterWeb do
    pipe_through :api

    post "/ratelimit", RateLimitController, :check
    post "/configure", RateLimitController, :configure
    post "/configure-client", RateLimitController, :configure_client
    get "/client-config/:client_id", RateLimitController, :get_client_config
    delete "/client-config/:client_id", RateLimitController, :reset_client_config
  end
end
