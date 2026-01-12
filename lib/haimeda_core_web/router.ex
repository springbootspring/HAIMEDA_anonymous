defmodule HaimedaCoreWeb.Router do
  use HaimedaCoreWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {HaimedaCoreWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/", HaimedaCoreWeb do
    pipe_through(:browser)

    get("/", PageController, :home)
    live("/reports", ReportsLive.Index, :index)
    live("/reports/:id/editor", ReportsEditor.Editor, :index)
  end

  # Other scopes may use custom stacks.
  # scope "/api", HaimedaCoreWeb do
  #   pipe_through :api
  # end
end
