defmodule PurpleFlowWeb.Router do
  use PurpleFlowWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug PurpleFlowWeb.Plugs.RequireLogin
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PurpleFlowWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  # Webhooks take whatever the caller sends; no browser session, no CSRF check.
  pipeline :webhook do
  end

  # For Docker's healthcheck, which has no login. Says only "ok".
  get "/health", PurpleFlowWeb.HealthController, :show

  scope "/", PurpleFlowWeb do
    pipe_through :browser

    live "/", WorkflowsLive
    live "/workflows/:name", RunsLive
    live "/runs/:id", RunLive
    live "/credentials", CredentialsLive
  end

  scope "/hooks", PurpleFlowWeb do
    pipe_through :webhook

    get "/*path", WebhookController, :handle
    post "/*path", WebhookController, :handle
  end
end
