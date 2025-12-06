defmodule RateLimiterWeb.RateLimitControllerPerformanceTest do
  use ExUnit.Case, async: false

  # These tests test the full HTTP stack including JSON parsing, routing, and HTTP overhead
  # The HTTP endpoint is automatically started and configured in setup_all
  # To exclude these tests: mix test --exclude http_performance
  @moduletag :http_performance
  @moduletag :performance

  # Start the application for HTTP testing
  setup_all do
    # Start Finch for HTTP client
    {:ok, _finch_pid} =
      case Finch.start_link(
             name: RateLimiter.Finch,
             pools: %{
               default: [
                 # Core pool settings (maximum concurrency)
                 # Connections per pool
                 size: 1024,
                 # Number of pools (44 CPUs × ~12)
                 count: 44,
                 # Performance monitoring
                 # Enable metrics collection
                 start_pool_metrics?: true,

                 # Connection options for maximum performance
                 conn_opts: [
                   # Timeout settings
                   # 2 min connect timeout
                   timeout: 120_000,

                   # Network mode
                   # Passive mode for high load
                   mode: :passive,

                   # Disable logging overhead
                   log: false,

                   # Transport options (passed to :gen_tcp)
                   transport_opts: [
                     # Critical latency optimizations
                     # Disable Nagle's algorithm
                     nodelay: true,
                     # TCP keepalive
                     keepalive: true,

                     # Large buffers for maximum throughput (1MB each)
                     sndbuf: 1_048_576,
                     recbuf: 1_048_576,
                     buffer: 1_048_576,

                     # Timeout settings
                     send_timeout: 60_000,
                     send_timeout_close: true,

                     # Socket settings for performance
                     packet: :raw,
                     mode: :binary,
                     active: false,
                     reuseaddr: true,

                     # Message queue management
                     high_msgq_watermark: 16_384,
                     low_msgq_watermark: 8_192
                   ]
                 ]
               ]
             }
           ) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
      end

    :ok
  end

  setup do
    # Reset and configure for each test
    :ok = RateLimiter.RateLimiter.reset()
    {:ok, _} = RateLimiter.RateLimiter.configure(60, 10000)
    :ok
  end

  defp http_post(path, body) do
    url = "http://192.168.0.249:4000#{path}"

    case Finch.build(:post, url, [{"content-type", "application/json"}], Jason.encode!(body))
         |> Finch.request(RateLimiter.Finch) do
      {:ok, %{status: status, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, decoded} -> {:ok, status, decoded}
          {:error, _} -> {:ok, status, %{}}
        end

      {:error, reason} ->
        IO.puts("HTTP POST Error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp http_get(path) do
    url = "http://192.168.0.249:4000#{path}"

    case Finch.build(:get, url) |> Finch.request(RateLimiter.Finch) do
      {:ok, %{status: status, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, decoded} -> {:ok, status, decoded}
          {:error, _} -> {:ok, status, %{}}
        end

      {:error, reason} ->
        IO.puts("HTTP GET Error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # defp http_delete(path) do
  #   url = "http://localhost:4000#{path}"
  #
  #   case Finch.build(:delete, url) |> Finch.request(RateLimiter.Finch) do
  #     {:ok, %{status: status, body: response_body}} ->
  #       {:ok, status, Jason.decode!(response_body)}
  #
  #     {:error, reason} ->
  #       {:error, reason}
  #   end
  # end

  describe "HTTP health endpoint" do
    test "GET /api/v1/health returns 200 OK" do
      {:ok, status, body} = http_get("/api/v1/health")

      assert status == 200
      assert body["status"] == "ok"
    end

    test "health endpoint responds quickly" do
      # Test response time for 100 health checks
      start_time = System.monotonic_time(:millisecond)

      results =
        Enum.map(1..100, fn _ ->
          {:ok, status, _body} = http_get("/api/v1/health")
          status
        end)

      elapsed = System.monotonic_time(:millisecond) - start_time
      avg_latency = elapsed / 100

      # All should return 200
      assert Enum.all?(results, &(&1 == 200))

      # Average latency should be very low (under 5ms)
      assert avg_latency < 5.0

      IO.puts("\n  Health endpoint average latency: #{Float.round(avg_latency, 3)}ms")
    end
  end

  describe "HTTP endpoint throughput" do
    test "POST /api/v1/ratelimit handles high throughput" do
      start_time = System.monotonic_time(:millisecond)

      # Make 500 concurrent HTTP requests
      tasks =
        Enum.map(1..500, fn i ->
          Task.async(fn ->
            client_num = rem(i, 10)

            http_post("/api/v1/ratelimit", %{
              "client_id" => "client_#{client_num}",
              "resource" => "api"
            })
          end)
        end)

      results = Task.await_many(tasks, 30000)
      elapsed_ms = System.monotonic_time(:millisecond) - start_time

      # Count successful responses
      success_count =
        Enum.count(results, fn
          {:ok, 200, _} -> true
          _ -> false
        end)

      assert success_count == 500, "All requests should succeed"

      throughput = 500 / (elapsed_ms / 1000)
      assert throughput >= 100, "Should handle at least 100 req/s over HTTP"

      IO.puts(
        "\n  HTTP endpoint throughput: #{Float.round(throughput, 2)} req/s (#{elapsed_ms}ms)"
      )
    end

    test "POST /api/v1/ratelimit scales with concurrent clients" do
      client_counts = [10, 50]

      results =
        Enum.map(client_counts, fn client_count ->
          start_time = System.monotonic_time(:millisecond)

          tasks =
            Enum.map(1..200, fn i ->
              client_num = rem(i, client_count)

              Task.async(fn ->
                http_post("/api/v1/ratelimit", %{
                  "client_id" => "client_#{client_num}",
                  "resource" => "api"
                })
              end)
            end)

          _results = Task.await_many(tasks, 30000)
          elapsed_ms = System.monotonic_time(:millisecond) - start_time
          throughput = 200 / (elapsed_ms / 1000)

          {client_count, throughput, elapsed_ms}
        end)

      IO.puts("\n  HTTP scalability (200 requests):")

      Enum.each(results, fn {client_count, throughput, elapsed_ms} ->
        IO.puts(
          "    #{client_count} clients: #{Float.round(throughput, 2)} req/s (#{elapsed_ms}ms)"
        )
      end)

      # Should maintain reasonable throughput
      Enum.each(results, fn {_client_count, throughput, _elapsed_ms} ->
        assert throughput >= 50, "Should maintain at least 50 req/s over HTTP"
      end)
    end
  end

  describe "HTTP endpoint latency" do
    test "POST /api/v1/ratelimit has reasonable latency" do
      # Warmup
      http_post("/api/v1/ratelimit", %{
        "client_id" => "warmup",
        "resource" => "api"
      })

      # Measure latencies
      latencies =
        for _ <- 1..50 do
          start_time = System.monotonic_time(:microsecond)

          http_post("/api/v1/ratelimit", %{
            "client_id" => "latency_test",
            "resource" => "api"
          })

          elapsed_us = System.monotonic_time(:microsecond) - start_time
          elapsed_us / 1000
        end

      avg_latency = Enum.sum(latencies) / Enum.count(latencies)
      max_latency = Enum.max(latencies)
      min_latency = Enum.min(latencies)

      # p95 latency
      sorted = Enum.sort(latencies)
      p95_index = ceil(Enum.count(sorted) * 0.95) - 1
      p95_latency = Enum.at(sorted, p95_index)

      assert avg_latency < 100, "Average HTTP latency should be under 100ms"
      assert p95_latency < 200, "p95 HTTP latency should be under 200ms"

      IO.puts("""
        \n  HTTP endpoint latency (50 requests):
          - Average: #{Float.round(avg_latency, 2)}ms
          - Min: #{Float.round(min_latency, 2)}ms
          - Max: #{Float.round(max_latency, 2)}ms
          - p95: #{Float.round(p95_latency, 2)}ms
      """)
    end
  end

  describe "POST /api/v1/configure performance" do
    test "configure endpoint is fast" do
      times =
        for i <- 1..50 do
          limit = 100 + rem(i, 10)
          start_time = System.monotonic_time(:microsecond)

          http_post("/api/v1/configure", %{
            "window_seconds" => 60,
            "request_per_window" => limit
          })

          elapsed_us = System.monotonic_time(:microsecond) - start_time
          elapsed_us / 1000
        end

      avg_time = Enum.sum(times) / Enum.count(times)
      max_time = Enum.max(times)

      assert avg_time < 100, "Configure HTTP should be under 100ms average"

      IO.puts("""
        \n  Configure endpoint performance:
          - Average: #{Float.round(avg_time, 2)}ms
          - Max: #{Float.round(max_time, 2)}ms
      """)
    end
  end

  describe "POST /api/v1/configure-client performance" do
    test "configure-client endpoint is fast" do
      times =
        for i <- 1..50 do
          start_time = System.monotonic_time(:microsecond)

          http_post("/api/v1/configure-client", %{
            "client_id" => "vip_#{i}",
            "window_seconds" => 60,
            "request_per_window" => 500
          })

          elapsed_us = System.monotonic_time(:microsecond) - start_time
          elapsed_us / 1000
        end

      avg_time = Enum.sum(times) / Enum.count(times)
      max_time = Enum.max(times)

      assert avg_time < 100, "Configure-client HTTP should be under 100ms average"

      IO.puts("""
        \n  Configure-client endpoint performance:
          - Average: #{Float.round(avg_time, 2)}ms
          - Max: #{Float.round(max_time, 2)}ms
      """)
    end
  end

  describe "GET /api/v1/client-config/:client_id performance" do
    test "get client config endpoint is fast" do
      # Set up some client configs
      for i <- 1..10 do
        http_post("/api/v1/configure-client", %{
          "client_id" => "client_#{i}",
          "window_seconds" => 60,
          "request_per_window" => 500
        })
      end

      times =
        for _ <- 1..50 do
          client_num = :rand.uniform(10)
          start_time = System.monotonic_time(:microsecond)

          http_get("/api/v1/client-config/client_#{client_num}")

          elapsed_us = System.monotonic_time(:microsecond) - start_time
          elapsed_us / 1000
        end

      avg_time = Enum.sum(times) / Enum.count(times)
      max_time = Enum.max(times)

      assert avg_time < 100, "Get client config HTTP should be under 100ms average"

      IO.puts("""
        \n  Get client-config endpoint performance:
          - Average: #{Float.round(avg_time, 2)}ms
          - Max: #{Float.round(max_time, 2)}ms
      """)
    end
  end

  describe "accuracy under concurrent HTTP load" do
    test "maintains accurate counting with concurrent HTTP requests" do
      # Use a unique client ID to avoid cross-test interference
      unique_client = "stress_client_#{:rand.uniform(100_000)}"

      http_post("/api/v1/configure", %{
        "window_seconds" => 60,
        "request_per_window" => 50
      })

      # Give config time to apply
      Process.sleep(10)

      # All requests from same client
      tasks =
        for _ <- 1..100 do
          Task.async(fn ->
            http_post("/api/v1/ratelimit", %{
              "client_id" => unique_client,
              "resource" => "api"
            })
          end)
        end

      results = Task.await_many(tasks, 30000)

      # Count allowed and denied
      allowed_count =
        Enum.count(results, fn
          {:ok, 200, %{"allowed" => true}} -> true
          _ -> false
        end)

      denied_count =
        Enum.count(results, fn
          {:ok, 200, %{"allowed" => false}} -> true
          _ -> false
        end)

      # Log for debugging
      IO.puts(
        "\n  HTTP accuracy test: #{allowed_count} allowed, #{denied_count} denied (expected: 50/50)"
      )

      # The counts should be exactly 50/50 with proper rate limiting
      assert allowed_count == 50,
             "Should allow exactly 50 requests via HTTP, got #{allowed_count}"

      assert denied_count == 50,
             "Should deny exactly 50 requests via HTTP, got #{denied_count}"
    end

    test "maintains per-client isolation with HTTP requests" do
      http_post("/api/v1/configure", %{
        "window_seconds" => 60,
        "request_per_window" => 100
      })

      # Create requests from 5 different clients, 20 requests each
      client_results =
        for client_num <- 1..5 do
          tasks =
            for _ <- 1..20 do
              Task.async(fn ->
                http_post("/api/v1/ratelimit", %{
                  "client_id" => "http_client_#{client_num}",
                  "resource" => "api"
                })
              end)
            end

          results = Task.await_many(tasks, 30000)

          allowed =
            Enum.count(results, fn
              {:ok, 200, %{"allowed" => true}} -> true
              _ -> false
            end)

          {client_num, allowed}
        end

      IO.puts("\n  HTTP per-client isolation (20 requests per client, 100 limit):")

      Enum.each(client_results, fn {client_num, allowed} ->
        IO.puts("    Client #{client_num}: #{allowed} allowed")
        assert allowed == 20, "Each client should get all 20 requests allowed via HTTP"
      end)
    end
  end

  describe "mixed HTTP endpoint load" do
    test "handles mixed check/configure HTTP requests concurrently" do
      start_time = System.monotonic_time(:millisecond)

      # Mix of check and configure operations
      tasks =
        Enum.map(1..200, fn i ->
          Task.async(fn ->
            if rem(i, 10) == 0 do
              # 10% configure requests
              http_post("/api/v1/configure", %{
                "window_seconds" => 60,
                "request_per_window" => 10000 + rem(i, 100)
              })
            else
              # 90% check requests
              client_num = rem(i, 10)

              http_post("/api/v1/ratelimit", %{
                "client_id" => "client_#{client_num}",
                "resource" => "api"
              })
            end
          end)
        end)

      results = Task.await_many(tasks, 30000)
      elapsed_ms = System.monotonic_time(:millisecond) - start_time

      # Count successful requests
      success_count =
        Enum.count(results, fn
          {:ok, 200, _} -> true
          _ -> false
        end)

      assert success_count == 200, "All mixed HTTP requests should succeed"

      throughput = 200 / (elapsed_ms / 1000)

      IO.puts("""
        \n  Mixed HTTP endpoint load (200 requests):
          - Throughput: #{Float.round(throughput, 2)} req/s
          - Elapsed: #{elapsed_ms}ms
      """)
    end
  end

  describe "HTTP endpoint stress test" do
    test "handles burst of HTTP requests to multiple endpoints" do
      start_time = System.monotonic_time(:millisecond)

      # Create burst across different endpoints
      check_tasks =
        for i <- 1..300 do
          Task.async(fn ->
            http_post("/api/v1/ratelimit", %{
              "client_id" => "burst_#{rem(i, 20)}",
              "resource" => "api"
            })
          end)
        end

      config_tasks =
        for i <- 1..50 do
          Task.async(fn ->
            http_post("/api/v1/configure-client", %{
              "client_id" => "vip_#{i}",
              "window_seconds" => 60,
              "request_per_window" => 1000
            })
          end)
        end

      get_tasks =
        for i <- 1..50 do
          Task.async(fn ->
            http_get("/api/v1/client-config/vip_#{i}")
          end)
        end

      all_tasks = check_tasks ++ config_tasks ++ get_tasks
      results = Task.await_many(all_tasks, 30000)
      elapsed_ms = System.monotonic_time(:millisecond) - start_time

      success_count =
        Enum.count(results, fn
          {:ok, 200, _} -> true
          _ -> false
        end)

      total_requests = length(all_tasks)
      throughput = total_requests / (elapsed_ms / 1000)

      assert success_count == total_requests, "All HTTP stress test requests should succeed"

      IO.puts("""
        \n  Multi-endpoint HTTP stress test:
          - Total requests: #{total_requests}
          - Success: #{success_count}
          - Throughput: #{Float.round(throughput, 2)} req/s
          - Elapsed: #{elapsed_ms}ms
      """)
    end
  end
end
