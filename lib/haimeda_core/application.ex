defmodule HaimedaCore.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Desktop.identify_default_locale(HaimedaCoreWeb.Gettext)

    children = [
      HaimedaCoreWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:haimeda_core, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: HaimedaCore.PubSub},
      # Start MongoDB connection
      HaimedaCore.Repo,
      # Start Performance Monitor
      HaimedaCore.PerformanceMonitor,
      # Start a worker by calling: HaimedaCore.Worker.start_link(arg)
      # {HaimedaCore.Worker, arg},
      # Start to serve requests, typically the last entry
      HaimedaCoreWeb.Endpoint,
      {DynamicSupervisor, name: PostProcessing.VerificationSupervisor, strategy: :one_for_one},
      {Desktop.Window,
       [
         app: :haimeda_core,
         id: Haimeda,
         title: "HAIMEDA",
         # Primary window size and minimum size
         size: {1920, 1080},
         min_size: {800, 600},
         url: &HaimedaCoreWeb.Endpoint.url/0,
         # menubar: true,
         # Custom application icon - use an absolute path to avoid path issues
         icon: "static/images/logo.png",
         # Background color for the window
         backgroundColor: "#222222",
         # Start in fullscreen mode
         # fullscreen: true,
         # Use a proper frame for better readability
         maximized: true,
         frame: false,
         transparent: false,
         # Customize window settings for better display
         webPreferences: %{
           "backgroundColor" => "#222222",
           "nodeIntegration" => true,
           "contextIsolation" => false,
           "webSecurity" => false
         }
       ]},
      # Make sure GatewayAPI is in the list of children
      # HaimedaCore.GatewayAPI,
      # Add a periodic task for cleaning up old editor sessions (runs once a day)
      %{
        id: :editor_session_cleanup,
        start: {Task, :start_link, [&schedule_editor_sessions_cleanup/0]},
        restart: :temporary
      }
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: HaimedaCore.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Schedule periodic cleanup of old editor sessions
  defp schedule_editor_sessions_cleanup do
    # Run cleanup once per day (24 hours)
    interval = 24 * 60 * 60 * 1000

    # Run cleanup immediately on start
    cleanup_editor_sessions()

    # Schedule recurring cleanup using a message to self
    :timer.send_interval(interval, self(), :cleanup_editor_sessions)

    # Create a receive loop to handle the cleanup messages
    spawn(fn -> cleanup_loop() end)
  end

  # Perform the cleanup task
  defp cleanup_editor_sessions do
    # Keep sessions for 30 days
    HaimedaCore.EditorSession.cleanup_old_sessions(30)
  end

  # Cleanup loop to handle periodic messages
  defp cleanup_loop do
    receive do
      :cleanup_editor_sessions ->
        cleanup_editor_sessions()
        cleanup_loop()

      _ ->
        cleanup_loop()
    after
      # Fallback timeout just to ensure the process doesn't hang indefinitely
      86_400_000 ->
        cleanup_editor_sessions()
        cleanup_loop()
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    HaimedaCoreWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
