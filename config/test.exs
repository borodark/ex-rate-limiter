import Config

# We don't run a server during test
config :rate_limiter, RateLimiterWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "G7tmsM6tOOVUzoTI933yCzSHKp7CrX6/frT9jA4ZRA/76LAL8j1K9t4QDGh2TBZa",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
