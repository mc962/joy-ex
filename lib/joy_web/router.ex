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

  pipeline :openapi do
    plug :accepts, ["json", "html"]
    plug OpenApiSpex.Plug.PutApiSpec, module: JoyWeb.API.ApiSpec
  end

  pipeline :api_auth do
    plug :accepts, ["json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: JoyWeb.API.ApiSpec
    plug JoyWeb.Plugs.ApiAuth
  end

  scope "/", JoyWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :app,
      on_mount: [{JoyWeb.UserAuth, :require_authenticated}] do
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
      live "/organizations", Organizations.IndexLive, :index
      live "/organizations/new", Organizations.IndexLive, :new
      live "/organizations/:id", Organizations.ShowLive, :show
      live "/organizations/:id/edit", Organizations.ShowLive, :edit
    end

    live_session :admin,
      on_mount: [{JoyWeb.UserAuth, :require_authenticated}, JoyWeb.AdminAuth] do
      live "/users", Users.IndexLive, :index
      live "/audit", AuditLive, :index
      live "/tools/mllp-client", Tools.MllpClientLive, :index
      live "/tools/sinks", Tools.SinksLive, :index
      live "/tools/retention", RetentionLive, :index
      live "/service-accounts", ServiceAccountsLive, :index
    end
  end

  # OpenAPI spec — unauthenticated, read-only
  scope "/api" do
    pipe_through :openapi
    get "/v1/openapi.json", OpenApiSpex.Plug.RenderSpec, []
  end

  # Scalar API docs UI — unauthenticated
  scope "/api", JoyWeb do
    pipe_through :openapi
    get "/docs", ApiDocsController, :index
  end

  # Token creation — unauthenticated (you're calling this to get a token)
  scope "/api/v1", JoyWeb.API.V1 do
    pipe_through :api
    post "/tokens", TokenController, :create
  end

  scope "/api/v1", JoyWeb.API.V1 do
    pipe_through :api_auth

    delete "/tokens/:id", TokenController, :delete

    resources "/channels", ChannelController, only: [:index, :show, :create, :update, :delete] do
      post "/start",  ChannelController, :start
      post "/stop",   ChannelController, :stop
      post "/pause",  ChannelController, :pause
      post "/resume", ChannelController, :resume
      resources "/destinations", DestinationController, only: [:index, :create, :update, :delete]
      resources "/messages", MessageLogController, only: [:index] do
        post "/retry", MessageLogController, :retry
      end
    end

    resources "/organizations", OrganizationController, only: [:index, :show, :create, :update, :delete]
    post "/retention/purge", RetentionController, :purge
    get "/metrics", MetricsController, :index
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

    get    "/users/settings", UserSettingsController, :edit
    put    "/users/settings", UserSettingsController, :update
    get    "/users/settings/confirm-email/:token", UserSettingsController, :confirm_email
    post   "/users/settings/tokens", UserSettingsController, :create_token
    delete "/users/settings/tokens/:id", UserSettingsController, :revoke_token
  end

  scope "/", JoyWeb do
    pipe_through [:browser]

    get "/users/log-in", UserSessionController, :new
    get "/users/log-in/:token", UserSessionController, :confirm
    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
