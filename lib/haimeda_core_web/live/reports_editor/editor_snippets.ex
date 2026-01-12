defmodule HaimedaCoreWeb.ReportsEditor.EditorSnippets do
  use HaimedaCoreWeb, :html
  import HaimedaCoreWeb.UIComponents, only: [app_header: 1]
  import HaimedaCoreWeb.ReportsEditor.StatusLog, only: [status_log_section: 1]
  import HaimedaCoreWeb.ReportsEditor.LiveChat, only: [chat_section: 1]
  alias HaimedaCoreWeb.ReportsEditor.ContentPersistence

  attr(:report_id, :string, required: true)
  attr(:report, :map, required: true)
  attr(:tabs, :list, required: true)
  attr(:active_tab, :string, required: true)
  attr(:nav_sections, :list, required: true)
  attr(:delete_modal, :map, default: nil)
  attr(:logs, :list, default: [])
  attr(:chat_messages, :list, default: [])
  attr(:chat_input, :string, default: "")
  attr(:loading, :boolean, default: false)
  attr(:page_type, :string, default: "editor")
  attr(:verification_count, :integer, default: 1)
  attr(:previous_content_mode, :string, default: "full_chapters")
  attr(:selected_llm, :string, default: "llama3_german_instruct")
  attr(:verification_degree, :string, default: "Mittlere Übereinstimmung")
  attr(:ai_correction_disabled, :boolean, default: true)
  attr(:confirm_changes_disabled, :boolean, default: true)
  attr(:discard_changes_disabled, :boolean, default: true)
  attr(:auto_chapter_disabled, :boolean, default: false)
  attr(:manual_verification_disabled, :boolean, default: false)
  attr(:ai_optimize_disabled, :boolean, default: false)
  attr(:loading_message, :string, default: "Lade...")
  attr(:llm_options, :list, default: [])

  attr(:llm_params, :map,
    default: %{
      "temperature" => 0.0,
      "top_p" => 0.3,
      "top_k" => 50,
      "max_tokens" => 4000,
      "repeat_penalty" => 1.1
    }
  )

  def editor_layout(assigns) do
    ~H"""
    <!-- Main app container -->
    <div id="editor-container" class="fixed inset-0 flex flex-col">
      <!-- Use the shared app header component with all necessary parameters -->
      <.app_header
        class="flex-shrink-0"
        page_type={@page_type}
        verification_count={@verification_count}
        llm_params={@llm_params}
        previous_content_mode={@previous_content_mode}
        loading={@loading}
        selected_llm={@selected_llm}
        verification_degree={@verification_degree}
        loading_message={@loading_message}
        llm_options={@llm_options}
      />

      <!-- OutputArea LiveComponent (invisible, for state management) -->
      <.live_component
        module={HaimedaCoreWeb.ReportsEditor.OutputArea}
        id="output-area"
        tabs={@tabs}
        active_tab={@active_tab}
        report_id={@report_id}
      />

      <!-- Main content area with resizable columns -->
      <div class="resizable-container">
        <!-- Left column: Navigation + Status Log -->
        <div class="left-panel">
          <div class="panel-content flex flex-col h-full">
            <!-- Navigation sidebar -->
            <div id="sidebar-navigation" class="flex-1 overflow-y-auto">
              <div class="p-4">
                <div class="text-xl font-bold mb-6"><%= @report.name %></div>

                <%= for section <- @nav_sections do %>
                  <.sidebar_section section={section} tabs={@tabs} active_tab={@active_tab} />
                <% end %>
              </div>
            </div>

            <!-- Status/log section at the bottom of left column -->
            <div class="h-48 border-t border-gray-600 flex-shrink-0">
              <.status_log_section logs={@logs} />
            </div>
          </div>
        </div>

        <!-- Middle column: Editor content -->
        <div class="middle-panel">
          <!-- Tab bar is now outside the scrollable area -->
          <.tabs_bar tabs={@tabs} active_tab={@active_tab} />

          <!-- Wrap content in a scrollable div -->
          <div class="flex-1 overflow-auto">
            <.content_area
              tabs={@tabs}
              active_tab={@active_tab}
              loading={@loading}
              ai_correction_disabled={@ai_correction_disabled}
              confirm_changes_disabled={@confirm_changes_disabled}
              discard_changes_disabled={@discard_changes_disabled}
              auto_chapter_disabled={@auto_chapter_disabled}
              manual_verification_disabled={@manual_verification_disabled}
              ai_optimize_disabled={@ai_optimize_disabled}
            />
          </div>
        </div>

        <!-- Right column: Chat functionality -->
        <div class="right-panel">
          <div class="panel-content h-full">
            <.chat_section chat_messages={@chat_messages} chat_input={@chat_input} />
          </div>
        </div>
      </div>

      <!-- Delete confirmation modal -->
      <%= if @delete_modal do %>
        <.delete_confirmation_modal
          id={@delete_modal.id}
          category={@delete_modal.category}
          item_label={@delete_modal.item_label}
          version={@delete_modal[:version]}
        />
      <% end %>
    </div>
    """
  end

  attr(:section, :map, required: true)
  attr(:tabs, :list, required: true)
  attr(:active_tab, :string, required: true)

  def sidebar_section(assigns) do
    ~H"""
    <div class="mb-4">
      <div class="flex items-center justify-between gap-2 mb-2 font-semibold">
        <div class="flex items-center gap-2">
          <.icon name={@section.icon} class="w-5 h-5" />
          <span><%= @section.title %></span>
        </div>
      </div>

      <div class="ml-4">
        <%= for item <- @section.items do %>
          <div class={"py-1 px-2 hover:bg-gray-700 rounded flex justify-between items-center " <>
              if has_active_tab_for_item?(item.id, @tabs, @active_tab), do: "bg-gray-700 border-l-2 border-blue-400", else: ""}>
            <!-- Section item name -->
            <span
              phx-click="select-section-item"
              phx-value-id={item.id}
              phx-value-category={@section.id}
              class="flex-grow cursor-pointer"
            >
              <%= if @section.id == "chapters" && Map.has_key?(item, :chapter_number) do %>
                <span class="font-medium mr-1"><%= item.chapter_number %></span>
              <% end %>
              <%= item.label %>
            </span>

            <%= if @section.id != "general" do %>
              <!-- Delete button - now using a dedicated form for deletion to prevent event propagation issues -->
              <form phx-submit="show-delete-confirmation" class="inline">
                <input type="hidden" name="item_id" value={item.id} />
                <input type="hidden" name="category" value={@section.id} />
                <button
                  type="submit"
                  class="text-gray-400 hover:text-red-400"
                >
                  <.icon name="hero-x-mark" class="w-3 h-3" />
                </button>
              </form>
            <% end %>
          </div>
        <% end %>

        <%= if @section.id != "general" do %>
          <!-- Add new item button for this section -->
          <div
            class="py-1 px-2 mt-2 text-gray-400 hover:text-white hover:bg-gray-700 cursor-pointer rounded flex items-center gap-1"
            phx-click="add-section-item"
            phx-value-category={@section.id}
          >
            <.icon name="hero-plus-small" class="w-4 h-4" />
            <span class="text-sm">Neuer Eintrag</span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr(:tabs, :list, required: true)
  attr(:active_tab, :string, required: true)

  def tabs_bar(assigns) do
    ~H"""
    <!-- Top tab bar - fixed height, horizontally scrollable -->
    <div class="bg-gray-700 text-white flex overflow-x-auto whitespace-nowrap" style="min-height: 42px;">
      <%= for tab <- @tabs do %>
        <div
          class={"px-4 py-2 flex items-center gap-2 cursor-pointer whitespace-nowrap #{if @active_tab == tab.id, do: "bg-gray-600 border-t-2 border-blue-400", else: "hover:bg-gray-600"}"}
          phx-click="select-tab"
          phx-value-id={tab.id}
        >
          <%= if tab.id == "new_tab" do %>
            <.icon name="hero-plus" class="w-4 h-4" />
          <% else %>
            <span><%= tab.label %></span>
            <button
              class="ml-2 text-gray-400 hover:text-white"
              phx-click="close-tab"
              phx-value-id={tab.id}
            >
              <.icon name="hero-x-mark" class="w-3 h-3" />
            </button>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  attr(:tabs, :list, required: true)
  attr(:active_tab, :string, required: true)
  attr(:loading, :boolean, default: false)
  attr(:ai_correction_disabled, :boolean, default: true)
  attr(:confirm_changes_disabled, :boolean, default: true)
  attr(:discard_changes_disabled, :boolean, default: true)
  attr(:auto_chapter_disabled, :boolean, default: false)
  attr(:manual_verification_disabled, :boolean, default: false)
  attr(:ai_optimize_disabled, :boolean, default: false)

  def content_area(assigns) do
    ~H"""
    <!-- Content area with fixed tab bar and scrollable content -->
    <div class="flex-1 flex flex-col bg-white">
      <!-- Content wrapper - this div will scroll -->
      <%= for tab <- @tabs do %>
        <div class={if @active_tab == tab.id, do: "h-full flex flex-col overflow-auto", else: "hidden"}>
          <%= cond do %>
            <% tab.id == "new_tab" -> %>
              <.new_tab_content />
            <% tab.category == "general" -> %>
              <.general_tab_content tab={tab} />
            <% tab.category == "parties" -> %>
              <.parties_tab_content tab={tab} />
            <% tab.category == "chapters" -> %>
              <.standard_tab_content
                tab={tab}
                loading={@loading}
                ai_correction_disabled={@ai_correction_disabled}
                confirm_changes_disabled={@confirm_changes_disabled}
                discard_changes_disabled={@discard_changes_disabled}
                auto_chapter_disabled={@auto_chapter_disabled}
                manual_verification_disabled={@manual_verification_disabled}
                ai_optimize_disabled={@ai_optimize_disabled}
              />
            <% true -> %>
              <.standard_tab_content
                tab={tab}
                loading={@loading}
                ai_correction_disabled={@ai_correction_disabled}
                confirm_changes_disabled={@confirm_changes_disabled}
                discard_changes_disabled={@discard_changes_disabled}
                auto_chapter_disabled={@auto_chapter_disabled}
                manual_verification_disabled={@manual_verification_disabled}
                ai_optimize_disabled={@ai_optimize_disabled}
              />
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  attr(:tab, :map, required: true)
  attr(:loading, :boolean, default: false)
  attr(:ai_correction_disabled, :boolean, default: true)
  attr(:confirm_changes_disabled, :boolean, default: true)
  attr(:discard_changes_disabled, :boolean, default: true)
  attr(:auto_chapter_disabled, :boolean, default: false)
  attr(:manual_verification_disabled, :boolean, default: false)
  attr(:ai_optimize_disabled, :boolean, default: false)

  def standard_tab_content(assigns) do
    # Ensure active_meta_info exists in the tab
    assigns =
      update_in(assigns.tab, fn tab ->
        if Map.has_key?(tab, :active_meta_info) do
          tab
        else
          Map.put(tab, :active_meta_info, %{})
        end
      end)

    # Set default button states if they don't exist
    assigns =
      assigns
      |> assign_new(:ai_correction_disabled, fn -> false end)
      |> assign_new(:confirm_changes_disabled, fn -> false end)
      |> assign_new(:discard_changes_disabled, fn -> false end)
      |> assign_new(:auto_chapter_disabled, fn -> false end)
      |> assign_new(:manual_verification_disabled, fn -> false end)
      |> assign_new(:ai_optimize_disabled, fn -> false end)

    # Get chapter versions
    chapter_versions = Map.get(assigns.tab, :chapter_versions, [])
    current_version = Map.get(assigns.tab, :current_version, length(chapter_versions))

    # Add these to assigns
    assigns =
      assigns
      |> assign(:chapter_versions, chapter_versions)
      |> assign(:current_version, current_version)

    ~H"""
    <!-- Full height container with scrollable content -->
    <div class="h-full overflow-auto bg-white text-black">
      <!-- Title input for the tab - fixed height -->
      <div class="p-4 border-b flex-shrink-0 bg-white text-black sticky top-0 z-10">
        <div class="flex items-center">
          <!-- Chapter number field -->
          <label class="font-medium mr-2 text-black">Kapitel-Nr.:</label>
          <input
            type="text"
            value={Map.get(@tab, :chapter_number, "")}
            class="w-24 p-2 border rounded text-black bg-white mr-4"
            phx-blur="update-chapter-number"
            phx-value-id={@tab.id}
            pattern="[0-9.]+"
            title="Bitte nur Zahlen und Punkte eingeben (z.B. 1.2.3)"
          />
          <label class="font-medium mr-2 text-black">Titel:</label>
          <input
            type="text"
            value={@tab.label}
            class="flex-1 p-2 border rounded text-black bg-white"
            phx-blur="update-tab-title"
            phx-value-id={@tab.id}
          />
        </div>
      </div>
      <!-- Full height container that grows with content -->
      <div class="p-4 flex-grow bg-white text-black">
        <!-- Info section -->
        <div class="mb-6">
          <h3 class="text-lg font-medium text-gray-800 mb-2">Informationen zum Kapitel:</h3>
          <textarea
            id={"info-#{@tab.id}"}
            class="w-full p-2 border rounded"
            style="min-height: 100px;"
            phx-blur="save-chapter-info"
            phx-value-id={@tab.id}
            placeholder="Welche Inhalte sollten im Kapitel enthalten sein?"
          ><%= Map.get(@tab, :chapter_info, "") %></textarea>
        </div>

        <!-- New section: Additional metadata for automatic chapter creation -->
        <div class="mb-6">
          <h3 class="text-lg font-medium text-gray-800 mb-2">Zusätzliche Informationen für die automatische Kapitelerstellung:</h3>

          <!-- Collapsible sections -->
          <.metadata_collapsible
            title="Grundlegende Informationen"
            id={"basic-info-#{@tab.id}"}
            tab_id={@tab.id}
            metadata_key="basic_info"
            active_meta_info={Map.get(@tab, :active_meta_info, %{})}
          />

          <.metadata_collapsible
            title="Gerätedaten"
            id={"device-info-#{@tab.id}"}
            tab_id={@tab.id}
            metadata_key="device_info"
            active_meta_info={Map.get(@tab, :active_meta_info, %{})}
          />

          <.metadata_collapsible
            title="Angaben der beteiligten Personen"
            id={"parties-info-#{@tab.id}"}
            tab_id={@tab.id}
            metadata_key="parties"
            active_meta_info={Map.get(@tab, :active_meta_info, %{})}
          />
        </div>

        <!-- Main content section -->
        <div class="mb-4">
          <div class="flex justify-between items-center mb-2">
            <h3 class="text-lg font-medium text-gray-800">Kapiteltext:</h3>
            <!-- Action buttons and loading spinner container -->
            <div class="flex items-center gap-2">
              <!-- Modern circular spinner -->
              <div class={if @loading, do: "flex items-center mr-2", else: "hidden"}>
                <div class="w-4 h-4 border-2 border-blue-600 border-t-transparent rounded-full animate-spin"></div>
              </div>

              <button
                type="button"
                class="bg-green-500 hover:bg-green-600 text-white px-3 py-1 rounded text-sm flex items-center gap-1 disabled:opacity-50 disabled:cursor-not-allowed"
                phx-click="start-auto-chapter-creation"
                phx-value-id={@tab.id}
                disabled={@loading || @auto_chapter_disabled}
              >
                <.icon name="hero-sparkles" class="w-4 h-4" />
                <span>Starte automatische Kapitelerstellung</span>
              </button>

              <button
                type="button"
                class="bg-orange-500 hover:bg-orange-600 text-white px-3 py-1 rounded text-sm flex items-center gap-1 disabled:opacity-50 disabled:cursor-not-allowed"
                phx-click="start-manual-verification"
                phx-value-id={@tab.id}
                disabled={@loading || @manual_verification_disabled}
              >
                <.icon name="hero-shield-check" class="w-4 h-4" />
                <span>Starte manuelle Verifikation</span>
              </button>

              <button
                type="button"
                class="bg-blue-500 hover:bg-blue-600 text-white px-3 py-1 rounded text-sm flex items-center gap-1 disabled:opacity-50 disabled:cursor-not-allowed"
                phx-click="ai-optimization"
                phx-value-id={@tab.id}
                disabled={@loading || @ai_optimize_disabled}
              >
                <.icon name="hero-sparkles" class="w-4 h-4" />
                <span>Text mit AI optimieren</span>
              </button>
            </div>
          </div>

          <!-- Text content area with TipTap editor -->
          <div class="content-area mb-2">
            <.live_component
              module={HaimedaCoreWeb.ReportsEditor.TipTapEditor}
              id={"tiptap-editor-#{@tab.id}"}
              tab_id={@tab.id}
              content={@tab.content}
              formatted_content={Map.get(@tab, :formatted_content)}
              read_only={Map.get(@tab, :read_only, false)}
            />

            <!-- Version navigation and control buttons -->
            <div class="flex justify-between items-center mt-2">
              <div class="flex items-center space-x-2">
                <button
                  type="button"
                  phx-click="ai-correction"
                  phx-value-id={@tab.id}
                  class="bg-yellow-500 hover:bg-yellow-600 text-white px-3 py-1 rounded text-sm flex items-center gap-1 disabled:opacity-50 disabled:cursor-not-allowed"
                  disabled={@ai_correction_disabled}
                >
                  <.icon name="hero-sparkles" class="w-4 h-4" />
                  <span>Mit Änderungen durch AI neuverfassen</span>
                </button>

                <button
                  type="button"
                  phx-click="confirm-changes"
                  phx-value-id={@tab.id}
                  class="bg-green-500 hover:bg-green-600 text-white px-3 py-1 rounded text-sm flex items-center gap-1 ml-2 disabled:opacity-50 disabled:cursor-not-allowed"
                  disabled={@confirm_changes_disabled}
                >
                  <.icon name="hero-check" class="w-4 h-4" />
                  <span>Bestätige Änderungen und beende Korrekturmodus</span>
                </button>
              </div>

              <!-- Version controls moved to the right -->
              <div class="flex items-center space-x-2 ml-auto">
                <!-- Version navigation with arrows -->
                <div class="flex items-center border rounded px-2 py-1 bg-gray-100">
                  <button
                    type="button"
                    phx-click="navigate_version"
                    phx-value-id={@tab.id}
                    phx-value-direction="prev"
                    class="text-gray-600 hover:text-black disabled:opacity-30"
                    disabled={@current_version <= 1}
                  >
                    <.icon name="hero-chevron-left" class="w-4 h-4" />
                  </button>

                  <span class="mx-2 text-sm">
                    <%= @current_version %> von <%= length(@chapter_versions) %>
                  </span>

                  <button
                    type="button"
                    phx-click="navigate_version"
                    phx-value-id={@tab.id}
                    phx-value-direction="next"
                    class="text-gray-600 hover:text-black disabled:opacity-30"
                    disabled={@current_version >= length(@chapter_versions)}
                  >
                    <.icon name="hero-chevron-right" class="w-4 h-4" />
                  </button>
                </div>

                <!-- New version button -->
                <button
                  type="button"
                  phx-click="add_version"
                  phx-value-id={@tab.id}
                  class="bg-blue-500 hover:bg-blue-600 text-white px-2 py-1 rounded text-xs flex items-center"
                >
                  <.icon name="hero-plus" class="w-3 h-3 mr-1" />
                  <span>Neue Version</span>
                </button>

                <!-- Delete version button -->
                <button
                  type="button"
                  phx-click="show-version-delete-confirmation"
                  phx-value-id={@tab.id}
                  phx-value-version={@current_version}
                  class="bg-red-500 hover:bg-red-600 text-white px-2 py-1 rounded text-xs flex items-center disabled:opacity-50"
                  disabled={length(@chapter_versions) <= 1}
                >
                  <.icon name="hero-trash" class="w-3 h-3 mr-1" />
                  <span>Version löschen</span>
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr(:tab, :map, required: true)

  def parties_tab_content(assigns) do
    person_statements =
      ContentPersistence.get_person_statements_for_ui(
        Map.get(assigns.tab, :person_statements, "[]")
      )

    analysis_statements =
      ContentPersistence.get_analysis_statements_for_ui(
        Map.get(assigns.tab, :analysis_statements, "[]")
      )

    # Get a list of IDs already in use by person statements
    used_person_ids =
      person_statements
      |> Enum.map(fn stmt -> Map.get(stmt, "id") end)

    assigns = assign(assigns, :person_statements, person_statements)
    assigns = assign(assigns, :analysis_statements, analysis_statements)
    assigns = assign(assigns, :used_person_ids, used_person_ids)

    ~H"""
    <!-- Full height container with scrollable content -->
    <div class="h-full overflow-auto bg-white text-black">
      <!-- Title input for the tab - fixed height -->
      <div class="p-4 border-b flex-shrink-0 bg-white text-black sticky top-0 z-10">
        <div class="flex items-center">
          <label class="font-medium mr-2 text-black">Titel:</label>
          <input
            type="text"
            value={@tab.label}
            class="flex-1 p-2 border rounded text-black bg-white"
            phx-blur="update-tab-title"
            phx-value-id={@tab.id}
          />
        </div>
      </div>
      <!-- Full height container that grows with content -->
      <div class="p-4 flex-grow bg-white text-black">
        <!-- Person statements section -->
        <div class="mb-6">
          <div class="flex items-center justify-between mb-2">
            <h3 class="text-lg font-medium text-gray-800">Angaben der Person:</h3>
            <button
              type="button"
              class="flex items-center gap-1 text-blue-600 hover:text-blue-800"
              phx-click="add-person-statement"
              phx-value-id={@tab.id}
            >
              <.icon name="hero-plus-circle" class="w-5 h-5" />
              <span>Neue Aussage hinzufügen</span>
            </button>
          </div>
          <%= if Enum.empty?(@person_statements) do %>
            <div class="text-gray-500 italic mb-3">Keine Aussagen vorhanden. Fügen Sie eine neue Aussage hinzu.</div>
          <% else %>
            <%= for {statement, index} <- Enum.with_index(@person_statements) do %>
              <div class="mb-4 border-l-4 border-blue-200 pl-3 py-2">
                <div class="flex items-center justify-between mb-2">
                  <div class="flex items-center gap-2">
                    <h4 class="font-medium">Aussage</h4>
                    <select
                      class="p-1 border rounded text-sm min-w-[50px] text-left"
                      id={"statement-id-select-#{index}"}
                      phx-input="update-person-statement-id"
                      phx-value-id={@tab.id}
                      phx-value-index={index}
                      phx-debounce="0"
                      phx-hook="SelectChangeHook"
                    >
                      <%= for n <- 1..20 do %>
                        <% current_id = statement["id"] %>
                        <% id_in_use = n in @used_person_ids && n != current_id %>
                        <option value={n} selected={current_id == n} disabled={id_in_use} class={if id_in_use, do: "text-gray-400", else: ""}>
                          <%= n %><%= if id_in_use, do: " (belegt)", else: "" %>
                        </option>
                      <% end %>
                    </select>
                  </div>
                  <button
                    type="button"
                    class="p-1 text-red-600 hover:bg-red-100 rounded"
                    phx-click="remove-person-statement"
                    phx-value-id={@tab.id}
                    phx-value-index={index}
                  >
                    <.icon name="hero-trash" class="w-4 h-4" />
                  </button>
                </div>
                <textarea
                  class="w-full p-2 border rounded"
                  rows="4"
                  phx-blur="update-person-statement"
                  phx-value-id={@tab.id}
                  phx-value-index={index}
                  placeholder="Aussage der Person hier eingeben..."
                ><%= statement["content"] %></textarea>
              </div>
            <% end %>
          <% end %>
        </div>

        <!-- Analysis section -->
        <div class="mb-4">
          <div class="flex items-center justify-between mb-2">
            <h3 class="text-lg font-medium text-gray-800">Analyse der Angaben:</h3>
            <button
              type="button"
              class="flex items-center gap-1 text-blue-600 hover:text-blue-800"
              phx-click="add-analysis-statement"
              phx-value-id={@tab.id}
            >
              <.icon name="hero-plus-circle" class="w-5 h-5" />
              <span>Neue Analyse hinzufügen</span>
            </button>
          </div>
          <%= if Enum.empty?(@analysis_statements) do %>
            <div class="text-gray-500 italic mb-3">Keine Analysen vorhanden. Fügen Sie eine neue Analyse hinzu.</div>
          <% else %>
            <%= for {statement, index} <- Enum.with_index(@analysis_statements) do %>
              <div class="mb-4 border-l-4 border-green-200 pl-3 py-2">
                <div class="flex items-center justify-between mb-2">
                  <div class="flex items-center gap-2">
                    <h4 class="font-medium">Analyse zu Aussage</h4>
                    <select
                      class="p-1 border rounded text-sm min-w-[50px] text-left"
                      id={"analysis-related-select-#{index}"}
                      phx-input="update-analysis-statement-related"
                      phx-value-id={@tab.id}
                      phx-value-index={index}
                      phx-debounce="0"
                      phx-hook="SelectChangeHook"
                    >
                      <%= for n <- 1..20 do %>
                        <% current_related_to = statement["related_to"] %>
                        <% id_exists = n in @used_person_ids %>
                        <option value={n} selected={current_related_to == n} disabled={!id_exists} class={if !id_exists, do: "text-gray-400", else: ""}>
                          <%= n %><%= if !id_exists, do: "", else: "" %>
                        </option>
                      <% end %>
                    </select>
                  </div>
                  <button
                    type="button"
                    class="p-1 text-red-600 hover:bg-red-100 rounded"
                    phx-click="remove-analysis-statement"
                    phx-value-id={@tab.id}
                    phx-value-index={index}
                  >
                    <.icon name="hero-trash" class="w-4 h-4" />
                  </button>
                </div>
                <textarea
                  class="w-full p-2 border rounded"
                  rows="4"
                  phx-blur="update-analysis-statement"
                  phx-value-id={@tab.id}
                  phx-value-index={index}
                  placeholder="Analyse zur Aussage hier eingeben..."
                ><%= statement["content"] %></textarea>
              </div>
            <% end %>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr(:tab, :map, required: true)

  def general_tab_content(assigns) do
    pairs = parse_key_value_pairs(assigns.tab.content)
    assigns = assign(assigns, :pairs, pairs)

    ~H"""
    <!-- Full height container with scrollable content -->
    <div class="h-full overflow-auto bg-white text-black">
      <!-- Fixed title header for general sections -->
      <div class="p-4 border-b flex-shrink-0 bg-white text-black sticky top-0 z-10">
        <div class="flex items-center">
          <h2 class="text-xl font-semibold text-black"><%= @tab.label %></h2>
        </div>
      </div>
      <!-- Key-Value pairs editor -->
      <div class="p-4 flex-grow">
        <div class="border rounded p-4 bg-gray-50">
          <h3 class="text-lg font-medium mb-4">Eigenschaften</h3>
          <!-- Key-Value pairs -->
          <%= if length(@pairs) > 0 do %>
            <%= for {pair, index} <- Enum.with_index(@pairs) do %>
              <div class="flex items-start gap-4 mb-3 key-value-pair">
                <div class="flex-1">
                  <label class="block text-sm font-medium text-gray-700 mb-1">Bezeichnung</label>
                  <input
                    type="text"
                    value={Map.get(pair, "key", "")}
                    class="w-full p-2 border rounded"
                    phx-blur="update-key-value-pair"
                    phx-value-id={@tab.id}
                    phx-value-index={index}
                    phx-value-field="key"
                  />
                </div>
                <div class="flex-1">
                  <label class="block text-sm font-medium text-gray-700 mb-1">Wert</label>
                  <input
                    type="text"
                    value={Map.get(pair, "value", "")}
                    class="w-full p-2 border rounded"
                    phx-blur="update-key-value-pair"
                    phx-value-id={@tab.id}
                    phx-value-index={index}
                    phx-value-field="value"
                  />
                </div>
                <div class="pt-7">
                  <button
                    type="button"
                    class="p-1 bg-red-100 text-red-600 hover:bg-red-200 rounded"
                    phx-click="remove-key-value-pair"
                    phx-value-id={@tab.id}
                    phx-value-index={index}
                  >
                    <.icon name="hero-trash" class="w-4 h-4" />
                  </button>
                </div>
              </div>
            <% end %>
          <% else %>
            <div class="text-gray-500 italic mb-3">Keine Eigenschaften vorhanden.</div>
          <% end %>
          <!-- Add new pair button -->
          <button
            type="button"
            class="mt-2 flex items-center gap-1 text-blue-600 hover:text-blue-800"
            phx-click="add-key-value-pair"
            phx-value-id={@tab.id}
          >
            <.icon name="hero-plus-circle" class="w-5 h-5" />
            <span>Neue Eigenschaft hinzufügen</span>
          </button>
        </div>
      </div>
    </div>
    """
  end

  def new_tab_content(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center h-full text-gray-500">
      <div class="text-xl mb-4">Klicken Sie auf +, um ein neues Kapitel zu erstellen</div>
      <button
        class="bg-blue-500 hover:bg-blue-600 text-white px-4 py-2 rounded flex items-center gap-2"
        phx-click="add-tab"
      >
        <.icon name="hero-document-plus" class="w-5 h-5" />
        <span>Neues Kapitel</span>
      </button>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:category, :string, required: true)
  attr(:item_label, :string, required: true)
  attr(:version, :integer, default: nil)

  def delete_confirmation_modal(assigns) do
    ~H"""
    <div id="delete-confirmation-modal" class="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50">
      <div class="bg-white rounded-lg shadow-xl max-w-md w-full p-6 mx-4">
        <div class="mb-4 text-center">
          <div class="mx-auto flex items-center justify-center h-12 w-12 rounded-full bg-red-100 mb-4">
            <.icon name="hero-exclamation-triangle" class="h-6 w-6 text-red-600" />
          </div>

          <%= if @category == "version" do %>
            <h3 class="text-lg font-medium text-gray-900 mb-2">Version wirklich löschen?</h3>
            <p class="text-sm text-gray-600 mt-2">
              Die Version "<span class="font-semibold"><%= @item_label %></span>" wird dauerhaft gelöscht und kann nicht wiederhergestellt werden.
            </p>
          <% else %>
            <h3 class="text-lg font-medium text-gray-900 mb-2">Kapitel/Bereich wirklich löschen?</h3>
            <p class="text-sm text-gray-600 mt-2">
              Der Eintrag "<span class="font-semibold"><%= @item_label %></span>" wird dauerhaft gelöscht und kann nicht wiederhergestellt werden.
            </p>
          <% end %>
        </div>
        <div class="flex items-center justify-between gap-3 mt-5">
          <button
            type="button"
            phx-click="confirm-delete"
            phx-value-id={@id}
            phx-value-category={@category}
            phx-value-version={@version}
            class="w-full inline-flex justify-center items-center rounded-md border border-transparent px-4 py-2 bg-red-600 text-base font-medium text-white hover:bg-red-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-red-500 sm:text-sm"
          >
            Löschen
          </button>
          <button
            type="button"
            phx-click="cancel-delete"
            class="w-full inline-flex justify-center items-center rounded-md border border-gray-300 px-4 py-2 bg-white text-base font-medium text-gray-700 hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-blue-500 sm:text-sm"
          >
            Abbrechen
          </button>
        </div>
      </div>
    </div>
    """
  end

  # Helper to parse key-value pairs from content string - improved error handling
  defp parse_key_value_pairs(""), do: []
  defp parse_key_value_pairs(nil), do: []

  defp parse_key_value_pairs(content) do
    case Jason.decode(content) do
      {:ok, pairs} when is_list(pairs) ->
        # Ensure all pairs have both key and value fields
        Enum.map(pairs, fn pair ->
          pair
          |> Map.put_new("key", "")
          |> Map.put_new("value", "")
        end)

      _ ->
        # Return empty list with proper structure when JSON is invalid
        []
    end
  end

  # Helper function to check if a navigation item has an active tab
  def has_active_tab_for_item?(item_id, tabs, active_tab) do
    active_tab != "new_tab" &&
      Enum.any?(tabs, fn tab ->
        tab.id == active_tab && tab.section_id == item_id
      end)
  end

  # Helper to parse statements with titles from JSON
  defp parse_statements_with_titles(""), do: []
  defp parse_statements_with_titles(nil), do: []

  defp parse_statements_with_titles(content) do
    case Jason.decode(content) do
      {:ok, statements} when is_list(statements) ->
        Enum.with_index(statements)
        |> Enum.map(fn
          {%{"title" => title, "content" => content}, _} ->
            %{"title" => title, "content" => content}

          {content, index} when is_binary(content) ->
            # Convert old format (simple string) to new format (map with title and content)
            %{"title" => "Aussage #{index + 1}", "content" => content}

          {_, index} ->
            # Handle unexpected format
            %{"title" => "Aussage #{index + 1}", "content" => ""}
        end)

      _ ->
        []
    end
  end

  # parse_statements for backward compatibility
  defp parse_statements(""), do: []
  defp parse_statements(nil), do: []

  defp parse_statements(content) do
    case Jason.decode(content) do
      {:ok, statements} when is_list(statements) ->
        # Extract just the content from the new format
        Enum.map(statements, fn
          %{"title" => _title, "content" => content} -> content
          content when is_binary(content) -> content
          _ -> ""
        end)

      _ ->
        []
    end
  end

  attr(:title, :string, required: true)
  attr(:id, :string, required: true)
  attr(:tab_id, :string, required: true)
  attr(:metadata_key, :string, required: true)
  attr(:active_meta_info, :map, default: %{})

  def metadata_collapsible(assigns) do
    ~H"""
    <div class="border rounded mb-2">
      <div
        class="flex justify-between items-center p-3 bg-gray-100 cursor-pointer"
        phx-click={JS.toggle(to: "##{@id}-content")}
      >
        <h4 class="font-medium"><%= @title %></h4>
        <.icon name="hero-chevron-down" class="w-5 h-5 text-gray-500" />
      </div>
      <div id={"#{@id}-content"} class="p-3 hidden">
        <%= case @metadata_key do %>
          <% "basic_info" -> %>
            <.metadata_buttons_for_basic_info
              tab_id={@tab_id}
              active_meta_info={@active_meta_info}
            />

          <% "device_info" -> %>
            <.metadata_buttons_for_device_info
              tab_id={@tab_id}
              active_meta_info={@active_meta_info}
            />

          <% "parties" -> %>
            <.metadata_buttons_for_parties
              tab_id={@tab_id}
              active_meta_info={@active_meta_info}
            />
        <% end %>
      </div>
    </div>
    """
  end

  # Component for basic info metadata buttons
  attr(:tab_id, :string, required: true)
  attr(:active_meta_info, :map, default: %{})

  def metadata_buttons_for_basic_info(assigns) do
    basic_info = get_basic_info()
    assigns = assign(assigns, :basic_info, basic_info)

    ~H"""
    <div class="flex flex-col gap-2">
      <%= if Enum.empty?(@basic_info) do %>
        <p class="text-gray-500 italic">Keine Informationen verfügbar.</p>
      <% else %>
        <%= for {key, value} <- @basic_info do %>
          <button
            type="button"
            phx-click="toggle-meta-info-button"
            phx-value-id={@tab_id}
            phx-value-section="basic_info"
            phx-value-key={key}
            class={"w-full text-left p-2 rounded text-sm #{if is_button_active?(@active_meta_info, "basic_info", key), do: "bg-green-200 hover:bg-green-300 text-green-800", else: "bg-gray-200 hover:bg-gray-300 text-gray-800"}"}
          >
            <%= key %>: <%= value %>
            <%= if is_button_active?(@active_meta_info, "basic_info", key) do %>
              <span class="float-right text-xs bg-green-800 text-white px-1 rounded">Aktiv</span>
            <% end %>
          </button>
        <% end %>
      <% end %>
    </div>
    """
  end

  # Component for device info metadata buttons
  attr(:tab_id, :string, required: true)
  attr(:active_meta_info, :map, default: %{})

  def metadata_buttons_for_device_info(assigns) do
    device_info = get_device_info()
    assigns = assign(assigns, :device_info, device_info)

    ~H"""
    <div class="flex flex-col gap-2">
      <%= if Enum.empty?(@device_info) do %>
        <p class="text-gray-500 italic">Keine Informationen verfügbar.</p>
      <% else %>
        <%= for {key, value} <- @device_info do %>
          <button
            type="button"
            phx-click="toggle-meta-info-button"
            phx-value-id={@tab_id}
            phx-value-section="device_info"
            phx-value-key={key}
            class={"w-full text-left p-2 rounded text-sm #{if is_button_active?(@active_meta_info, "device_info", key), do: "bg-green-200 hover:bg-green-300 text-green-800", else: "bg-gray-200 hover:bg-gray-300 text-gray-800"}"}
          >
            <%= key %>: <%= value %>
            <%= if is_button_active?(@active_meta_info, "device_info", key) do %>
              <span class="float-right text-xs bg-green-800 text-white px-1 rounded">Aktiv</span>
            <% end %>
          </button>
        <% end %>
      <% end %>
    </div>
    """
  end

  # Component for parties metadata buttons
  attr(:tab_id, :string, required: true)
  attr(:active_meta_info, :map, default: %{})

  def metadata_buttons_for_parties(assigns) do
    parties_info = get_parties_info()
    assigns = assign(assigns, :parties_info, parties_info)

    ~H"""
    <div class="flex flex-col gap-2">
      <%= if Enum.empty?(@parties_info) do %>
        <p class="text-gray-500 italic">Keine Informationen verfügbar.</p>
      <% else %>
        <%= for {party_title, party_data} <- @parties_info do %>
          <!-- Person statements -->
          <%= for statement <- Map.get(party_data, :person_statements, []) do %>
            <button
              type="button"
              phx-click="toggle-meta-info-button"
              phx-value-id={@tab_id}
              phx-value-section="parties"
              phx-value-key={"#{party_title}:person:#{statement.id}"}
              class={"w-full text-left p-2 rounded text-sm #{if is_button_active?(@active_meta_info, "parties", "#{party_title}:person:#{statement.id}"), do: "bg-green-200 hover:bg-green-300 text-green-800", else: "bg-gray-200 hover:bg-gray-300 text-gray-800"}"}
            >
              <%= party_title %>: Aussage <%= statement.id %>
              <%= if is_button_active?(@active_meta_info, "parties", "#{party_title}:person:#{statement.id}") do %>
                <span class="float-right text-xs bg-green-800 text-white px-1 rounded">Aktiv</span>
              <% end %>
            </button>
          <% end %>

          <!-- Analysis statements -->
          <%= for statement <- Map.get(party_data, :analysis_statements, []) do %>
            <button
              type="button"
              phx-click="toggle-meta-info-button"
              phx-value-id={@tab_id}
              phx-value-section="parties"
              phx-value-key={"#{party_title}:analysis:#{statement.related_to}:#{statement.id}"}
              class={"w-full text-left p-2 rounded text-sm #{if is_button_active?(@active_meta_info, "parties", "#{party_title}:analysis:#{statement.related_to}:#{statement.id}"), do: "bg-green-200 hover:bg-green-300 text-green-800", else: "bg-gray-200 hover:bg-gray-300 text-gray-800"}"}
            >
              <%= party_title %>: Analyse Aussage <%= statement.related_to %> (<%= statement.id %>)
              <%= if is_button_active?(@active_meta_info, "parties", "#{party_title}:analysis:#{statement.related_to}:#{statement.id}") do %>
                <span class="float-right text-xs bg-green-800 text-white px-1 rounded">Aktiv</span>
              <% end %>
            </button>
          <% end %>
        <% end %>
      <% end %>
    </div>
    """
  end

  # Helper function to check if a button is active
  defp is_button_active?(active_meta_info, section, key) do
    # Handle nil or non-map active_meta_info for backwards compatibility
    section_data =
      case active_meta_info do
        meta when is_map(meta) -> Map.get(meta, section, %{})
        _ -> %{}
      end

    # If the key exists in the section data, it's active
    Map.has_key?(section_data, key)
  end

  # Helper function to get metadata value if it exists
  defp get_active_metadata_value(active_meta_info, section, key) do
    section_data =
      case active_meta_info do
        meta when is_map(meta) -> Map.get(meta, section, %{})
        _ -> %{}
      end

    Map.get(section_data, key)
  end

  # Helper function to get basic info metadata
  defp get_basic_info do
    case HaimedaCore.Report.get_current_report_context() do
      {:ok, report} ->
        general_data = Map.get(report, "general", %{})
        basic_info = Map.get(general_data, "basic_info", [])

        # Ensure basic_info is a list for backwards compatibility
        basic_info = if is_list(basic_info), do: basic_info, else: []

        basic_info
        |> Enum.reduce(%{}, fn item, acc ->
          case item do
            %{"key" => key, "value" => value} when key != "" ->
              Map.put(acc, key, value)

            _ ->
              acc
          end
        end)

      _ ->
        # Default values for when no report context is available
        %{
          "Auftraggebende Person" => "",
          "Anschrift" => "",
          "Gutachtentyp" => "",
          "Gutachtennummer" => "",
          "Datum der Begutachtung" => ""
        }
    end
  end

  # Helper function to get device info metadata
  defp get_device_info do
    case HaimedaCore.Report.get_current_report_context() do
      {:ok, report} ->
        general_data = Map.get(report, "general", %{})
        device_info = Map.get(general_data, "device_info", [])

        # Ensure device_info is a list for backwards compatibility
        device_info = if is_list(device_info), do: device_info, else: []

        device_info
        |> Enum.reduce(%{}, fn item, acc ->
          case item do
            %{"key" => key, "value" => value} when key != "" ->
              Map.put(acc, key, value)

            _ ->
              acc
          end
        end)

      _ ->
        # Default values for when no report context is available
        %{
          "Gerätebezeichnung" => "",
          "Hersteller" => "",
          "Modell" => "",
          "Seriennummer" => "",
          "Baujahr" => ""
        }
    end
  end

  # Helper function to get parties info metadata
  defp get_parties_info do
    case HaimedaCore.Report.get_current_report_context() do
      {:ok, report} ->
        parties = Map.get(report, "parties", [])

        parties
        |> Enum.reduce(%{}, fn party, acc ->
          title = Map.get(party, "title", "Unbekannt")

          # Extract person statements
          person_statements =
            party
            |> Map.get("person_statements", [])
            |> Enum.map(fn statement ->
              %{
                id: Map.get(statement, "id", 1),
                content: Map.get(statement, "content", "")
              }
            end)
            |> Enum.sort_by(& &1.id)

          # Extract analysis statements
          analysis_statements =
            party
            |> Map.get("analysis_statements", [])
            |> Enum.map(fn statement ->
              %{
                id: Map.get(statement, "id", 1),
                related_to: Map.get(statement, "related_to", 1),
                content: Map.get(statement, "content", "")
              }
            end)
            |> Enum.sort_by(& &1.id)

          # Add party data to accumulator
          if Enum.empty?(person_statements) and Enum.empty?(analysis_statements) do
            acc
          else
            Map.put(acc, title, %{
              person_statements: person_statements,
              analysis_statements: analysis_statements
            })
          end
        end)

      _ ->
        %{
          "Versicherungsnehmer" => %{
            person_statements: [
              %{id: 1, content: "Aussage 1"},
              %{id: 2, content: "Aussage 2"}
            ],
            analysis_statements: [
              %{id: 1, related_to: 1, content: "Analyse 1"},
              %{id: 2, related_to: 1, content: "Analyse 2"},
              %{id: 3, related_to: 2, content: "Analyse 3"}
            ]
          },
          "Sachverständiger" => %{
            person_statements: [
              %{id: 1, content: "Aussage 1"}
            ],
            analysis_statements: [
              %{id: 1, related_to: 1, content: "Analyse 1"}
            ]
          }
        }
    end
  end
end
