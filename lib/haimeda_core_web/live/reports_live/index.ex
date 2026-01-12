defmodule HaimedaCoreWeb.ReportsLive.Index do
  use HaimedaCoreWeb, :live_view
  alias HaimedaCore.Report
  import HaimedaCoreWeb.DateHelpers, only: [format_date: 1]
  import HaimedaCoreWeb.UIComponents, only: [app_header: 1]
  require Logger

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      reports = fetch_reports()

      {:ok,
       socket
       |> assign(:reports, reports)
       |> assign(:page_title, "HAIMEDA - Medizingerätebegutachtung")
       |> assign(:report_name, "")
       |> assign(:show_form, false)
       |> assign(:delete_mode, false)
       |> assign(:delete_modal, nil)
       |> assign(:page_type, "index")}
    else
      {:ok,
       socket
       |> assign(:reports, [])
       |> assign(:page_title, "HAIMEDA - Medizingerätebegutachtung")
       |> assign(:report_name, "")
       |> assign(:show_form, false)
       |> assign(:delete_mode, false)
       |> assign(:delete_modal, nil)
       |> assign(:page_type, "index")}
    end
  end

  defp fetch_reports do
    try do
      reports = Report.list_reports()
      Logger.debug("Successfully fetched #{length(reports)} reports")
      reports
    rescue
      e ->
        Logger.error("Error fetching reports: #{inspect(e)}")
        []
    end
  end

  @impl true
  def handle_event("toggle-form", _params, socket) do
    {:noreply, assign(socket, :show_form, !socket.assigns.show_form)}
  end

  @impl true
  def handle_event("update-report-name", %{"value" => name}, socket) do
    {:noreply, assign(socket, :report_name, name)}
  end

  @impl true
  def handle_event("create-report", %{"name" => name}, socket) do
    report_name = if name == "", do: "Neues Gutachten", else: name
    Logger.debug("Creating report with name: #{report_name}")

    case Report.create_report(%{name: report_name}) do
      {:ok, new_report} ->
        Logger.info("Report created successfully: #{inspect(new_report)}")

        Process.sleep(100)
        reports = fetch_reports()

        {:noreply,
         socket
         |> put_flash(:info, "Gutachten \"#{report_name}\" wurde erstellt.")
         |> assign(:reports, reports)
         |> assign(:report_name, "")
         |> assign(:show_form, false)}

      {:error, reason} ->
        Logger.error("Failed to create report: #{reason}")

        {:noreply,
         socket
         |> put_flash(:error, "Fehler beim Erstellen des Gutachtens: #{reason}")
         |> assign(:show_form, true)}
    end
  end

  @impl true
  def handle_event("toggle-delete-mode", _params, socket) do
    {:noreply, assign(socket, :delete_mode, !socket.assigns.delete_mode)}
  end

  @impl true
  def handle_event(
        "show-delete-confirmation",
        %{"report_id" => report_id, "report_name" => report_name},
        socket
      ) do
    delete_modal = %{
      id: report_id,
      category: "report",
      item_label: report_name
    }

    {:noreply, assign(socket, :delete_modal, delete_modal)}
  end

  @impl true
  def handle_event("confirm-delete", %{"id" => report_id, "category" => "report"}, socket) do
    case Report.soft_delete_report(report_id) do
      {:ok, _message} ->
        reports = fetch_reports()

        {:noreply,
         socket
         |> put_flash(:info, "Gutachten wurde gelöscht.")
         |> assign(:reports, reports)
         |> assign(:delete_modal, nil)}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Fehler beim Löschen des Gutachtens: #{reason}")
         |> assign(:delete_modal, nil)}
    end
  end

  @impl true
  def handle_event("cancel-delete", _params, socket) do
    {:noreply, assign(socket, :delete_modal, nil)}
  end

  @impl true
  def handle_event("open-report", %{"id" => id}, socket) do
    HaimedaCore.EditorSession.reset_initialization(id)

    if socket.assigns.delete_mode do
      socket = assign(socket, :delete_mode, false)
      {:noreply, push_navigate(socket, to: ~p"/reports/#{id}/editor")}
    else
      {:noreply, push_navigate(socket, to: ~p"/reports/#{id}/editor")}
    end
  end
end
