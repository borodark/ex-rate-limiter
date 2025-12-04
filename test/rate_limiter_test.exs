defmodule RateLimiterTest do
  use ExUnit.Case, async: true

  setup do
    # RateLimiter is started by the application supervision tree
    # Reset state before each test
    :ok = RateLimiter.RateLimiter.reset()
    :ok
  end

  describe "check_rate_limit/2" do
    test "allows request when under limit" do
      {:ok, response} = RateLimiter.RateLimiter.check_rate_limit("client1", "resource1")

      assert response.allowed == true
      assert response.remaining == 99
      assert not Map.has_key?(response, :retry_after)
    end

    test "tracks remaining requests correctly" do
      limit = 100
      {:ok, config} = RateLimiter.RateLimiter.configure(60, limit)
      assert config.requests_per_window == limit

      # Make requests and verify remaining count decreases
      for i <- 1..10 do
        {:ok, response} = RateLimiter.RateLimiter.check_rate_limit("client_a", "resource")
        assert response.allowed == true
        assert response.remaining == limit - i
      end
    end

    test "denies request when limit exceeded" do
      {:ok, _} = RateLimiter.RateLimiter.configure(60, 5)

      # Fill up the limit
      for _ <- 1..5 do
        {:ok, response} = RateLimiter.RateLimiter.check_rate_limit("client_b", "resource")
        assert response.allowed == true
      end

      # Next request should be denied
      {:ok, response} = RateLimiter.RateLimiter.check_rate_limit("client_b", "resource")
      assert response.allowed == false
      assert response.remaining == 0
      assert is_integer(response.retry_after)
      assert response.retry_after >= 1
    end

    test "has correct retry_after value" do
      {:ok, _} = RateLimiter.RateLimiter.configure(2, 2)

      # Use up the limit
      {:ok, _} = RateLimiter.RateLimiter.check_rate_limit("client_c", "resource")
      {:ok, _} = RateLimiter.RateLimiter.check_rate_limit("client_c", "resource")

      # Next request is denied with retry_after
      {:ok, response} = RateLimiter.RateLimiter.check_rate_limit("client_c", "resource")
      assert response.allowed == false
      # retry_after should be between 1 and 2 seconds
      assert response.retry_after >= 1
      assert response.retry_after <= 2
    end

    test "isolates limits per client" do
      {:ok, _} = RateLimiter.RateLimiter.configure(60, 3)

      # client_d uses up limit
      for _ <- 1..3 do
        {:ok, response} = RateLimiter.RateLimiter.check_rate_limit("client_d", "resource")
        assert response.allowed == true
      end

      # client_d is now limited
      {:ok, response} = RateLimiter.RateLimiter.check_rate_limit("client_d", "resource")
      assert response.allowed == false

      # client_e should still have requests available
      {:ok, response} = RateLimiter.RateLimiter.check_rate_limit("client_e", "resource")
      assert response.allowed == true
      assert response.remaining == 2
    end

    test "ignores resource parameter for same client" do
      {:ok, _} = RateLimiter.RateLimiter.configure(60, 2)

      # Use different resources but same client
      {:ok, r1} = RateLimiter.RateLimiter.check_rate_limit("client_f", "resource1")
      {:ok, r2} = RateLimiter.RateLimiter.check_rate_limit("client_f", "resource2")

      # Both should count against same client limit
      assert r1.allowed == true
      assert r1.remaining == 1
      assert r2.allowed == true
      assert r2.remaining == 0

      # Third request should be denied
      {:ok, r3} = RateLimiter.RateLimiter.check_rate_limit("client_f", "resource3")
      assert r3.allowed == false
    end

    test "resets after window expires" do
      {:ok, _} = RateLimiter.RateLimiter.configure(1, 2)

      # Use up the limit
      {:ok, _} = RateLimiter.RateLimiter.check_rate_limit("client_g", "resource")
      {:ok, _} = RateLimiter.RateLimiter.check_rate_limit("client_g", "resource")

      # Next request is denied
      {:ok, response} = RateLimiter.RateLimiter.check_rate_limit("client_g", "resource")
      assert response.allowed == false

      # Wait for window to expire
      Process.sleep(1100)

      # Should allow again
      {:ok, response} = RateLimiter.RateLimiter.check_rate_limit("client_g", "resource")
      assert response.allowed == true
      assert response.remaining == 1
    end
  end

  describe "configure/2" do
    test "updates window_seconds" do
      {:ok, config} = RateLimiter.RateLimiter.configure(120, 100)
      assert config.window_seconds == 120
      assert config.requests_per_window == 100
    end

    test "updates request_per_window" do
      {:ok, config} = RateLimiter.RateLimiter.configure(60, 50)
      assert config.window_seconds == 60
      assert config.requests_per_window == 50
    end

    test "applies configuration immediately" do
      {:ok, _} = RateLimiter.RateLimiter.configure(60, 3)

      # Fill up to new limit
      for _ <- 1..3 do
        {:ok, response} = RateLimiter.RateLimiter.check_rate_limit("client_h", "resource")
        assert response.allowed == true
      end

      # Now limited
      {:ok, response} = RateLimiter.RateLimiter.check_rate_limit("client_h", "resource")
      assert response.allowed == false

      # Reconfigure with higher limit
      {:ok, _} = RateLimiter.RateLimiter.configure(60, 5)

      # Should now allow more requests (the 3 old requests are still tracked)
      # But we should be able to make more requests
      {:ok, response} = RateLimiter.RateLimiter.check_rate_limit("client_h", "resource")
      assert response.allowed == true
      assert response.remaining == 1
    end
  end

  describe "get_config/0" do
    test "returns current configuration" do
      {:ok, _} = RateLimiter.RateLimiter.configure(90, 75)
      {:ok, config} = RateLimiter.RateLimiter.get_config()

      assert config.window_seconds == 90
      assert config.requests_per_window == 75
    end

    test "returns default configuration initially" do
      {:ok, config} = RateLimiter.RateLimiter.get_config()

      assert config.window_seconds == 60
      assert config.requests_per_window == 100
    end
  end

  describe "concurrent requests" do
    test "handles concurrent requests from multiple clients" do
      {:ok, _} = RateLimiter.RateLimiter.configure(60, 50)

      # Spawn multiple processes making requests concurrently
      tasks =
        for client_id <- 1..10 do
          Task.async(fn ->
            for _ <- 1..5 do
              RateLimiter.RateLimiter.check_rate_limit("client_#{client_id}", "resource")
            end
          end)
        end

      # Collect results
      results = Task.await_many(tasks)

      # All requests should succeed since each client only makes 5 requests
      # and limit is 50
      Enum.each(results, fn client_results ->
        Enum.each(client_results, fn {:ok, response} ->
          assert response.allowed == true
        end)
      end)
    end

    test "handles concurrent requests from same client" do
      {:ok, _} = RateLimiter.RateLimiter.configure(60, 10)

      # Spawn multiple processes for same client
      tasks =
        for _ <- 1..15 do
          Task.async(fn ->
            RateLimiter.RateLimiter.check_rate_limit("concurrent_client", "resource")
          end)
        end

      results = Task.await_many(tasks)

      # Should allow first 10, deny rest
      allowed_count = Enum.count(results, fn {:ok, response} -> response.allowed end)
      denied_count = Enum.count(results, fn {:ok, response} -> not response.allowed end)

      assert allowed_count == 10
      assert denied_count == 5
    end

    test "maintains consistency under concurrent load" do
      {:ok, _} = RateLimiter.RateLimiter.configure(60, 50)

      # Heavy concurrent load
      tasks =
        for _ <- 1..100 do
          Task.async(fn ->
            RateLimiter.RateLimiter.check_rate_limit("heavy_client", "resource")
          end)
        end

      results = Task.await_many(tasks)

      # First 50 should be allowed, rest denied
      allowed = Enum.filter(results, fn {:ok, r} -> r.allowed end)
      denied = Enum.filter(results, fn {:ok, r} -> not r.allowed end)

      assert Enum.count(allowed) == 50
      assert Enum.count(denied) == 50

      # Verify remaining is correct in denied responses
      Enum.each(denied, fn {:ok, response} ->
        assert response.remaining == 0
        assert response.retry_after >= 1
      end)
    end
  end

  describe "edge cases" do
    test "handles empty client_id" do
      {:ok, response} = RateLimiter.RateLimiter.check_rate_limit("", "resource")
      assert response.allowed == true
      # Empty string is still a valid client_id, just gets tracked
    end

    test "handles long client_id" do
      long_id = String.duplicate("x", 10000)
      {:ok, response} = RateLimiter.RateLimiter.check_rate_limit(long_id, "resource")
      assert response.allowed == true
    end

    test "handles special characters in client_id" do
      special_ids = ["client@example.com", "user:123", "client/resource", "client#1"]

      Enum.each(special_ids, fn client_id ->
        {:ok, response} = RateLimiter.RateLimiter.check_rate_limit(client_id, "resource")
        assert response.allowed == true
      end)
    end

    test "handles very high request limit" do
      {:ok, _} = RateLimiter.RateLimiter.configure(60, 1_000_000)

      # Should handle large numbers
      {:ok, response} = RateLimiter.RateLimiter.check_rate_limit("big_limit_client", "resource")
      assert response.allowed == true
      assert response.remaining == 999_999
    end

    test "handles very small window" do
      {:ok, _} = RateLimiter.RateLimiter.configure(1, 5)

      for _ <- 1..5 do
        {:ok, response} = RateLimiter.RateLimiter.check_rate_limit("small_window", "resource")
        assert response.allowed == true
      end

      {:ok, response} = RateLimiter.RateLimiter.check_rate_limit("small_window", "resource")
      assert response.allowed == false
      assert response.retry_after >= 1
      assert response.retry_after <= 1
    end
  end

  describe "memory management" do
    test "cleanup removes expired entries" do
      {:ok, _} = RateLimiter.RateLimiter.configure(1, 100)

      # Create entries for multiple clients
      for i <- 1..5 do
        for _ <- 1..3 do
          RateLimiter.RateLimiter.check_rate_limit("cleanup_client_#{i}", "resource")
        end
      end

      # Wait for window to expire and cleanup to run (30 seconds default, but we can observe)
      # For now, just verify that old entries are removed on next check
      Process.sleep(1100)

      {:ok, response} = RateLimiter.RateLimiter.check_rate_limit("cleanup_client_1", "resource")
      assert response.allowed == true
      assert response.remaining == 99
    end
  end

  describe "per-client custom configuration" do
    test "configure_client sets custom limit for specific client" do
      # Set global config
      {:ok, _} = RateLimiter.RateLimiter.configure(60, 10)

      # Set custom limit for client_a: 5 requests per 60 seconds
      {:ok, config} = RateLimiter.RateLimiter.configure_client("client_a", 60, 5)
      assert config.window_seconds == 60
      assert config.requests_per_window == 5

      # Verify client_a has custom limit
      for i <- 1..5 do
        {:ok, response} = RateLimiter.RateLimiter.check_rate_limit("client_a", "resource")
        assert response.allowed == true
        assert response.remaining == 5 - i
      end

      # 6th request should be denied
      {:ok, response} = RateLimiter.RateLimiter.check_rate_limit("client_a", "resource")
      assert response.allowed == false
      assert response.remaining == 0
    end

    test "global config still applies to non-configured clients" do
      # Set global config
      {:ok, _} = RateLimiter.RateLimiter.configure(60, 10)

      # Set custom limit for client_a
      {:ok, _} = RateLimiter.RateLimiter.configure_client("client_a", 60, 5)

      # client_b should use global config (10 requests)
      for i <- 1..10 do
        {:ok, response} = RateLimiter.RateLimiter.check_rate_limit("client_b", "resource")
        assert response.allowed == true
        assert response.remaining == 10 - i
      end

      # 11th request should be denied
      {:ok, response} = RateLimiter.RateLimiter.check_rate_limit("client_b", "resource")
      assert response.allowed == false
      assert response.remaining == 0
    end

    test "different clients can have different limits" do
      # Set global config
      {:ok, _} = RateLimiter.RateLimiter.configure(60, 100)

      # Set different limits for different clients
      {:ok, _} = RateLimiter.RateLimiter.configure_client("vip_client", 60, 50)
      {:ok, _} = RateLimiter.RateLimiter.configure_client("basic_client", 60, 5)

      # VIP client can make 50 requests
      for _ <- 1..50 do
        {:ok, response} = RateLimiter.RateLimiter.check_rate_limit("vip_client", "resource")
        assert response.allowed == true
      end

      # 51st request denied for VIP
      {:ok, response} = RateLimiter.RateLimiter.check_rate_limit("vip_client", "resource")
      assert response.allowed == false

      # Basic client limited to 5 requests
      for _ <- 1..5 do
        {:ok, response} = RateLimiter.RateLimiter.check_rate_limit("basic_client", "resource")
        assert response.allowed == true
      end

      # 6th request denied for basic
      {:ok, response} = RateLimiter.RateLimiter.check_rate_limit("basic_client", "resource")
      assert response.allowed == false
    end

    test "get_client_config returns custom config if set" do
      # Set global config
      {:ok, global_config} = RateLimiter.RateLimiter.configure(60, 100)

      # Get config for unconfigured client (should return global)
      {:ok, config} = RateLimiter.RateLimiter.get_client_config("unconfigured")
      assert config == global_config

      # Set custom config
      {:ok, custom_config} = RateLimiter.RateLimiter.configure_client("configured", 30, 50)

      # Get config for configured client (should return custom)
      {:ok, config} = RateLimiter.RateLimiter.get_client_config("configured")
      assert config == custom_config
      assert config.window_seconds == 30
      assert config.requests_per_window == 50
    end

    test "reset_client_config reverts to global config" do
      # Set global config
      {:ok, global_config} = RateLimiter.RateLimiter.configure(60, 100)

      # Set custom config
      {:ok, _} = RateLimiter.RateLimiter.configure_client("client_x", 30, 50)

      # Verify custom config is active
      {:ok, config} = RateLimiter.RateLimiter.get_client_config("client_x")
      assert config.window_seconds == 30

      # Reset client config
      :ok = RateLimiter.RateLimiter.reset_client_config("client_x")

      # Verify reverted to global config
      {:ok, config} = RateLimiter.RateLimiter.get_client_config("client_x")
      assert config == global_config
    end

    test "multiple clients with different windows work correctly" do
      # Set global config with 60 second window
      {:ok, _} = RateLimiter.RateLimiter.configure(60, 10)

      # Set fast client with 1 second window
      {:ok, _} = RateLimiter.RateLimiter.configure_client("fast_client", 1, 5)

      # Fast client can make 5 requests quickly
      for _ <- 1..5 do
        {:ok, response} = RateLimiter.RateLimiter.check_rate_limit("fast_client", "resource")
        assert response.allowed == true
      end

      # 6th request denied
      {:ok, response} = RateLimiter.RateLimiter.check_rate_limit("fast_client", "resource")
      assert response.allowed == false

      # Wait for 1 second (fast client's window expires)
      Process.sleep(1100)

      # Now fast client can make requests again
      {:ok, response} = RateLimiter.RateLimiter.check_rate_limit("fast_client", "resource")
      assert response.allowed == true
      assert response.remaining == 4

      # Normal client still uses 60 second window
      for _ <- 1..10 do
        {:ok, response} = RateLimiter.RateLimiter.check_rate_limit("normal_client", "resource")
        assert response.allowed == true
      end

      {:ok, response} = RateLimiter.RateLimiter.check_rate_limit("normal_client", "resource")
      assert response.allowed == false
    end

    test "configuring same client multiple times updates config" do
      {:ok, _} = RateLimiter.RateLimiter.configure(60, 100)

      # Set initial custom config
      {:ok, _} = RateLimiter.RateLimiter.configure_client("dynamic_client", 60, 5)

      # Use 3 requests
      for _ <- 1..3 do
        RateLimiter.RateLimiter.check_rate_limit("dynamic_client", "resource")
      end

      # Reconfigure with higher limit
      {:ok, _} = RateLimiter.RateLimiter.configure_client("dynamic_client", 60, 20)

      # New config takes effect - can now make more requests
      for i <- 4..20 do
        {:ok, response} = RateLimiter.RateLimiter.check_rate_limit("dynamic_client", "resource")
        assert response.allowed == true
        # Remaining should be based on new limit, but old timestamp still counts
        assert response.remaining <= 20 - i
      end
    end
  end
end
