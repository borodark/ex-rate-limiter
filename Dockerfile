# Build stage
FROM docker.io/hexpm/elixir:1.19.4-erlang-28.2-alpine-3.22.2 AS builder

# Install build dependencies
RUN apk add --no-cache build-base git

# Set working directory
WORKDIR /app

# Install hex and rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Set build environment
ENV MIX_ENV=prod

# Copy dependency files
COPY mix.exs mix.lock ./

# Install dependencies
RUN mix deps.get --only prod && \
    mix deps.compile

# Copy application code
COPY config config
COPY lib lib

# Compile the application
RUN mix compile

# Build release
RUN mix release

# Runtime stage
FROM docker.io/alpine:3.22.2

# Install runtime dependencies
RUN apk add --no-cache \
    ncurses-libs \
    libstdc++ \
    libgcc \
    openssl

# Create app user
RUN addgroup -g 1000 app && \
    adduser -D -u 1000 -G app app

# Set working directory
WORKDIR /app

# Copy the release from build stage
COPY --from=builder --chown=app:app /app/_build/prod/rel/rate_limiter ./

# Switch to app user
USER app

# Expose port 4000
EXPOSE 4000

# Set environment variables
ENV HOME=/app
ENV MIX_ENV=prod
ENV PORT=4000
ENV PHX_SERVER=true

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:4000/api/v1/health || exit 1

# Start the application
CMD ["bin/rate_limiter", "start"]
