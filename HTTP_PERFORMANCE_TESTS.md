# HTTP Performance Tests

This directory contains HTTP-level performance tests for the Rate Limiter Controller endpoints.

## Overview

The HTTP performance tests in `rate_limit_controller_performance_test.exs` test the **full HTTP stack** including:
- HTTP request/response cycle
- JSON encoding/decoding
- Phoenix routing and plug pipeline
- Controller logic
- Network overhead

These complement the GenServer performance tests which test the core rate limiting logic directly.

## Running the Tests

### Included by Default

HTTP performance tests are **included in the regular test suite** by default. When you run:

```bash
mix test
```

All 64 tests run, including the 10 HTTP performance tests.

### Run Only HTTP Performance Tests

To run just the HTTP performance tests:

```bash
# Run all HTTP performance tests
mix test test/rate_limiter_web/controllers/rate_limit_controller_performance_test.exs

# Run specific HTTP performance test
mix test test/rate_limiter_web/controllers/rate_limit_controller_performance_test.exs:259
```

### Exclude HTTP Tests

If you want to run tests WITHOUT the HTTP performance tests (e.g., for faster feedback during development):

```bash
mix test --exclude http_performance
```

This will run only the 54 GenServer and integration tests, skipping the HTTP endpoint startup.

## Test Coverage

The HTTP performance test suite includes 10 tests:

### 1. Throughput Tests (2 tests)
- **High Throughput**: 500 concurrent HTTP requests
- **Scalability**: Tests with 10 and 50 concurrent clients (200 requests each)

### 2. Latency Tests (1 test)
- Measures HTTP latency over 50 requests
- Includes min, max, average, and p95 latency

### 3. Endpoint-Specific Performance (3 tests)
- **POST /api/v1/configure**: 50 configure operations
- **POST /api/v1/configure-client**: 50 client-specific configurations
- **GET /api/v1/client-config/:client_id**: 50 config retrievals

### 4. Accuracy Tests (2 tests)
- **Concurrent Accuracy**: 100 concurrent requests, verifies 50 allowed / 50 denied
- **Per-Client Isolation**: 5 clients with 20 requests each

### 5. Mixed Load Tests (1 test)
- 200 mixed requests (90% check, 10% configure)

### 6. Stress Test (1 test)
- 400 requests across multiple endpoints (check, configure-client, get-config)

## Expected Performance

When the HTTP endpoint is properly started, you should see:

```
✓ HTTP server started successfully on port 4002
```

Typical performance metrics:

- **HTTP Throughput**: 2,000-11,000 req/s (varies by test and load)
- **HTTP Latency**: 0.6-1.0ms average
- **HTTP p95 Latency**: 0.7-1.3ms
- **Configure endpoint**: ~1-4ms average
- **Get config endpoint**: ~0.75-0.9ms average
- **All accuracy tests**: 100% correct rate limiting

Note: HTTP performance is naturally slower than direct GenServer calls due to the additional layers (network stack, HTTP protocol, JSON parsing, routing).

## Comparison with GenServer Tests

| Metric | GenServer Tests | HTTP Tests |
|--------|----------------|------------|
| **Throughput** | 44,000+ req/s | 2,000-11,000 req/s |
| **Latency** | 0.010ms | 0.6-1.0ms |
| **What's Tested** | Core logic only | Full HTTP stack |
| **Stability** | Very stable | Stable |
| **Speed** | Fast (~6s) | Fast (~2s) |
| **Included by Default** | Yes | Yes |
| **Can Exclude With** | N/A | `--exclude http_performance` |

## Troubleshooting

### Connection Refused Errors

If you see `Mint.TransportError{reason: :econnrefused}`, the HTTP endpoint isn't running. The test setup attempts to start it, but this can fail if:
- Port 4002 is already in use
- The endpoint was already started by another process
- Configuration issues prevent the endpoint from starting

### Server Not Starting

The tests configure the endpoint with:
```elixir
Application.put_env(:rate_limiter, RateLimiterWeb.Endpoint,
  http: [port: 4002],
  server: true
)
```

If the server doesn't start, check:
1. Port 4002 is available: `lsof -i :4002` or `netstat -tlnp | grep 4002`
2. The application has started: `Application.started_applications()`
3. The endpoint process is running: `Process.whereis(RateLimiterWeb.Endpoint)`

### High Failure Rate

If many tests fail with connection errors:
- Reduce the number of concurrent requests in tests
- Increase the sleep time in `setup_all` to give the server more time to start
- Run tests sequentially: `mix test --max-cases 1 --include http_performance`

## Why Both HTTP and GenServer Tests?

1. **GenServer tests** verify the core rate limiting logic is correct and performant
2. **HTTP tests** verify the entire system works end-to-end including HTTP overhead
3. **Together** they ensure both the algorithm and the API are production-ready

For most development and CI purposes, the GenServer tests provide sufficient coverage. HTTP tests are useful for:
- Integration testing
- Load testing the HTTP layer
- Benchmarking end-to-end performance
- Verifying the full system before deployment
