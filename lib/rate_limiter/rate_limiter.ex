defmodule RateLimiter.RateLimiter do
  @moduledoc """
  A GenServer-based rate limiter that uses a sliding window algorithm
  to track and limit request rates per client.

  ## Overview
  - Tracks request timestamps in a sliding window per client
  - Automatically cleans up expired entries to prevent memory leaks
  - Configurable time window and request limit
  """

  use GenServer

  @default_window_seconds 60
  @default_requests_per_window 100
  # Clean up every 30 seconds
  @cleanup_interval 30_000

  # Type definitions
  @type client_id :: String.t()
  @type resource :: String.t()
  @type timestamp :: integer()
  @type config :: %{window_seconds: pos_integer(), requests_per_window: pos_integer()}
  @type allowed_response :: %{allowed: true, remaining: non_neg_integer()}
  @type denied_response :: %{allowed: false, remaining: 0, retry_after: non_neg_integer()}
  @type rate_limit_response :: allowed_response() | denied_response()
  @type state :: %{
          clients: %{client_id() => [timestamp()]},
          config: config(),
          client_configs: %{client_id() => config()}
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts the RateLimiter GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks if a request from a client should be allowed.

  Returns a tuple:
  - {:ok, %{allowed: true, remaining: integer}} when request is allowed
  - {:ok, %{allowed: false, remaining: integer, retry_after: integer}} when request is denied
  """
  @spec check_rate_limit(client_id(), resource()) :: {:ok, rate_limit_response()}
  def check_rate_limit(client_id, resource) do
    GenServer.call(__MODULE__, {:check_rate_limit, client_id, resource})
  end

  @doc """
  Updates the global rate limiting configuration.

  Returns the updated configuration.
  """
  @spec configure(pos_integer(), pos_integer()) :: {:ok, config()}
  def configure(window_seconds, requests_per_window) do
    GenServer.call(__MODULE__, {:configure, window_seconds, requests_per_window})
  end

  @doc """
  Sets a custom rate limit configuration for a specific client.

  Returns the client-specific configuration.
  """
  @spec configure_client(client_id(), pos_integer(), pos_integer()) :: {:ok, config()}
  def configure_client(client_id, window_seconds, requests_per_window) do
    GenServer.call(
      __MODULE__,
      {:configure_client, client_id, window_seconds, requests_per_window}
    )
  end

  @doc """
  Removes custom configuration for a client (falls back to global config).
  """
  @spec reset_client_config(client_id()) :: :ok
  def reset_client_config(client_id) do
    GenServer.call(__MODULE__, {:reset_client_config, client_id})
  end

  @doc """
  Gets current global configuration.
  """
  @spec get_config() :: {:ok, config()}
  def get_config do
    GenServer.call(__MODULE__, :get_config)
  end

  @doc """
  Gets configuration for a specific client (includes custom if set, else global).
  """
  @spec get_client_config(client_id()) :: {:ok, config()}
  def get_client_config(client_id) do
    GenServer.call(__MODULE__, {:get_client_config, client_id})
  end

  @doc """
  Resets all state (for testing only).
  """
  @spec reset() :: :ok
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(_opts) do
    # Start cleanup timer
    schedule_cleanup()

    state = %{
      # Per-client request tracking: %{client_id => [timestamps]}
      clients: %{},
      # Global configuration
      config: %{
        window_seconds: @default_window_seconds,
        requests_per_window: @default_requests_per_window
      },
      # Per-client custom configuration (overrides global): %{client_id => %{window_seconds: ..., requests_per_window: ...}}
      client_configs: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:check_rate_limit, client_id, _resource}, _from, state) do
    now = System.monotonic_time(:millisecond)

    # Get or initialize client's request list
    timestamps = Map.get(state.clients, client_id, [])

    # Get the configuration for this client (use custom if set, else global)
    client_config = Map.get(state.client_configs, client_id, state.config)
    window_ms = client_config.window_seconds * 1000
    limit = client_config.requests_per_window

    # Clean up old timestamps outside the window
    clean_timestamps = Enum.filter(timestamps, &(now - &1 < window_ms))

    # Check if we're under the limit
    requests_count = length(clean_timestamps)

    if requests_count < limit do
      # Allow the request
      new_timestamps = [now | clean_timestamps]
      new_clients = Map.put(state.clients, client_id, new_timestamps)
      new_state = %{state | clients: new_clients}

      response = %{
        allowed: true,
        remaining: limit - (requests_count + 1)
      }

      {:reply, {:ok, response}, new_state}
    else
      # Deny the request
      oldest_timestamp = List.last(clean_timestamps)
      time_until_oldest_expires = window_ms - (now - oldest_timestamp)
      retry_after_seconds = ceil(time_until_oldest_expires / 1000)

      response = %{
        allowed: false,
        remaining: 0,
        retry_after: max(1, retry_after_seconds)
      }

      {:reply, {:ok, response}, state}
    end
  end

  @impl true
  def handle_call({:configure, window_seconds, requests_per_window}, _from, state) do
    new_config = %{
      window_seconds: window_seconds,
      requests_per_window: requests_per_window
    }

    new_state = %{state | config: new_config}

    {:reply, {:ok, new_config}, new_state}
  end

  @impl true
  def handle_call(
        {:configure_client, client_id, window_seconds, requests_per_window},
        _from,
        state
      ) do
    client_config = %{
      window_seconds: window_seconds,
      requests_per_window: requests_per_window
    }

    new_client_configs = Map.put(state.client_configs, client_id, client_config)
    new_state = %{state | client_configs: new_client_configs}

    {:reply, {:ok, client_config}, new_state}
  end

  @impl true
  def handle_call({:reset_client_config, client_id}, _from, state) do
    new_client_configs = Map.delete(state.client_configs, client_id)
    new_state = %{state | client_configs: new_client_configs}

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:get_client_config, client_id}, _from, state) do
    # Return client-specific config if set, else global config
    config = Map.get(state.client_configs, client_id, state.config)
    {:reply, {:ok, config}, state}
  end

  @impl true
  def handle_call(:get_config, _from, state) do
    {:reply, {:ok, state.config}, state}
  end

  @impl true
  def handle_call(:reset, _from, _state) do
    state = %{
      clients: %{},
      config: %{
        window_seconds: @default_window_seconds,
        requests_per_window: @default_requests_per_window
      },
      client_configs: %{}
    }

    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:millisecond)
    window_ms = state.config.window_seconds * 1000

    # Remove clients with all expired timestamps
    new_clients =
      state.clients
      |> Enum.reduce(%{}, fn {client_id, timestamps}, acc ->
        clean_timestamps = Enum.filter(timestamps, &(now - &1 < window_ms))

        if Enum.empty?(clean_timestamps) do
          acc
        else
          Map.put(acc, client_id, clean_timestamps)
        end
      end)

    new_state = %{state | clients: new_clients}

    # Reschedule cleanup
    schedule_cleanup()

    {:noreply, new_state}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  @spec schedule_cleanup() :: reference()
  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
