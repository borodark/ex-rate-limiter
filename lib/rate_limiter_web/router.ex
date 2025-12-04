defmodule RateLimiterWeb.Router do
  use RateLimiterWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api/v1", RateLimiterWeb do
    pipe_through :api

    post "/ratelimit", RateLimitController, :check
    post "/configure", RateLimitController, :configure
  end
end
