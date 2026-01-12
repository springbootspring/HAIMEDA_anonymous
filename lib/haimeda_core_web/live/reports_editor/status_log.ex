defmodule HaimedaCoreWeb.ReportsEditor.StatusLog do
  use HaimedaCoreWeb, :html

  # Status/log section component
  attr(:logs, :list, default: [])

  def status_log_section(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <div class="bg-gray-700 text-white px-4 py-2 font-semibold flex items-center">
        <.icon name="hero-information-circle" class="w-4 h-4 mr-2" />
        <span>Status Information</span>
      </div>

      <div
        id="log-content"
        phx-update="append"
        phx-hook="LogContainer"
        class="flex-1 overflow-y-auto p-2 bg-gray-800 text-white text-sm"
      >
        <%= if length(@logs) > 0 do %>
          <%= for log <- @logs do %>
            <div id={"log-#{log.timestamp}-#{log.message}"} class="log-entry mb-1 flex">
              <span class="text-gray-400 whitespace-nowrap mr-2">[<%= format_log_time(get_timestamp(log)) %>]</span>
              <span class={log_type_class(get_type(log))}><%= get_message(log) %></span>
            </div>
          <% end %>
        <% else %>
          <div class="text-gray-500 italic p-2">
            Status-Informationen von der AI werden hier angezeigt.
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # Helper functions to extract values regardless of whether keys are atoms or strings
  defp get_timestamp(log) do
    cond do
      is_map_key(log, :timestamp) -> Map.get(log, :timestamp)
      is_map_key(log, "timestamp") -> Map.get(log, "timestamp")
      true -> nil
    end
  end

  defp get_message(log) do
    cond do
      is_map_key(log, :message) -> Map.get(log, :message)
      is_map_key(log, "message") -> Map.get(log, "message")
      true -> ""
    end
  end

  defp get_type(log) do
    cond do
      is_map_key(log, :type) -> Map.get(log, :type)
      is_map_key(log, "type") -> Map.get(log, "type")
      true -> ""
    end
  end

  # Helper function to format log timestamp to HH:MM:SS only
  defp format_log_time(timestamp) when is_binary(timestamp) do
    case String.split(timestamp, ".", parts: 2) do
      [time_part | _] -> String.slice(time_part, 0, 8)
      _ -> timestamp
    end
  end

  defp format_log_time(timestamp), do: timestamp

  # Helper function to assign class based on log type
  defp log_type_class(type) do
    case type do
      "success" -> "text-green-400"
      "warning" -> "text-yellow-400"
      "error" -> "text-red-400"
      "info" -> "text-blue-400"
      "ai" -> "text-purple-400"
      _ -> ""
    end
  end
end
