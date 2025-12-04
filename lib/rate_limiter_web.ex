defmodule RateLimiterWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such as controllers and channels.
  """

  def router do
    quote do
      use Phoenix.Router, helpers: false
      import Plug.Conn
      import Phoenix.Controller
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:json]
      import Plug.Conn
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: RateLimiterWeb.Endpoint,
        router: RateLimiterWeb.Router,
        statics: RateLimiterWeb.static_paths()
    end
  end

  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
