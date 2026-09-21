defmodule MDTClientWeb.Router do
  use MDTClientWeb, :router

  pipeline :browser do
    plug MDTClientWeb.Plugs.LoopbackHost
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MDTClientWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", MDTClientWeb do
    pipe_through :browser

    live_session :public, on_mount: {MDTClientWeb.Hooks.Theme, :default} do
      live "/", LoginLive
    end

    post "/login", SessionController, :create
    delete "/logout", SessionController, :delete

    live_session :app,
      on_mount: [{MDTClientWeb.UserAuth, :unlocked}, {MDTClientWeb.Hooks.Theme, :default}] do
      live "/tools", ToolsLive
      live "/tools/http", HttpClientLive
      live "/tools/git", GitLive
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", MDTClientWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:mdt_client, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: MDTClientWeb.Telemetry
    end
  end
end
