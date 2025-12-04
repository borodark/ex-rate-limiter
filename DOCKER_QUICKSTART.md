# Docker Quick Start

Get the rate limiter running in a container in under 2 minutes.

## Prerequisites

- Docker and Docker Compose installed
- Port 4000 available

## Quick Deploy

```bash
# Start the service
docker compose up -d --build

# Verify it's running
curl http://localhost:4000/api/v1/health
# Expected: {"status":"ok"}

# Test rate limiting
curl -X POST http://localhost:4000/api/v1/ratelimit \
  -H "Content-Type: application/json" \
  -d '{"client_id":"test","resource":"api"}'
# Expected: {"allowed":true,"remaining":99}
```

## Common Commands

```bash
# View logs
docker compose logs -f

# Check status
docker compose ps

# Stop service
docker compose down

# Restart
docker compose restart

# Update and redeploy
docker compose down
docker compose up -d --build
```

## Configuration

Edit `compose.yaml` to change:
- `PORT`: HTTP port (default: 4000)
- `RATE_LIMIT_WINDOW_SECONDS`: Time window (default: 60)
- `RATE_LIMIT_REQUESTS_PER_WINDOW`: Request limit (default: 100)
- `SECRET_KEY_BASE`: **⚠️ Change this for production!**

Generate a secure secret:
```bash
docker run --rm rate-limiter:latest /app/bin/rate_limiter eval "IO.puts(:crypto.strong_rand_bytes(64) |> Base.encode64())"
```

## Health & Monitoring

```bash
# Health check
curl http://localhost:4000/api/v1/health

# Container stats
docker stats rate-limiter

# View health status
docker inspect rate-limiter | grep -A 5 Health
```

## Troubleshooting

**Port already in use:**
```bash
# Change port in compose.yaml
ports:
  - "4001:4000"  # Use 4001 instead
```

**Container won't start:**
```bash
# Check logs
docker compose logs rate-limiter

# Common fix: regenerate secret
# Edit compose.yaml and update SECRET_KEY_BASE
```

**Low performance:**
```bash
# Increase memory in compose.yaml
deploy:
  resources:
    limits:
      memory: 1G
```

## Full Documentation

- **[DOCKER_DEPLOYMENT.md](./DOCKER_DEPLOYMENT.md)** - Complete deployment guide
- **[README.md](./README.md)** - API documentation
- **[README_IMPLEMENTATION.md](./README_IMPLEMENTATION.md)** - Development guide

## Production Checklist

Before deploying to production:
- [ ] Generate unique `SECRET_KEY_BASE`
- [ ] Configure appropriate rate limits
- [ ] Set up reverse proxy with SSL
- [ ] Configure monitoring/alerting
- [ ] Review resource limits
- [ ] Test health checks
- [ ] Set up log aggregation
