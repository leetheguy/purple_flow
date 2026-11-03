defmodule PurpleFlowWeb.Router do
  @moduledoc """
  Maps each URL to the code that answers it.

  - Open to anyone: `GET /health` (Docker's health check), `GET /agents`
    (the guide for visiting agents), and `/hooks/*` (webhooks, which can
    require a token; see [specs/040](specs/040_triggers.md)).
  - `/api/workflows`: for agents, with `PURPLEFLOW_AGENT_TOKEN`
    ([specs/090](specs/090_workflow_files.md)).
  - Everything else is the UI, behind the admin login
    ([specs/080](specs/080_credentials.md)).

  A *pipeline* is a list of plugs (small request handlers) run in order
  before the controller or LiveView.
  """

  use PurpleFlowWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PurpleFlowWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  # The one sign-in (see PurpleFlowWeb.Auth). Everything under it needs it.
  pipeline :signed_in do
    plug PurpleFlowWeb.Plugs.RequireLogin
  end

  # Webhooks take whatever the caller sends; no browser session, no CSRF check.
  pipeline :webhook do
  end

  # For Docker's healthcheck, which has no login. Says only "ok".
  get "/health", PurpleFlowWeb.HealthController, :show

  # Instructions for visiting agents, before they have a token. Public.
  get "/agents", PurpleFlowWeb.AgentsController, :show

  scope "/", PurpleFlowWeb do
    pipe_through :browser

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    delete "/logout", SessionController, :delete
  end

  scope "/", PurpleFlowWeb do
    pipe_through [:browser, :signed_in]

    # Connecting an OAuth credential: specs/200_oauth_credentials.md.
    get "/credentials/oauth/callback", OAuthController, :callback
    get "/credentials/:id/connect", OAuthController, :connect

    live_session :signed_in, on_mount: {PurpleFlowWeb.Auth, :require_login} do
      live "/", WorkflowsLive
      live "/workflows/:name", RunsLive
      live "/workflows/:name/canvas", CanvasLive
      live "/runs/:id", RunLive
      live "/files", FilesLive
      live "/files/*path", FilesLive
      live "/credentials", CredentialsLive
    end
  end

  # For agents, with their own token instead of the browser login.
  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", PurpleFlowWeb do
    pipe_through :api

    get "/workflows", WorkflowStatusController, :index
  end

  scope "/hooks", PurpleFlowWeb do
    pipe_through :webhook

    get "/*path", WebhookController, :handle
    post "/*path", WebhookController, :handle
  end
end
