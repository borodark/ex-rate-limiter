import Config

# For development, we disable any cache and enable
# debugging and code reloading.
config :rate_limiter, RateLimiterWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "IsEHio1xxGFq5Yl36flvy9ufDDzWtfntCjuv3yOyeWFx6y1syBACUXV2/9UUFOhM",
  live_view: [signing_salt: "GH6wPEW9gS-T-w1W"]

# Do not include metadata nor timestamps in development logs
config :logger, :console, format: "[$level] $message\n"

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

# Do not print debug messages in production
config :logger, level: :error
