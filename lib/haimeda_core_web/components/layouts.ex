defmodule HaimedaCoreWeb.Layouts do
  @moduledoc """
  This module holds different layouts used by your application.

  See the `layouts` directory for all templates available.
  The "root" layout is a skeleton rendered as part of the
  application router. The "app" layout is set as the default
  layout on both `use HaimedaCoreWeb, :controller` and
  `use HaimedaCoreWeb, :live_view`.
  """
  use HaimedaCoreWeb, :html

  # Import the UIComponents module to use app_header
  import HaimedaCoreWeb.UIComponents

  embed_templates("layouts/*")
end
