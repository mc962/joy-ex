defmodule JoyWeb.Router do
  use JoyWeb, :router

  import JoyWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {JoyWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", JoyWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :app,
      on_mount: [{JoyWeb.UserAuth, :require_authenticated}, JoyWeb.AdminAuth] do
      live "/", DashboardLive, :index
      live "/channels", Channels.IndexLive, :index
      live "/channels/new", Channels.IndexLive, :new
      live "/channels/:id", Channels.ShowLive, :show
      live "/channels/:id/edit", Channels.ShowLive, :edit
      live "/channels/:id/transforms/new", Channels.ShowLive, :new_transform
      live "/channels/:id/transforms/:transform_id/edit", Channels.ShowLive, :edit_transform
      live "/channels/:id/transforms/:transform_id/editor", Transforms.EditorLive, :show
      live "/channels/:id/destinations/new", Channels.ShowLive, :new_destination
      live "/channels/:id/destinations/:dest_id/edit", Channels.ShowLive, :edit_destination
      live "/channels/:id/messages", MessageLog.IndexLive, :index
      live "/messages/failed", Messages.FailedLive, :index
      live "/users", Users.IndexLive, :index
      live "/tools/mllp-client", Tools.MllpClientLive, :index
      live "/tools/sinks", Tools.SinksLive, :index
    end
  end

  if Application.compile_env(:joy, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser
      live_dashboard "/dashboard", metrics: JoyWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", JoyWeb do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    get "/users/register", UserRegistrationController, :new
    post "/users/register", UserRegistrationController, :create
  end

  scope "/", JoyWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/users/settings", UserSettingsController, :edit
    put "/users/settings", UserSettingsController, :update
    get "/users/settings/confirm-email/:token", UserSettingsController, :confirm_email
  end

  scope "/", JoyWeb do
    pipe_through [:browser]

    get "/users/log-in", UserSessionController, :new
    get "/users/log-in/:token", UserSessionController, :confirm
    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
