defmodule HaimedaCoreWeb.ReportsEditor.LiveChat do
  use HaimedaCoreWeb, :html

  # Chat section component
  attr(:chat_messages, :list, default: [])
  attr(:chat_input, :string, default: "")
  attr(:chat_history, :list, default: [])

  def chat_section(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <div class="bg-gray-700 text-white px-4 py-2 font-semibold flex items-center">
        <.icon name="hero-chat-bubble-left-right" class="w-4 h-4 mr-2" />
        <span>KI-Assistent</span>
      </div>

      <!-- Chat messages area (scrollable) -->
      <div
        id="chat-messages"
        phx-hook="ChatContainer"
        class="flex-1 overflow-y-auto p-3 bg-white"
        >
        <%= for {message, i} <- Enum.with_index(@chat_messages) do %>
          <%= cond do %>
            <% message.sender == "user" -> %>
              <!-- User message -->
              <div id={"msg-#{i}"} class="flex mb-3 justify-end">
                <div class="mr-2 bg-blue-100 rounded-lg p-2 max-w-[80%]">
                  <p class="text-sm text-gray-800 select-text cursor-text"><%= message.content %></p>
                  <p class="text-xs text-gray-500 mt-1">
                    <%= format_chat_time(message.timestamp) %>
                  </p>
                </div>
                <div class="w-8 h-8 rounded-full bg-gray-300 flex items-center justify-center flex-shrink-0">
                  <.icon name="hero-user" class="w-4 h-4 text-gray-600" />
                </div>
              </div>

            <% message.sender == "symbolic_ai" -> %>
              <!-- Symbolic AI message -->
              <div id={"msg-#{i}"} class="flex mb-3">
                <div class="w-8 h-8 rounded-full bg-orange-100 flex items-center justify-center flex-shrink-0">
                  <.icon name="hero-cpu-chip" class="w-4 h-4 text-orange-600" />
                </div>
                <div class="ml-2 bg-orange-50 rounded-lg p-2 max-w-[80%]">
                  <p class="text-xs font-bold text-orange-700 mb-1">Symbolische KI</p>
                  <div class="text-sm text-gray-800 select-text cursor-text"><%= raw(message.content) %></div>
                  <p class="text-xs text-gray-500 mt-1 text-right">
                    <%= format_chat_time(message.timestamp) %>
                  </p>
                </div>
              </div>

            <% message.sender == "hybrid_ai" -> %>
              <!-- Hybrid AI message (combination of symbolic and sub-symbolic) -->
              <div id={"msg-#{i}"} class="flex mb-3">
                <div class="w-8 h-8 rounded-full bg-indigo-100 flex items-center justify-center flex-shrink-0">
                  <.icon name="hero-bolt" class="w-4 h-4 text-indigo-600" />
                </div>
                <div class="ml-2 bg-indigo-50 rounded-lg p-2 max-w-[80%]">
                  <p class="text-xs font-bold text-indigo-700 mb-1">Hybride KI</p>
                  <p class="text-sm whitespace-pre-line text-gray-800 select-text cursor-text"><%= message.content %></p>
                  <p class="text-xs text-gray-500 mt-1 text-right">
                    <%= format_chat_time(message.timestamp) %>
                  </p>
                </div>
              </div>

            <% message.sender == "sub-symbolic_ai" -> %>
              <!-- Sub-symbolic AI message (LLM) -->
              <div id={"msg-#{i}"} class="flex mb-3">
                <div class="w-8 h-8 rounded-full bg-green-100 flex items-center justify-center flex-shrink-0">
                  <.icon name="hero-sparkles" class="w-4 h-4 text-green-600" />
                </div>
                <div class="ml-2 bg-green-50 rounded-lg p-2 max-w-[80%]">
                  <p class="text-xs font-bold text-green-700 mb-1">LLM</p>
                  <p class="text-sm whitespace-pre-line text-gray-800 select-text cursor-text"><%= message.content %></p>
                  <p class="text-xs text-gray-500 mt-1 text-right">
                    <%= format_chat_time(message.timestamp) %>
                  </p>
                </div>
              </div>

            <% message.sender == "system" -> %>
              <!-- System message -->
              <div id={"msg-#{i}"} class="flex mb-3">
                <div class="w-8 h-8 rounded-full bg-gray-100 flex items-center justify-center flex-shrink-0">
                  <.icon name="hero-cog-6-tooth" class="w-4 h-4 text-gray-600" />
                </div>
                <div class="ml-2 bg-gray-100 rounded-lg p-2 max-w-[80%]">
                  <p class="text-xs font-bold text-gray-700 mb-1">System</p>
                  <p class="text-sm whitespace-pre-line text-gray-800 select-text cursor-text"><%= message.content %></p>
                  <p class="text-xs text-gray-500 mt-1 text-right">
                    <%= format_chat_time(message.timestamp) %>
                  </p>
                </div>
              </div>

            <% true -> %>
              <!-- Default AI message (fallback for "ai" or unknown sender types) -->
              <div id={"msg-#{i}"} class="flex mb-3">
                <div class="w-8 h-8 rounded-full bg-blue-100 flex items-center justify-center flex-shrink-0">
                  <.icon name="hero-sparkles" class="w-4 h-4 text-blue-600" />
                </div>
                <div class="ml-2 bg-gray-100 rounded-lg p-2 max-w-[80%]">
                  <p class="text-sm whitespace-pre-line text-gray-800 select-text cursor-text"><%= message.content %></p>
                  <p class="text-xs text-gray-500 mt-1 text-right">
                    <%= format_chat_time(message.timestamp) %>
                  </p>
                </div>
              </div>
          <% end %>
        <% end %>
      </div>

      <!-- Chat input area (fixed at bottom) -->
      <div class="p-2 border-t border-gray-200 bg-white">
        <form phx-submit="submit-chat" id="chat-form" class="flex items-center">
          <input
            id="chat-input-field"
            type="text"
            name="message"
            value={@chat_input}
            placeholder="Frage an KI-Assistenten stellen..."
            class="flex-1 p-2 border rounded-l-md focus:outline-none focus:ring-2 focus:ring-blue-500"
            phx-hook="ChatInputSync"
            phx-keydown="handle-chat-keydown"
            phx-change="update-chat-input"
            autocomplete="off"
          />
          <button type="submit" class="bg-blue-600 hover:bg-blue-700 text-white p-2 rounded-r-md">
            <.icon name="hero-paper-airplane" class="w-5 h-5" />
          </button>
        </form>
      </div>
    </div>
    """
  end

  # Helper for formatting chat message timestamps
  def format_chat_time(%DateTime{} = dt) do
    "#{pad_number(dt.hour)}:#{pad_number(dt.minute)}"
  end

  def format_chat_time(dt) when is_binary(dt) do
    case DateTime.from_iso8601(dt) do
      {:ok, datetime, _} -> format_chat_time(datetime)
      _ -> dt
    end
  end

  def format_chat_time(_), do: ""

  defp pad_number(number) when number < 10, do: "0#{number}"
  defp pad_number(number), do: "#{number}"
end
