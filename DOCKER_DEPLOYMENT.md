# Docker Deployment Guide

This guide explains how to deploy the Rate Limiter service using Docker and Docker Compose.

## Quick Start

### Using Docker Compose (Recommended)

```bash
# Build and start the container
docker compose up --build

# Or run in detached mode
docker compose up -d --build

# View logs
docker compose logs -f

# Stop the container
docker compose down
```

The service will be available at `http://localhost:4000`

### Using Docker Directly

```bash
# Build the image
docker build -t rate-limiter:latest .

# Run the container
docker run -d \
  --name rate-limiter \
  -p 4000:4000 \
  -e PHX_SERVER=true \
  -e SECRET_KEY_BASE=your_secret_key_base_here \
  rate-limiter:latest

# View logs
docker logs -f rate-limiter

# Stop and remove
docker stop rate-limiter
docker rm rate-limiter
```

## Configuration

### Environment Variables

The following environment variables can be configured in `compose.yaml` or passed via `-e` flags:

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | 4000 | HTTP port to listen on |
| `MIX_ENV` | prod | Elixir environment (prod/dev/test) |
| `PHX_SERVER` | true | Enable Phoenix HTTP server (required) |
| `SECRET_KEY_BASE` | (required) | Secret key for Phoenix sessions/cookies |
| `RATE_LIMIT_WINDOW_SECONDS` | 60 | Default rate limit time window |
| `RATE_LIMIT_REQUESTS_PER_WINDOW` | 100 | Default requests allowed per window |
| `PHX_HOST` | example.com | Hostname for URL generation |

### Generating SECRET_KEY_BASE

**Important:** Always generate a unique secret key for production!

```bash
# Generate a secret key using mix
docker run --rm rate-limiter:latest /app/bin/rate_limiter eval "IO.puts(:crypto.strong_rand_bytes(64) |> Base.encode64())"

# Or if you have Elixir installed locally
mix phx.gen.secret
```

Update the `SECRET_KEY_BASE` value in `compose.yaml` before deploying to production.

## Docker Compose Configuration

The `compose.yaml` file includes:

### Service Configuration
- **Image**: `rate-limiter:latest`
- **Port Mapping**: Host 4000 → Container 4000
- **Restart Policy**: `unless-stopped` (automatic restart on failure)

### Health Check
The container includes a health check that:
- Runs every 30 seconds
- Checks the `/api/v1/health` endpoint
- Has a 3-second timeout
- Allows 10 seconds for startup
- Retries 3 times before marking unhealthy

Check health status:
```bash
docker ps
docker inspect rate-limiter | grep Health -A 10
```

### Resource Limits
Default limits (can be adjusted in `compose.yaml`):
- **CPU**: 1 core max, 0.25 core reserved
- **Memory**: 512MB max, 128MB reserved

### Logging
- **Driver**: json-file
- **Max Size**: 10MB per file
- **Max Files**: 3 (rotates after 30MB total)

View logs:
```bash
docker compose logs -f
docker compose logs --tail=100
```

## Testing the Deployment

### 1. Verify Container is Running
```bash
docker compose ps
```

Expected output:
```
NAME           IMAGE                 STATUS         PORTS
rate-limiter   rate-limiter:latest   Up (healthy)   0.0.0.0:4000->4000/tcp
```

### 2. Check Health Endpoint
```bash
curl http://localhost:4000/api/v1/health
```

Expected: `{"status":"ok"}`

### 3. Test Rate Limiting
```bash
# Make a rate limit check request
curl -X POST http://localhost:4000/api/v1/ratelimit \
  -H "Content-Type: application/json" \
  -d '{"client_id":"user123","resource":"api"}'
```

Expected response:
```json
{"allowed":true,"remaining":99}
```

### 4. Run Load Test
```bash
# Send 100 requests to the same client
for i in {1..100}; do
  curl -s -X POST http://localhost:4000/api/v1/ratelimit \
    -H "Content-Type: application/json" \
    -d '{"client_id":"loadtest","resource":"api"}' | grep -o '"allowed":[^,]*'
done | sort | uniq -c
```

Expected output (with default 100 req/60s limit):
```
100 "allowed":true    # First 100 requests allowed
```

## Production Deployment Checklist

- [ ] Generate unique `SECRET_KEY_BASE`
- [ ] Update `SECRET_KEY_BASE` in compose.yaml or environment
- [ ] Review and adjust resource limits (CPU/memory)
- [ ] Configure rate limit defaults for your use case
- [ ] Set up log collection/monitoring
- [ ] Configure reverse proxy (nginx/traefik) if needed
- [ ] Set up SSL/TLS certificates
- [ ] Test health check endpoint
- [ ] Configure backup/restore procedures (if adding persistence)
- [ ] Set up container restart policies
- [ ] Configure firewall rules
- [ ] Set up monitoring/alerting

