defmodule RateLimiterWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :rate_limiter

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug RateLimiterWeb.Router
end
