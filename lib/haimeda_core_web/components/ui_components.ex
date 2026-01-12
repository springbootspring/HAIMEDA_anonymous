defmodule HaimedaCoreWeb.UIComponents do
  use Phoenix.Component
  alias Phoenix.LiveView.JS

  attr(:class, :string, default: "")
  attr(:page_type, :string, default: "index")
  attr(:verification_count, :integer, default: 1)

  attr(:llm_params, :map,
    default: %{
      "temperature" => 0.7,
      "top_p" => 0.9,
      "top_k" => 50,
      "max_tokens" => 4000,
      "repeat_penalty" => 1.1
    }
  )

  attr(:previous_content_mode, :string, default: "full_chapters")
  attr(:loading, :boolean, default: false)
  attr(:selected_llm, :string, default: "llama3_german_instruct_ft_stage_d")
  attr(:verification_degree, :string, default: "Mittlere Übereinstimmung")
  attr(:loading_message, :atom, default: :default)
  attr(:llm_options, :list, default: [])

  @loading_messages %{
    llm_integration: "LLM-Integration läuft...",
    rag_verification: "Lokale Datenbank für RAG wird verifiziert...",
    default: "Lade...",
    chapter_creation: "Erstelle Kapitel...",
    verification: "Verifiziere Inhalt...",
    summarization: "Erstelle Zusammenfassung...",
    ai_correction: "KI-Korrektur läuft...",
    ai_optimization: "Text wird optimiert...",
    chat_response: "Verarbeite Anfrage...",
    db_search: "Suche in lokalen Daten...",
    ai_answer: "KI-Antwort wird generiert..."
  }

  def app_header(assigns) do
    # Use a unique id for the dropdown per page type to avoid DOM conflicts
    dropdown_id = "options-dropdown-#{assigns[:page_type] || "default"}"
    menu_button_id = "options-menu-button-#{assigns[:page_type] || "default"}"
    assigns = assign(assigns, :dropdown_id, dropdown_id)
    assigns = assign(assigns, :menu_button_id, menu_button_id)

    # Determine if this is for the index page for special styling
    is_index_page = assigns.page_type == "index"

    # Adjust sizes based on page type
    text_size_class = if is_index_page, do: "text-base md:text-lg", else: "text-sm md:text-base"
    logo_size = if is_index_page, do: 44, else: 36
    py_class = if is_index_page, do: "py-4", else: "py-3"

    # Set positioning style conditionally based on page type
    header_styles =
      if is_index_page do
        "position: absolute; top: 0; left: 0; right: 0; z-index: 50;"
      else
        ""
      end

    # Define verification degree options
    verification_degree_options = [
      "Keine Übereinstimmung",
      "Schwache Übereinstimmung",
      "Mittlere Übereinstimmung",
      "Starke Übereinstimmung",
      "Exakte Übereinstimmung"
    ]

    # Ensure verification_degree is a display string (for case when atom is passed)
    verification_degree =
      if is_atom(assigns.verification_degree) do
        verification_atom_map = %{
          no_match: "Keine Übereinstimmung",
          weak_match: "Schwache Übereinstimmung",
          moderate_match: "Mittlere Übereinstimmung",
          strong_match: "Starke Übereinstimmung",
          exact_match: "Exakte Übereinstimmung"
        }

        Map.get(verification_atom_map, assigns.verification_degree, "Mittlere Übereinstimmung")
      else
        assigns.verification_degree
      end

    assigns = assign(assigns, :verification_degree_options, verification_degree_options)
    assigns = assign(assigns, :verification_degree_display, verification_degree)

    # Get actual loading message from the map based on the key
    loading_message =
      case assigns.loading_message do
        message_key when is_atom(message_key) ->
          Map.get(@loading_messages, message_key, @loading_messages[:default])

        _ ->
          @loading_messages[:default]
      end

    assigns = assign(assigns, :display_loading_message, loading_message)

    ~H"""
    <header class={"bg-blue-800 w-full m-0 p-0 #{@class}"} style={header_styles}>
      <div class={"flex items-center justify-between border-b border-blue-600 #{py_class} px-4 sm:px-6 lg:px-8"}>
        <div class="flex items-center gap-4">
          <a href="/">
            <div class="bg-grey rounded-full p-1">
              <img src="/images/logo.png" width={logo_size} height={logo_size} class="rounded-full object-cover" alt="HAIMEDA Logo" />
            </div>
          </a>
          <p class={"text-white font-semibold #{text_size_class}"}>
            HAIMEDA - Hybrid AI for Medical Device Assessment
          </p>
        </div>
        <div class="flex items-center gap-4 font-semibold leading-6">
          <!-- Loading spinner with dynamic message -->
          <%= if @page_type == "editor" && @loading do %>
            <div class="flex items-center text-white mr-2">
              <div class="w-4 h-4 border-2 border-white border-t-transparent rounded-full animate-spin mr-2"></div>
              <span class="text-xs"><%= @display_loading_message %></span>
            </div>
          <% end %>

          <!-- Options Dropdown -->
          <div class="relative">
            <button
              id={@menu_button_id}
              class={"text-white hover:text-blue-200 #{text_size_class}"}
              phx-click={JS.toggle(to: "##{@dropdown_id}")}
            >
              Optionen
            </button>
            <!-- Dropdown menu -->
            <div
              id={@dropdown_id}
              class="hidden absolute right-0 mt-2 w-64 origin-top-right divide-y divide-gray-100 rounded-md bg-white shadow-lg ring-1 ring-black ring-opacity-5 focus:outline-none z-50"
              role="menu"
              aria-orientation="vertical"
              aria-labelledby={@menu_button_id}
              tabindex="-1"
            >
              <div class="py-1" role="none">
                <%= if @page_type == "editor" do %>
                  <button
                    phx-click="clear-messages"
                    class="text-gray-700 block w-full px-4 py-2 text-left text-sm hover:bg-gray-100"
                    role="menuitem"
                  >
                    Lösche Status- und Chatnachrichten
                  </button>

                  <button
                    phx-click="chapter-summarization"
                    class="text-gray-700 block w-full px-4 py-2 text-left text-sm hover:bg-gray-100"
                    role="menuitem"

                  >
                    Starte automatische Zusammenfassung der Kapitel
                  </button>

                  <button
                    phx-click="toggle-content-mode"
                    class={"text-left text-sm px-4 py-2 block w-full #{if @previous_content_mode == "summaries", do: "bg-green-100 text-green-800", else: "text-gray-700 hover:bg-gray-100"}"}
                    role="menuitem"
                  >
                    Nutze Kapitelzusammenfassungen anstelle ganzer Kapitel für Kontext
                  </button>

                  <div class="px-4 py-3 flex items-center justify-between">
                    <label for="verification-count" class="text-gray-700 text-sm">
                      Anzahl automatischer Verifikationen:
                    </label>
                    <input
                      id="verification-count"
                      type="number"
                      min="1"
                      max="20"
                      value={@verification_count}
                      phx-change="update-verification-count"
                      phx-blur="update-verification-count"
                      class="w-16 px-2 py-1 border rounded text-sm"
                      onkeydown="return event.key === 'ArrowUp' || event.key === 'ArrowDown'"
                    />
                  </div>

                  <!-- Verification Degree Slider -->
                  <div class="px-4 py-3 border-t border-gray-200">
                    <label for="verification-degree" class="block text-sm font-medium text-gray-700 mb-2">
                      Verifikationsgrad:
                    </label>
                    <div class="relative pt-1">
                      <form phx-change="update-verification-degree" phx-submit="update-verification-degree">
                        <input
                          id="verification-degree-slider"
                          name="value"
                          type="range"
                          min="0"
                          max="4"
                          step="1"
                          value={Enum.find_index(@verification_degree_options, &(&1 == @verification_degree_display)) || 2}
                          class="w-full h-2 bg-gray-200 rounded-lg appearance-none cursor-pointer"
                        />
                      </form>
                      <div class="text-xs text-center mt-2 font-medium text-gray-800" id="verification-degree-value">
                        <%= @verification_degree_display %>
                      </div>
                      <div class="flex text-xs text-gray-500 justify-between mt-1">
                        <span>Keine</span>
                        <span>Schwach</span>
                        <span>Mittel</span>
                        <span>Stark</span>
                        <span>Exakt</span>
                      </div>
                    </div>
                  </div>

                  <!-- LLM Selection Section -->
                  <div class="px-4 py-3 border-t border-gray-200">
                    <h3 class="text-sm font-medium text-gray-700 mb-2">Gewähltes LLM</h3>
                    <%= if length(@llm_options) > 0 do %>
                      <form phx-change="update-selected-llm" phx-submit="update-selected-llm">
                        <select
                          name="value"
                          class="w-full p-2 border rounded text-sm"
                        >
                          <%= for llm <- @llm_options do %>
                            <option value={llm} selected={llm == @selected_llm}><%= llm %></option>
                          <% end %>
                        </select>
                      </form>
                    <% else %>
                      <p class="text-sm text-gray-500">Keine lokalen LLMs verfügbar</p>
                    <% end %>
                  </div>

                  <!-- LLM Parameters Section -->
                  <div class="px-4 py-2 border-t border-gray-200">
                    <h3 class="text-sm font-medium text-gray-700 mb-2">LLM Parameter</h3>

                    <!-- Temperature slider -->
                    <div class="mb-3">
                      <div class="flex justify-between mb-1">
                        <label class="text-xs text-gray-600">Temperature</label>
                        <span class="text-xs text-gray-600" id="temperature-value"><%= @llm_params["temperature"] %></span>
                      </div>
                      <form phx-change="update-llm-param">
                        <input type="hidden" name="param" value="temperature">
                        <input
                          type="range"
                          min="0"
                          max="1"
                          step="0.05"
                          name="value"
                          value={@llm_params["temperature"]}
                          class="w-full"
                        />
                      </form>
                    </div>

                    <!-- Top_p slider -->
                    <div class="mb-3">
                      <div class="flex justify-between mb-1">
                        <label class="text-xs text-gray-600">Top_p</label>
                        <span class="text-xs text-gray-600" id="top_p-value"><%= @llm_params["top_p"] %></span>
                      </div>
                      <form phx-change="update-llm-param">
                        <input type="hidden" name="param" value="top_p">
                        <input
                          type="range"
                          min="0"
                          max="1"
                          step="0.05"
                          name="value"
                          value={@llm_params["top_p"]}
                          class="w-full"
                        />
                      </form>
                    </div>

                    <!-- Top_k slider -->
                    <div class="mb-3">
                      <div class="flex justify-between mb-1">
                        <label class="text-xs text-gray-600">Top_k</label>
                        <span class="text-xs text-gray-600" id="top_k-value"><%= @llm_params["top_k"] %></span>
                      </div>
                      <form phx-change="update-llm-param">
                        <input type="hidden" name="param" value="top_k">
                        <input
                          type="range"
                          min="0"
                          max="100"
                          step="5"
                          name="value"
                          value={@llm_params["top_k"]}
                          class="w-full"
                        />
                      </form>
                    </div>

                    <!-- Max Tokens slider -->
                    <div class="mb-3">
                      <div class="flex justify-between mb-1">
                        <label class="text-xs text-gray-600">Max. Tokens</label>
                        <span class="text-xs text-gray-600" id="max_tokens-value"><%= @llm_params["max_tokens"] %></span>
                      </div>
                      <form phx-change="update-llm-param">
                        <input type="hidden" name="param" value="max_tokens">
                        <input
                          type="range"
                          min="0"
                          max="10000"
                          step="50"
                          name="value"
                          value={@llm_params["max_tokens"]}
                          class="w-full"
                        />
                      </form>
                    </div>

                    <!-- Repeat Penalty slider -->
                    <div class="mb-2">
                      <div class="flex justify-between mb-1">
                        <label class="text-xs text-gray-600">Repeat Penalty</label>
                        <span class="text-xs text-gray-600" id="repeat_penalty-value"><%= @llm_params["repeat_penalty"] %></span>
                      </div>
                      <form phx-change="update-llm-param">
                        <input type="hidden" name="param" value="repeat_penalty">
                        <input
                          type="range"
                          min="0"
                          max="10"
                          step="0.05"
                          name="value"
                          value={@llm_params["repeat_penalty"]}
                          class="w-full"
                        />
                      </form>
                    </div>
                  </div>
                <% end %>
                <%= if @page_type == "index" do %>
                  <button
                    phx-click="toggle-delete-mode"
                    class="text-gray-700 block w-full px-4 py-2 text-left text-sm hover:bg-gray-100"
                    role="menuitem"
                  >
                    Gutachten löschen
                  </button>
                <% end %>
              </div>
            </div>
          </div>
          <!-- Overview link -->
          <a href="/reports" class={"text-white hover:text-blue-200 #{text_size_class}"}>
            Übersicht
          </a>
        </div>
      </div>
    </header>
    """
  end
end
