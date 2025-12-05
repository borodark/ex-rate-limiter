# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.

import Config

# General application configuration
config :rate_limiter,
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :rate_limiter, RateLimiterWeb.Endpoint,
  url: [host: "0.0.0.0"],
  adapter: Bandit.PhoenixAdapter,
  http: [
    # Optimized for Extreme Load (44 CPUs / 256GB RAM)
    # Target: 25,000+ concurrent connections

    # HTTP protocol optimizations
    http_1_options: [
      enabled: true,
      # Unlimited requests per connection
      max_requests: 0,
      # Disable for performance
      clear_process_dict: false,
      # Reduce logging overhead
      log_unknown_messages: false
    ],
    http_options: [
      compress: true,
      # Disable for performance
      log_protocol_errors: false,
      # Disable for performance
      log_client_closures: false
    ],

    # ThousandIsland configuration for extreme load
    thousand_island_options: [
      # Acceptor configuration
      # High concurrency
      num_acceptors: 44,
      # Max per acceptor
      num_connections: 16_384,

      # Retry and timeout settings
      max_connections_retry_wait: 1000,
      max_connections_retry_count: 5,
      read_timeout: 60_000,
      shutdown_timeout: 15_000,

      # TCP transport options for extreme load
      transport_options: [
        # Latency optimization
        # Disable Nagle's algorithm
        nodelay: true,

        # Connection management
        # TCP keepalive
        keepalive: true,
        # Pending connection queue (extreme load)
        backlog: 4096,

        # Buffer sizes (512KB each for extreme load)
        sndbuf: 2097152,
        recbuf: 2097152,
        buffer: 2097152,

        # Timeouts
        send_timeout: 30_000,
        send_timeout_close: true,

        # Data delivery mode
        # Passive mode for high load
        active: false,
        packet: :raw,
        mode: :binary,

        # Performance tuning
        delay_send: false,
        reuseaddr: true
      ]
    ]
  ],
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
