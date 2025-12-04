defmodule RateLimiterWeb.RateLimitController do
  use RateLimiterWeb, :controller
  require Logger

  @doc """
  POST /api/v1/ratelimit

  Checks if a request from a client should be allowed.
  """
  def check(conn, params) do
    with {:ok, client_id} <- validate_client_id(params),
         {:ok, resource} <- validate_resource(params),
         {:ok, response} <- RateLimiter.RateLimiter.check_rate_limit(client_id, resource) do
      json(conn, response)
    else
      {:error, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: message})
    end
  end

  @doc """
  POST /api/v1/configure

  Updates the rate limiting configuration.
  """
  def configure(conn, params) do
    with {:ok, window} <- validate_window(params),
         {:ok, limit} <- validate_limit(params),
         {:ok, config} <- RateLimiter.RateLimiter.configure(window, limit) do
      json(conn, config)
    else
      {:error, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: message})
    end
  end

  @doc """
  POST /api/v1/configure-client

  Sets custom rate limiting configuration for a specific client.
  """
  def configure_client(conn, params) do
    with {:ok, client_id} <- validate_client_id(params),
         {:ok, window} <- validate_window(params),
         {:ok, limit} <- validate_limit(params),
         {:ok, config} <- RateLimiter.RateLimiter.configure_client(client_id, window, limit) do
      json(conn, config)
    else
      {:error, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: message})
    end
  end

  @doc """
  GET /api/v1/client-config/:client_id

  Gets the rate limiting configuration for a specific client.
  """
  def get_client_config(conn, %{"client_id" => client_id}) do
    with {:ok, client_id} <- validate_client_id(%{"client_id" => client_id}),
         {:ok, config} <- RateLimiter.RateLimiter.get_client_config(client_id) do
      json(conn, config)
    else
      {:error, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: message})
    end
  end

  @doc """
  DELETE /api/v1/client-config/:client_id

  Removes custom rate limiting configuration for a client (reverts to global config).
  """
  def reset_client_config(conn, %{"client_id" => client_id}) do
    with {:ok, client_id} <- validate_client_id(%{"client_id" => client_id}),
         :ok <- RateLimiter.RateLimiter.reset_client_config(client_id) do
      json(conn, %{status: "ok", message: "Client configuration reset"})
    else
      {:error, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: message})
    end
  end

  # ============================================================================
  # Validation Helpers
  # ============================================================================

  defp validate_client_id(params) do
    case Map.get(params, "client_id") do
      nil -> {:error, "Missing required field: client_id"}
      "" -> {:error, "client_id cannot be empty"}
      client_id -> {:ok, client_id}
    end
  end

  defp validate_resource(params) do
    case Map.get(params, "resource") do
      nil -> {:error, "Missing required field: resource"}
      "" -> {:error, "resource cannot be empty"}
      resource -> {:ok, resource}
    end
  end

  defp validate_window(params) do
    case params do
      %{"window_seconds" => window} when is_integer(window) and window > 0 ->
        {:ok, window}

      %{"window_seconds" => window} when is_binary(window) ->
        case Integer.parse(window) do
          {n, ""} when n > 0 -> {:ok, n}
          _ -> {:error, "window_seconds must be a positive integer"}
        end

      _ ->
        {:error, "Missing or invalid required field: window_seconds (must be positive integer)"}
    end
  end

  defp validate_limit(params) do
    case params do
      %{"request_per_window" => limit} when is_integer(limit) and limit > 0 ->
        {:ok, limit}

      %{"request_per_window" => limit} when is_binary(limit) ->
        case Integer.parse(limit) do
          {n, ""} when n > 0 -> {:ok, n}
          _ -> {:error, "request_per_window must be a positive integer"}
        end

      _ ->
        {:error, "Missing or invalid required field: request_per_window (must be positive integer)"}
    end
  end
end