## Multi-Stage Build Details

The Dockerfile uses a multi-stage build for optimization:

### Build Stage (hexpm/elixir:1.18.3-erlang-27.2.7.2-alpine-3.21.2)
1. Installs build dependencies (gcc, git, etc.)
2. Installs Elixir dependencies
3. Compiles the application
4. Creates a production release

### Runtime Stage (alpine:3.21.2)
1. Minimal Alpine Linux base (~5MB)
2. Only runtime dependencies (ncurses, libstdc++, openssl)
3. Runs as non-root user (`app:app`)
4. Contains only the compiled release (~50MB total)

Benefits:
- **Small image size**: ~50MB (vs ~500MB with build tools)
- **Security**: Minimal attack surface, non-root user
- **Performance**: Optimized Erlang release with ahead-of-time compilation

## Networking

### Default Network
The compose file creates a custom bridge network: `rate-limiter-network`

### Connecting Other Containers
To connect other services to the rate limiter:

```yaml
services:
  my-app:
    image: my-app:latest
    networks:
      - rate-limiter-network
    environment:
      - RATE_LIMITER_URL=http://rate-limiter:4000

networks:
  rate-limiter-network:
    external: true
```

### Port Binding
By default, the service binds to `0.0.0.0:4000` (all interfaces).

To bind to localhost only:
```yaml
ports:
  - "127.0.0.1:4000:4000"
```

## Troubleshooting

### Container Won't Start

Check logs:
```bash
docker compose logs rate-limiter
```

Common issues:
1. **PORT already in use**: Change port mapping in compose.yaml
2. **SECRET_KEY_BASE missing**: Ensure it's set in environment
3. **Permission errors**: Check file ownership in container

### Health Check Failing

```bash
# Check if port is accessible
curl -v http://localhost:4000/api/v1/health

# Check container logs
docker compose logs rate-limiter

# Exec into container
docker compose exec rate-limiter sh
wget -O- http://localhost:4000/api/v1/health
```

### High Memory Usage

Adjust memory limits in compose.yaml:
```yaml
deploy:
  resources:
    limits:
      memory: 256M  # Reduce if needed
```

### Viewing Runtime Configuration

```bash
# Exec into running container
docker compose exec rate-limiter sh

# Check environment variables
env | grep -E 'PORT|RATE_LIMIT|SECRET'

# Check Erlang VM info
/app/bin/rate_limiter remote
:observer.start()  # Opens observer (requires X11)
```

## Updating the Service

```bash
# Pull latest code
git pull

# Rebuild and restart
docker compose down
docker compose up -d --build

# Or with zero-downtime:
docker compose build
docker compose up -d --no-deps rate-limiter
```

## Scaling (Future)

For horizontal scaling across multiple hosts:

1. Add distributed Erlang clustering
2. Use Redis for shared state
3. Configure load balancer (nginx/HAProxy)
4. Deploy with orchestration (Docker Swarm/Kubernetes)

Current version: Single-node, in-memory rate limiting

## Monitoring

### Container Metrics
```bash
docker stats rate-limiter
```

### Application Metrics
Future additions could include:
- Prometheus metrics endpoint
- Telemetry integration
- APM tools (New Relic, DataDog)
- Custom logging integration

## Backup and Persistence

Current implementation stores rate limit data in memory only.

For persistence across restarts:
1. Mount volume for data storage
2. Implement state snapshot/restore
3. Use Redis/PostgreSQL backend
4. Configure ETS disk persistence

## Security Considerations

1. **Run as non-root**: Container uses `app:app` user (UID 1000)
2. **Minimal base image**: Alpine Linux reduces attack surface
3. **No build tools**: Runtime image has no compilers/build tools
4. **Secret management**: Use Docker secrets or vault for `SECRET_KEY_BASE`
5. **Network isolation**: Custom bridge network isolates from default
6. **Resource limits**: CPU/memory limits prevent DoS
7. **Read-only filesystem**: Consider adding `read_only: true` to compose file

## Performance Tuning

### Erlang VM Options
Add to Dockerfile or compose environment:
```yaml
environment:
  - ERL_MAX_PORTS=65536
  - ERL_MAX_ETS_TABLES=10000
```

### Kernel Parameters (host)
For high-throughput scenarios:
```bash
sudo sysctl -w net.core.somaxconn=4096
sudo sysctl -w net.ipv4.tcp_max_syn_backlog=4096
```

## Further Reading

- [Elixir Releases](https://hexdocs.pm/mix/Mix.Tasks.Release.html)
- [Phoenix Deployment](https://hexdocs.pm/phoenix/deployment.html)
- [Docker Best Practices](https://docs.docker.com/develop/dev-best-practices/)
- [Alpine Linux Security](https://alpinelinux.org/about/)
