defmodule HaimedaCoreWeb.PageController do
  use HaimedaCoreWeb, :controller

  def home(conn, _params) do
    # Redirect to reports page instead of rendering the default home page
    redirect(conn, to: ~p"/reports")
  end
end
