# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.

import Config

# General application configuration
config :rate_limiter,
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :rate_limiter, RateLimiterWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: RateLimiterWeb.ErrorJSON],
    layout: false
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
