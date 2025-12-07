defmodule RateLimiter.SaturationTest do
  @moduledoc """
  Saturation tests to understand the limits of the rate limiter endpoint.

  These tests are designed to push the system to its limits and identify:
  - Maximum throughput (requests per second)
  - Latency under extreme load
  - Error rates at saturation
  - Connection limits
  - Memory and resource usage patterns

  Run with: mix test test/saturation_test.exs

  NOTE: These tests assume the service is running on localhost:4000
  Start the service first with: mix phx.server
  """
  use ExUnit.Case, async: false

  @moduletag :saturation
  @moduletag timeout: :infinity

  # Test configuration
  # Use IP address instead of hostname to avoid DNS resolution bottleneck
  #@base_url "http://192.168.0.249:4000"
  @base_url "http://127.0.0.1:4000"
  @health_endpoint "#{@base_url}/api/v1/health"
  @ratelimit_endpoint "#{@base_url}/api/v1/ratelimit"

  setup_all do
    # Start Finch HTTP client with MAXIMUM pool configuration for extreme concurrency testing
    # Pool configuration: 20,000 connections × 512 pools = 10,240,000 total capacity
    # Optimized for maximum throughput on 44 CPU / 256GB RAM system
    {:ok, _} =
      case Finch.start_link(
             name: SaturationTest.Finch,
             pools: %{
               default: [
                 # Core pool settings (maximum concurrency)
                 # Connections per pool
                 size: 20000,
                 # Number of pools (44 CPUs × ~12)
                 count: 512,
                 # Performance monitoring
                 start_pool_metrics?: false,

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
                     sndbuf: 2_097_152,
                     recbuf: 2_097_152,
                     buffer: 2_097_152,

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

    # Verify service is running
    case http_get(@health_endpoint) do
      {:ok, 200, _body} ->
        IO.puts("\n✓ Service is running on #{@base_url}")
        :ok

      {:error, reason} ->
        IO.puts("\n✗ ERROR: Service is not responding on #{@base_url}")
        IO.puts("  Reason: #{inspect(reason)}")
        IO.puts("  Please start the service with: mix phx.server")
        flunk("Service not running")
    end

    :ok
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp http_get(url) do
    case Finch.build(:get, url) |> Finch.request(SaturationTest.Finch) do
      {:ok, %{status: status, body: body}} ->
        case Jason.decode(body) do
          {:ok, decoded} -> {:ok, status, decoded}
          {:error, _} -> {:ok, status, %{}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp http_post(url, body) do
    case Finch.build(:post, url, [{"content-type", "application/json"}], Jason.encode!(body))
         |> Finch.request(SaturationTest.Finch) do
      {:ok, %{status: status, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, decoded} -> {:ok, status, decoded}
          {:error, _} -> {:ok, status, %{}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp calculate_stats(latencies) do
    sorted = Enum.sort(latencies)
    count = length(sorted)
    sum = Enum.sum(latencies)

    %{
      count: count,
      min: Enum.min(latencies),
      max: Enum.max(latencies),
      avg: sum / count,
      median: Enum.at(sorted, div(count, 2)),
      p95: Enum.at(sorted, round(count * 0.95)),
      p99: Enum.at(sorted, round(count * 0.99))
    }
  end

  # ============================================================================
  # Saturation Tests
  # ============================================================================

  describe "Baseline Performance" do
    test "establishes baseline with 1000 sequential requests" do
      IO.puts("\n=== Baseline Performance Test ===")
      IO.puts("Sending 1000 sequential requests...")

      start_time = System.monotonic_time(:millisecond)
      latencies = []
      errors = 0

      {latencies, errors} =
        Enum.reduce(1..1000, {latencies, errors}, fn i, {lats, errs} ->
          req_start = System.monotonic_time(:millisecond)

          case http_post(@ratelimit_endpoint, %{
                 "client_id" => "baseline_client_#{rem(i, 10)}",
                 "resource" => "api"
               }) do
            {:ok, _status, _body} ->
              req_end = System.monotonic_time(:millisecond)
              {[req_end - req_start | lats], errs}

            {:error, _reason} ->
              {lats, errs + 1}
          end
        end)

      elapsed = System.monotonic_time(:millisecond) - start_time
      throughput = 1000 / (elapsed / 1000)
      stats = calculate_stats(latencies)

      IO.puts("\nBaseline Results:")
      IO.puts("  Total Time: #{elapsed}ms")
      IO.puts("  Throughput: #{Float.round(throughput, 2)} req/s")
      IO.puts("  Errors: #{errors}")
      IO.puts("  Latency Stats:")
      IO.puts("    Min: #{stats.min}ms")
      IO.puts("    Avg: #{Float.round(stats.avg, 2)}ms")
      IO.puts("    Median: #{stats.median}ms")
      IO.puts("    P95: #{stats.p95}ms")
      IO.puts("    P99: #{stats.p99}ms")
      IO.puts("    Max: #{stats.max}ms")

      assert errors == 0, "Baseline should have no errors"
      assert throughput > 500, "Baseline throughput should be > 500 req/s"
    end
  end

  describe "Concurrent Load Testing" do
    test "measures throughput with 100 concurrent connections" do
      IO.puts("\n=== 100 Concurrent Connections Test ===")
      IO.puts("Spawning 100 concurrent tasks, each sending 100 requests...")

      start_time = System.monotonic_time(:millisecond)

      results =
        1..100
        |> Enum.map(fn task_id ->
          Task.async(fn ->
            latencies = []
            errors = 0

            {latencies, errors} =
              Enum.reduce(1..100, {latencies, errors}, fn _i, {lats, errs} ->
                req_start = System.monotonic_time(:millisecond)

                case http_post(@ratelimit_endpoint, %{
                       "client_id" => "client_#{task_id}",
                       "resource" => "api"
                     }) do
                  {:ok, _status, _body} ->
                    req_end = System.monotonic_time(:millisecond)
                    {[req_end - req_start | lats], errs}

                  {:error, _reason} ->
                    {lats, errs + 1}
                end
              end)

            %{latencies: latencies, errors: errors}
          end)
        end)
        |> Enum.map(&Task.await(&1, :infinity))

      elapsed = System.monotonic_time(:millisecond) - start_time

      all_latencies = Enum.flat_map(results, & &1.latencies)
      total_errors = Enum.sum(Enum.map(results, & &1.errors))
      total_requests = 100 * 100
      throughput = total_requests / (elapsed / 1000)
      stats = calculate_stats(all_latencies)

      IO.puts("\n100 Concurrent Connections Results:")
      IO.puts("  Total Requests: #{total_requests}")
      IO.puts("  Total Time: #{elapsed}ms")
      IO.puts("  Throughput: #{Float.round(throughput, 2)} req/s")

      IO.puts(
        "  Errors: #{total_errors} (#{Float.round(total_errors / total_requests * 100, 2)}%)"
      )

      IO.puts("  Latency Stats:")
      IO.puts("    Min: #{stats.min}ms")
      IO.puts("    Avg: #{Float.round(stats.avg, 2)}ms")
      IO.puts("    Median: #{stats.median}ms")
      IO.puts("    P95: #{stats.p95}ms")
      IO.puts("    P99: #{stats.p99}ms")
      IO.puts("    Max: #{stats.max}ms")

      assert total_errors / total_requests < 0.05, "Error rate should be < 5%"
    end

    test "finds saturation point with increasing concurrent connections" do
      IO.puts("\n=== Finding Saturation Point ===")
      IO.puts("Testing with increasing concurrent connections...")

      concurrency_levels = [
        1_000,
        5_000,
        10_000
      ]

      requests_per_task = 100

      IO.puts("Note: Testing up to #{Enum.max(concurrency_levels)} concurrent connections")

      results =
        Enum.map(concurrency_levels, fn concurrency ->
          IO.puts("\nTesting #{concurrency} concurrent connections...")

          start_time = System.monotonic_time(:millisecond)

          task_results =
            1..concurrency
            |> Enum.map(fn task_id ->
              Task.async(fn ->
                errors = 0

                errors =
                  Enum.reduce(1..requests_per_task, errors, fn _i, errs ->
                    case http_post(@ratelimit_endpoint, %{
                           "client_id" => "saturation_client_#{task_id}",
                           "resource" => "api"
                         }) do
                      {:ok, _status, _body} -> errs
                      {:error, _reason} ->
                        errs + 1
                    end
                  end)

                errors
              end)
            end)
            |> Enum.map(&Task.await(&1, :infinity))

          elapsed = System.monotonic_time(:millisecond) - start_time
          total_requests = concurrency * requests_per_task
          total_errors = Enum.sum(task_results)
          throughput = total_requests / (elapsed / 1000)
          error_rate = total_errors / total_requests * 100

          result = %{
            concurrency: concurrency,
            total_requests: total_requests,
            elapsed_ms: elapsed,
            throughput: throughput,
            errors: total_errors,
            error_rate: error_rate
          }

          IO.puts("  Throughput: #{Float.round(throughput, 2)} req/s")
          IO.puts("  Error Rate: #{Float.round(error_rate, 2)}%")
          IO.puts("  Total Time: #{elapsed}ms")

          result
        end)

      IO.puts("\n=== Saturation Summary ===")
      IO.puts("\nConcurrency | Throughput (req/s) | Error Rate | Time (ms)")
      IO.puts("------------|-------------------|-----------|----------")

      Enum.each(results, fn r ->
        IO.puts(
          "#{String.pad_leading(Integer.to_string(r.concurrency), 11)} | " <>
            "#{String.pad_leading(Float.to_string(Float.round(r.throughput, 2)), 17)} | " <>
            "#{String.pad_leading(Float.to_string(Float.round(r.error_rate, 2)), 9)}% | " <>
            "#{r.elapsed_ms}"
        )
      end)

      # Find peak throughput
      peak = Enum.max_by(results, & &1.throughput)

      IO.puts(
        "\n✓ Peak throughput: #{Float.round(peak.throughput, 2)} req/s at #{peak.concurrency} concurrent connections"
      )

      # Find saturation point (where error rate exceeds 5%)
      saturation =
        Enum.find(results, fn r -> r.error_rate > 5.0 end) ||
          List.last(results)

      if saturation.error_rate > 5.0 do
        IO.puts(
          "⚠ Saturation point: #{saturation.concurrency} concurrent connections (#{Float.round(saturation.error_rate, 2)}% error rate)"
        )
      else
        IO.puts("✓ No saturation detected up to #{saturation.concurrency} concurrent connections")
      end

      assert peak.throughput > 1000, "Peak throughput should exceed 1000 req/s"
    end
  end

  describe "Sustained Load Testing" do
    test "maintains performance under sustained load for 30 seconds" do
      IO.puts("\n=== Sustained Load Test (30 seconds) ===")
      IO.puts("Running 500 concurrent connections for 30 seconds...")

      duration_ms = 30_000
      concurrency = 500
      start_time = System.monotonic_time(:millisecond)
      end_time = start_time + duration_ms

      tasks =
        1..concurrency
        |> Enum.map(fn task_id ->
          Task.async(fn ->
            requests = 0
            errors = 0
            latencies = []

            {requests, errors, latencies} =
              Stream.cycle([1])
              |> Enum.reduce_while({requests, errors, latencies}, fn _, {reqs, errs, lats} ->
                current_time = System.monotonic_time(:millisecond)

                if current_time < end_time do
                  req_start = System.monotonic_time(:millisecond)

                  case http_post(@ratelimit_endpoint, %{
                         "client_id" => "sustained_client_#{task_id}",
                         "resource" => "api"
                       }) do
                    {:ok, _status, _body} ->
                      req_end = System.monotonic_time(:millisecond)
                      {:cont, {reqs + 1, errs, [req_end - req_start | lats]}}

                    {:error, _reason} ->
                      {:cont, {reqs + 1, errs + 1, lats}}
                  end
                else
                  {:halt, {reqs, errs, lats}}
                end
              end)

            %{requests: requests, errors: errors, latencies: latencies}
          end)
        end)

      results = Enum.map(tasks, &Task.await(&1, :infinity))
      actual_elapsed = System.monotonic_time(:millisecond) - start_time

      total_requests = Enum.sum(Enum.map(results, & &1.requests))
      total_errors = Enum.sum(Enum.map(results, & &1.errors))
      all_latencies = Enum.flat_map(results, & &1.latencies)

      throughput = total_requests / (actual_elapsed / 1000)
      error_rate = total_errors / total_requests * 100
      stats = calculate_stats(all_latencies)

      IO.puts("\nSustained Load Results:")
      IO.puts("  Duration: #{actual_elapsed}ms (target: #{duration_ms}ms)")
      IO.puts("  Total Requests: #{total_requests}")
      IO.puts("  Throughput: #{Float.round(throughput, 2)} req/s")
      IO.puts("  Errors: #{total_errors} (#{Float.round(error_rate, 2)}%)")
      IO.puts("  Latency Stats:")
      IO.puts("    Min: #{stats.min}ms")
      IO.puts("    Avg: #{Float.round(stats.avg, 2)}ms")
      IO.puts("    Median: #{stats.median}ms")
      IO.puts("    P95: #{stats.p95}ms")
      IO.puts("    P99: #{stats.p99}ms")
      IO.puts("    Max: #{stats.max}ms")

      assert error_rate < 5.0, "Sustained load error rate should be < 5%"
      assert throughput > 500, "Sustained throughput should be > 500 req/s"
    end
  end

  @extreme 200_000
  describe "Extreme Load Testing" do
    test "handles #inspect{(@extreme)} concurrent connections ALL AT ONCE" do
      IO.puts("\n=== Extreme Load Test: #inspect{(@extreme)} Concurrent Connections ===")
      IO.puts("This test pushes the system to TRUE extreme limits...")
      IO.puts("All #inspect{(@extreme)} requests spawned SIMULTANEOUSLY (no batching)")
      IO.puts("Testing true server saturation point...")

      concurrency = @extreme
      start_time = System.monotonic_time(:millisecond)

      IO.puts("\nSpawning #{concurrency} concurrent tasks NOW...")
      spawn_start = System.monotonic_time(:millisecond)

      results =
        1..concurrency
        |> Enum.map(fn task_id ->
          Task.async(fn ->
            req_start = System.monotonic_time(:millisecond)

            result =
              case http_post(@ratelimit_endpoint, %{
                     "client_id" => "extreme_client_#{rem(task_id, 100)}",
                     "resource" => "api"
                   }) do
                {:ok, _status, _body} ->
                  req_end = System.monotonic_time(:millisecond)
                  {:ok, req_end - req_start}

                {:error, reason} ->
                  {:error, reason}
              end

            result
          end)
        end)
        |> Enum.map(&Task.await(&1, :infinity))

      spawn_elapsed = System.monotonic_time(:millisecond) - spawn_start
      IO.puts("All tasks spawned in #{spawn_elapsed}ms")

      elapsed = System.monotonic_time(:millisecond) - start_time

      successes = Enum.count(results, fn r -> match?({:ok, _}, r) end)
      errors = concurrency - successes
      error_rate = errors / concurrency * 100

      latencies =
        results
        |> Enum.filter(fn r -> match?({:ok, _}, r) end)
        |> Enum.map(fn {:ok, lat} -> lat end)

      throughput = concurrency / (elapsed / 1000)

      IO.puts("\nExtreme Load Results:")
      IO.puts("  Total Connections: #{concurrency}")
      IO.puts("  Total Time: #{elapsed}ms (#{Float.round(elapsed / 1000, 2)}s)")
      IO.puts("  Throughput: #{Float.round(throughput, 2)} req/s")
      IO.puts("  Successful: #{successes}")
      IO.puts("  Errors: #{errors} (#{Float.round(error_rate, 2)}%)")

      if length(latencies) > 0 do
        stats = calculate_stats(latencies)

        IO.puts("  Latency Stats (successful requests):")
        IO.puts("    Min: #{stats.min}ms")
        IO.puts("    Avg: #{Float.round(stats.avg, 2)}ms")
        IO.puts("    Median: #{stats.median}ms")
        IO.puts("    P95: #{stats.p95}ms")
        IO.puts("    P99: #{stats.p99}ms")
        IO.puts("    Max: #{stats.max}ms")
      end

      # Group errors by type if any
      if errors > 0 do
        error_types =
          results
          |> Enum.filter(fn r -> match?({:error, _}, r) end)
          |> Enum.map(fn {:error, reason} -> inspect(reason) end)
          |> Enum.frequencies()

        IO.puts("\n  Error Breakdown:")

        Enum.each(error_types, fn {type, count} ->
          IO.puts("    #{type}: #{count} (#{Float.round(count / errors * 100, 2)}%)")
        end)
      end

      IO.puts("\n=== Extreme Load Analysis ===")

      if error_rate < 5.0 do
        IO.puts("✓ System handled #inspect{(@extreme)} concurrent connections with < 5% errors")
      else
        IO.puts(
          "⚠ System saturated at #inspect{(@extreme)} connections (#{Float.round(error_rate, 2)}% error rate)"
        )
      end

      # The assertion is lenient for extreme load - we expect some errors
      assert error_rate < 20.0,
        "Error rate should be < 20% even under extreme load (#inspect{(@extreme)} connections)"

      assert throughput > 1000, "Should maintain > 1000 req/s even under extreme load"
    end
  end

  describe "Burst Load Testing" do
    test "handles burst traffic patterns" do
      IO.puts("\n=== Burst Load Test ===")
      IO.puts("Testing system response to sudden traffic bursts...")

      # Normal load: 10 connections
      # Burst load: 200 connections
      # Pattern: 5s normal -> 10s burst -> 5s normal

      IO.puts("\nPhase 1: Normal load (10 connections, 5 seconds)...")
      phase1_start = System.monotonic_time(:millisecond)
      phase1_results = run_burst_phase(10, 5_000, "normal1")
      phase1_elapsed = System.monotonic_time(:millisecond) - phase1_start

      Process.sleep(1000)

      IO.puts("\nPhase 2: BURST load (200 connections, 10 seconds)...")
      phase2_start = System.monotonic_time(:millisecond)
      phase2_results = run_burst_phase(200, 10_000, "burst")
      phase2_elapsed = System.monotonic_time(:millisecond) - phase2_start

      Process.sleep(1000)

      IO.puts("\nPhase 3: BURST load (5000 connections, 30 seconds)...")
      phase3_start = System.monotonic_time(:millisecond)
      phase3_results = run_burst_phase(5000, 30_000, "burst")
      phase3_elapsed = System.monotonic_time(:millisecond) - phase3_start

      Process.sleep(1000)

      IO.puts("\nPhase 4: Recovery to normal (10 connections, 5 seconds)...")
      phase4_start = System.monotonic_time(:millisecond)
      phase4_results = run_burst_phase(10, 5_000, "normal2")
      phase4_elapsed = System.monotonic_time(:millisecond) - phase4_start

      # Analyze results
      print_burst_results("Phase 1 (Normal)", phase1_results, phase1_elapsed)
      print_burst_results("Phase 2 (Burst)", phase2_results, phase2_elapsed)
      print_burst_results("Phase 3 (Burst)", phase3_results, phase3_elapsed)
      print_burst_results("Phase 4 (Recovery)", phase4_results, phase4_elapsed)

      IO.puts("\n=== Burst Test Analysis ===")
      phase2_error_rate = phase2_results.errors / phase2_results.requests * 100

      IO.puts("Burst phase error rate: #{Float.round(phase2_error_rate, 2)}% (should be < 10%)")

      assert phase2_error_rate < 10.0, "Burst error rate should be < 10%"
    end
  end

  defp run_burst_phase(concurrency, duration_ms, prefix) do
    start_time = System.monotonic_time(:millisecond)
    end_time = start_time + duration_ms

    tasks =
      1..concurrency
      |> Enum.map(fn task_id ->
        Task.async(fn ->
          requests = 0
          errors = 0
          latencies = []

          {requests, errors, latencies} =
            Stream.cycle([1])
            |> Enum.reduce_while({requests, errors, latencies}, fn _, {reqs, errs, lats} ->
              current_time = System.monotonic_time(:millisecond)

              if current_time < end_time do
                req_start = System.monotonic_time(:millisecond)

                case http_post(@ratelimit_endpoint, %{
                       "client_id" => "#{prefix}_client_#{task_id}",
                       "resource" => "api"
                     }) do
                  {:ok, _status, _body} ->
                    req_end = System.monotonic_time(:millisecond)
                    {:cont, {reqs + 1, errs, [req_end - req_start | lats]}}

                  {:error, _reason} ->
                    {:cont, {reqs + 1, errs + 1, lats}}
                end
              else
                {:halt, {reqs, errs, lats}}
              end
            end)

          %{requests: requests, errors: errors, latencies: latencies}
        end)
      end)

    results = Enum.map(tasks, &Task.await(&1, :infinity))

    %{
      requests: Enum.sum(Enum.map(results, & &1.requests)),
      errors: Enum.sum(Enum.map(results, & &1.errors)),
      latencies: Enum.flat_map(results, & &1.latencies)
    }
  end

  defp print_burst_results(phase_name, results, elapsed) do
    throughput = results.requests / (elapsed / 1000)
    error_rate = results.errors / results.requests * 100
    stats = calculate_stats(results.latencies)

    IO.puts("\n#{phase_name}:")
    IO.puts("  Requests: #{results.requests}")
    IO.puts("  Throughput: #{Float.round(throughput, 2)} req/s")
    IO.puts("  Errors: #{results.errors} (#{Float.round(error_rate, 2)}%)")
    IO.puts("  Latency P95: #{stats.p95}ms, Max: #{stats.max}ms")
  end
end
