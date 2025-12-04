defmodule RateLimiterWeb.RateLimitControllerTest do
  use ExUnit.Case

  setup do
    # Reset state before each test
    :ok = RateLimiter.RateLimiter.reset()
    {:ok, _} = RateLimiter.RateLimiter.configure(60, 5)
    :ok
  end

  describe "rate limit check" do
    test "allows valid request" do
      {:ok, response} = RateLimiter.RateLimiter.check_rate_limit("client", "resource")
      assert response.allowed == true
      assert is_integer(response.remaining)
    end

    test "denies request when limit exceeded" do
      {:ok, _} = RateLimiter.RateLimiter.configure(60, 2)

      {:ok, r1} = RateLimiter.RateLimiter.check_rate_limit("client", "resource")
      {:ok, r2} = RateLimiter.RateLimiter.check_rate_limit("client", "resource")

      # Next should be denied
      {:ok, r3} = RateLimiter.RateLimiter.check_rate_limit("client", "resource")
      assert r1.allowed == true
      assert r2.allowed == true
      assert r3.allowed == false
    end
  end

  describe "configuration" do
    test "allows valid configuration" do
      {:ok, config} = RateLimiter.RateLimiter.configure(120, 50)
      assert config.window_seconds == 120
      assert config.requests_per_window == 50
    end

    test "applies configuration to rate limiting" do
      {:ok, _} = RateLimiter.RateLimiter.configure(60, 2)

      {:ok, r1} = RateLimiter.RateLimiter.check_rate_limit("client", "resource")
      {:ok, r2} = RateLimiter.RateLimiter.check_rate_limit("client", "resource")

      # Next should be denied
      {:ok, r3} = RateLimiter.RateLimiter.check_rate_limit("client", "resource")
      assert r1.allowed == true
      assert r2.allowed == true
      assert r3.allowed == false
    end
  end

  describe "response structure" do
    test "ratelimit check returns correct fields" do
      {:ok, response} = RateLimiter.RateLimiter.check_rate_limit("client", "resource")

      assert Map.has_key?(response, :allowed)
      assert Map.has_key?(response, :remaining)
      assert is_boolean(response.allowed)
      assert is_integer(response.remaining)
    end

    test "denied request includes retry_after" do
      {:ok, _} = RateLimiter.RateLimiter.configure(60, 1)

      {:ok, _} = RateLimiter.RateLimiter.check_rate_limit("client", "resource")
      {:ok, response} = RateLimiter.RateLimiter.check_rate_limit("client", "resource")

      assert response.allowed == false
      assert Map.has_key?(response, :retry_after)
      assert is_integer(response.retry_after)
      assert response.retry_after >= 1
    end

    test "configure returns correct fields" do
      {:ok, config} = RateLimiter.RateLimiter.configure(90, 75)

      assert Map.has_key?(config, :window_seconds)
      assert Map.has_key?(config, :requests_per_window)
      assert config.window_seconds == 90
      assert config.requests_per_window == 75
    end
  end

  describe "end-to-end workflows" do
    test "client can check rate limit and get accurate remaining count" do
      {:ok, _} = RateLimiter.RateLimiter.configure(60, 3)

      {:ok, r1} = RateLimiter.RateLimiter.check_rate_limit("user1", "api")
      assert r1.allowed == true
      assert r1.remaining == 2

      {:ok, r2} = RateLimiter.RateLimiter.check_rate_limit("user1", "api")
      assert r2.allowed == true
      assert r2.remaining == 1

      {:ok, r3} = RateLimiter.RateLimiter.check_rate_limit("user1", "api")
      assert r3.allowed == true
      assert r3.remaining == 0

      {:ok, r4} = RateLimiter.RateLimiter.check_rate_limit("user1", "api")
      assert r4.allowed == false
      assert r4.remaining == 0
    end

    test "reconfiguring allows new requests after hitting limit" do
      {:ok, _} = RateLimiter.RateLimiter.configure(60, 2)

      # Hit the limit
      {:ok, _} = RateLimiter.RateLimiter.check_rate_limit("client", "api")
      {:ok, _} = RateLimiter.RateLimiter.check_rate_limit("client", "api")
      {:ok, denied} = RateLimiter.RateLimiter.check_rate_limit("client", "api")
      assert denied.allowed == false

      # Reconfigure with higher limit
      {:ok, _} = RateLimiter.RateLimiter.configure(60, 5)

      # Can now make more requests (old ones still count)
      {:ok, allowed} = RateLimiter.RateLimiter.check_rate_limit("client", "api")
      assert allowed.allowed == true
      assert allowed.remaining == 2
    end

    test "multiple clients have independent limits" do
      {:ok, _} = RateLimiter.RateLimiter.configure(60, 2)

      # Client A uses both requests
      {:ok, a1} = RateLimiter.RateLimiter.check_rate_limit("alice", "api")
      {:ok, a2} = RateLimiter.RateLimiter.check_rate_limit("alice", "api")
      assert a1.allowed == true
      assert a2.allowed == true

      # Client B still has full quota
      {:ok, b1} = RateLimiter.RateLimiter.check_rate_limit("bob", "api")
      assert b1.allowed == true
      assert b1.remaining == 1

      {:ok, b2} = RateLimiter.RateLimiter.check_rate_limit("bob", "api")
      assert b2.allowed == true
      assert b2.remaining == 0

      # Both are now limited
      {:ok, a_denied} = RateLimiter.RateLimiter.check_rate_limit("alice", "api")
      {:ok, b_denied} = RateLimiter.RateLimiter.check_rate_limit("bob", "api")
      assert a_denied.allowed == false
      assert b_denied.allowed == false
    end
  end
end
