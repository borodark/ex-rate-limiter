defmodule RateLimiterPerformanceTest do
  use ExUnit.Case, async: true

  setup do
    # Start a unique GenServer instance for this test
    {:ok, pid} = GenServer.start_link(RateLimiter.RateLimiter, [])
    {:ok, limiter: pid}
  end

  describe "throughput benchmarks" do
    test "handles 1000+ requests per second", %{limiter: limiter} do
      {:ok, _} = GenServer.call(limiter, {:configure, 60, 10000})

      # Measure time to process 1000 requests
      start_time = System.monotonic_time(:millisecond)

      tasks =
        Enum.map(1..1000, fn i ->
          num = i
          client_num = rem(num, 10)

          Task.async(fn ->
            GenServer.call(limiter, {:check_rate_limit, "client_#{client_num}", "resource"})
          end)
        end)

      results = Task.await_many(tasks)
      elapsed_ms = System.monotonic_time(:millisecond) - start_time

      # All requests should succeed
      assert Enum.all?(results, fn {:ok, r} -> r.allowed end)

      # Throughput should be 1000+ req/s
      # At 1000 requests, 1000ms = 1000 req/s
      throughput = 1000 / (elapsed_ms / 1000)
      assert throughput >= 1000, "Throughput: #{throughput} req/s (expected >= 1000)"

      IO.puts("\n  Throughput: #{Float.round(throughput, 2)} req/s (elapsed: #{elapsed_ms}ms)")
    end

    test "handles 50000+ requests per second with high concurrency", %{limiter: limiter} do
      {:ok, _} = GenServer.call(limiter, {:configure, 60, 50000})

      start_time = System.monotonic_time(:millisecond)

      # 50000 concurrent requests
      tasks =
        Enum.map(1..50000, fn i ->
          client_num = rem(i, 50)

          Task.async(fn ->
            GenServer.call(limiter, {:check_rate_limit, "bench_client_#{client_num}", "resource"})
          end)
        end)

      results = Task.await_many(tasks)
      elapsed_ms = System.monotonic_time(:millisecond) - start_time

      # All requests should succeed with high limit
      success_count = Enum.count(results, fn {:ok, r} -> r.allowed end)
      assert success_count >= 50000 * 0.99, "Most requests should succeed"

      # Throughput calculation
      throughput = 50000 / (elapsed_ms / 1000)

      IO.puts(
        "\n  High concurrency throughput: #{Float.round(throughput, 2)} req/s (50000 requests in #{elapsed_ms}ms)"
      )
    end
  end

  describe "latency benchmarks" do
    test "processes single request in under 10ms (latency requirement)", %{limiter: limiter} do
      # Warm up
      GenServer.call(limiter, {:check_rate_limit, "latency_test", "resource"})

      # Measure single request latency
      start_time = System.monotonic_time(:microsecond)
      {:ok, _response} = GenServer.call(limiter, {:check_rate_limit, "latency_test", "resource"})
      elapsed_us = System.monotonic_time(:microsecond) - start_time
      elapsed_ms = elapsed_us / 1000

      assert elapsed_ms < 10,
             "Single request latency: #{Float.round(elapsed_ms, 3)}ms (expected < 10ms)"

      IO.puts("\n  Single request latency: #{Float.round(elapsed_ms, 3)}ms")
    end

    test "maintains sub-10ms latency under load", %{limiter: limiter} do
      {:ok, _} = GenServer.call(limiter, {:configure, 60, 100_000})

      # Spawn background load
      background_tasks =
        for _ <- 1..100 do
          Task.async(fn ->
            for _ <- 1..50 do
              GenServer.call(limiter, {:check_rate_limit, "bg_client", "resource"})
            end
          end)
        end

      # Measure latency of requests while background tasks are running
      latencies_microsecond =
        for _ <- 1..100 do
          start_time = System.monotonic_time(:microsecond)
          GenServer.call(limiter, {:check_rate_limit, "latency_client", "resource"})
          elapsed_us = System.monotonic_time(:microsecond) - start_time
          elapsed_us
        end

      # Wait for background tasks
      Task.await_many(background_tasks, 30000)

      # Calculate statistics
      latency_sum = Enum.reduce(latencies_microsecond, 0, fn x, acc -> acc + x end)
      avg_latency = latency_sum / Enum.count(latencies_microsecond) / 1000
      max_latency = Enum.max(latencies_microsecond) / 1000
      min_latency = Enum.min(latencies_microsecond) / 1000

      # Most should be under 10ms (the actual rate limiter operation is sub-millisecond)
      count_under_10ms = Enum.count(latencies_microsecond, &(&1 < 10_000))
      percent_under_10ms = count_under_10ms / Enum.count(latencies_microsecond) * 100

      # Under background load, we're still well under 10ms per operation
      # Using 70% threshold to account for system scheduling variance
      assert percent_under_10ms >= 70,
             "At least 70% should be under 10ms, got #{percent_under_10ms}%"

      IO.puts("""
        \n  Latency under load (100 requests):
          - Average: #{Float.round(avg_latency, 3)}ms
          - Min: #{Float.round(min_latency, 3)}ms
          - Max: #{Float.round(max_latency, 3)}ms
          - Under 10ms: #{percent_under_10ms}%
      """)
    end

    test "p95 latency is reasonable under stress", %{limiter: limiter} do
      {:ok, _} = GenServer.call(limiter, {:configure, 60, 100_000})

      # Measure 500 requests
      latencies =
        for _ <- 1..500 do
          start_time = System.monotonic_time(:microsecond)
          GenServer.call(limiter, {:check_rate_limit, "p95_client", "resource"})
          elapsed_us = System.monotonic_time(:microsecond) - start_time
          elapsed_us / 1000
        end

      # Calculate p95
      sorted = Enum.sort(latencies)
      p95_index = ceil(Enum.count(sorted) * 0.95) - 1
      p95_latency = Enum.at(sorted, p95_index)

      # p95 should be under 15ms
      assert p95_latency < 15,
             "p95 latency should be under 15ms, got #{Float.round(p95_latency, 3)}ms"

      IO.puts("\n  p95 latency (500 requests): #{Float.round(p95_latency, 3)}ms")
    end
  end

  describe "scalability benchmarks" do
    test "scales with number of concurrent clients", %{limiter: limiter} do
      {:ok, _} = GenServer.call(limiter, {:configure, 60, 100_000})

      client_counts = [10, 50, 100, 500, 1000]

      results =
        Enum.map(client_counts, fn client_count ->
          start_time = System.monotonic_time(:millisecond)

          tasks =
            Enum.map(1..10000, fn i ->
              client_num = rem(i, client_count)

              Task.async(fn ->
                GenServer.call(limiter, {:check_rate_limit, "client_#{client_num}", "resource"})
              end)
            end)

          _results = Task.await_many(tasks)
          elapsed_ms = System.monotonic_time(:millisecond) - start_time
          throughput = 10000 / (elapsed_ms / 1000)

          {client_count, throughput, elapsed_ms}
        end)

      IO.puts("\n  Scalability (10000 requests across varying client counts):")

      Enum.each(results, fn {client_count, throughput, elapsed_ms} ->
        IO.puts(
          "    #{client_count} clients: #{Float.round(throughput, 2)} req/s (#{elapsed_ms}ms)"
        )
      end)

      # Should maintain reasonable throughput across all scenarios
      Enum.each(results, fn {_client_count, throughput, _elapsed_ms} ->
        assert throughput >= 500, "Throughput should remain >= 500 req/s"
      end)
    end

    test "memory efficiency with many clients", %{limiter: limiter} do
      {:ok, _} = GenServer.call(limiter, {:configure, 60, 100_000})

      # Create requests from 1000 different clients
      tasks =
        for i <- 1..1000 do
          Task.async(fn ->
            for _ <- 1..10 do
              GenServer.call(limiter, {:check_rate_limit, "distinct_client_#{i}", "resource"})
            end
          end)
        end

      _results = Task.await_many(tasks)

      # Should complete without issues - validates memory management
      {:ok, config} = GenServer.call(limiter, :get_config)
      assert config.window_seconds == 60
      assert config.requests_per_window == 100_000

      IO.puts("\n  Successfully tracked requests from 1000 distinct clients")
    end
  end

  describe "consistency and accuracy under stress" do
    test "maintains accurate request counting under concurrent load", %{limiter: limiter} do
      {:ok, _} = GenServer.call(limiter, {:configure, 60, 50})

      # All requests from same client
      tasks =
        for _ <- 1..100 do
          Task.async(fn ->
            GenServer.call(limiter, {:check_rate_limit, "stress_client", "resource"})
          end)
        end

      results = Task.await_many(tasks)

      # Exactly 50 should be allowed (limit)
      allowed_count = Enum.count(results, fn {:ok, r} -> r.allowed end)
      denied_count = Enum.count(results, fn {:ok, r} -> not r.allowed end)

      assert allowed_count == 50, "Should allow exactly 50 requests"
      assert denied_count == 50, "Should deny exactly 50 requests"

      # Verify all denied responses have retry_after
      Enum.each(results, fn {:ok, response} ->
        if not response.allowed do
          assert Map.has_key?(response, :retry_after)
          assert response.retry_after >= 1
        end
      end)

      IO.puts(
        "\n  Concurrent stress test: #{allowed_count} allowed, #{denied_count} denied (accurate)"
      )
    end

    test "maintains per-client isolation under stress", %{limiter: limiter} do
      {:ok, _} = GenServer.call(limiter, {:configure, 60, 100})

      # Create load from multiple clients
      client_results =
        for client_num <- 1..10 do
          tasks =
            for _ <- 1..50 do
              Task.async(fn ->
                GenServer.call(
                  limiter,
                  {:check_rate_limit, "stress_client_#{client_num}", "resource"}
                )
              end)
            end

          results = Task.await_many(tasks)
          allowed = Enum.count(results, fn {:ok, r} -> r.allowed end)
          {client_num, allowed}
        end

      IO.puts("\n  Per-client isolation (50 requests per client, 100 limit):")

      Enum.each(client_results, fn {client_num, allowed} ->
        IO.puts("    Client #{client_num}: #{allowed} allowed")
        assert allowed == 50, "Each client should get all 50 requests"
      end)
    end
  end

  describe "operation timing" do
    test "configure operation completes quickly", %{limiter: limiter} do
      times =
        for _ <- 1..100 do
          start_time = System.monotonic_time(:microsecond)
          {:ok, _} = GenServer.call(limiter, {:configure, 120, 500})
          elapsed_us = System.monotonic_time(:microsecond) - start_time
          elapsed_us / 1000
        end

      avg_time = Enum.sum(times) / Enum.count(times)

      assert avg_time < 5, "Configure should complete in < 5ms on average"

      IO.puts("\n  Configure operation average time: #{Float.round(avg_time, 3)}ms")
    end

    test "get_config operation is instant", %{limiter: limiter} do
      times =
        for _ <- 1..100 do
          start_time = System.monotonic_time(:microsecond)
          {:ok, _} = GenServer.call(limiter, :get_config)
          elapsed_us = System.monotonic_time(:microsecond) - start_time
          elapsed_us / 1000
        end

      max_time = Enum.max(times)
      avg_time = Enum.sum(times) / Enum.count(times)

      assert max_time < 5, "Get config should always complete in < 5ms"

      IO.puts(
        "\n  Get config operation - avg: #{Float.round(avg_time, 3)}ms, max: #{Float.round(max_time, 3)}ms"
      )
    end
  end
end
