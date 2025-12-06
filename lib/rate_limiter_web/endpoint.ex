defmodule RateLimiterWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :rate_limiter

  # Session configuration for LiveDashboard
  @session_options [
    store: :cookie,
    key: "_rate_limiter_key",
    signing_salt: "rLtM8xPqY2vK9wN5jC3sH7gF6dB4nA1z",
    same_site: "Lax"
  ]

  # LiveDashboard socket for live updates
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Session, @session_options

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug RateLimiterWeb.Router
end
