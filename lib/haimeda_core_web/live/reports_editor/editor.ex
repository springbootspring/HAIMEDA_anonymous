defmodule HaimedaCoreWeb.ReportsEditor.Editor do
  use HaimedaCoreWeb, :live_view
  alias HaimedaCore.Report

  alias HaimedaCoreWeb.ReportsEditor.{
    EditorSnippets,
    ContentPersistence,
    TabManagement,
    PartiesSection,
    OutputArea,
    MetadataSection,
    TipTapEditor,
    TiptapActions
  }

  alias HaimedaCore.MainController
  alias HaimedaCore.FeedbackModule
  require Logger

  @show_JS_debug false

  # Helper to return a short type name for debug/logging
  defp typeof(term) do
    cond do
      is_binary(term) -> "string"
      is_boolean(term) -> "boolean"
      is_integer(term) -> "integer"
      is_float(term) -> "float"
      is_list(term) -> "list"
      is_map(term) -> "map"
      is_tuple(term) -> "tuple"
      is_atom(term) -> "atom"
      is_function(term) -> "function"
      is_pid(term) -> "pid"
      is_reference(term) -> "reference"
      true -> "unknown"
    end
  end

  # Helpers to manage correction mode states
  def correction_mode_initiate(socket) do
    send(self(), {:set_button_state, :ai_correction, true})
    send(self(), {:set_button_state, :confirm_changes, true})
    send(self(), {:set_button_state, :discard_changes, true})
    send(self(), {:set_button_state, :auto_chapter, false})
    send(self(), {:set_button_state, :manual_verification, true})
    send(self(), {:set_button_state, :ai_optimize, false})
    socket
  end

  def correction_mode_reset(socket) do
    send(self(), {:set_button_state, :ai_correction, false})
    send(self(), {:set_button_state, :confirm_changes, false})
    send(self(), {:set_button_state, :discard_changes, true})
    send(self(), {:set_button_state, :auto_chapter, true})
    send(self(), {:set_button_state, :manual_verification, true})
    send(self(), {:set_button_state, :ai_optimize, true})
    socket
  end

  def disable_all_button_states do
    send(self(), {:set_button_state, :ai_correction, false})
    send(self(), {:set_button_state, :confirm_changes, false})
    send(self(), {:set_button_state, :discard_changes, false})
    send(self(), {:set_button_state, :auto_chapter, false})
    send(self(), {:set_button_state, :manual_verification, false})
    send(self(), {:set_button_state, :ai_optimize, false})
  end

  @impl true
  def mount(%{"id" => id}, session, socket) do
    if connected?(socket) do
      socket = push_event(socket, "add-body-class", %{class: "editor-page"})
      :timer.send_interval(30000, self(), :save_editor_session)
    end

    Report.set_current_report_id(id)

    case Report.get_report(id) do
      {:ok, report} ->
        nav_sections = MetadataSection.generate_nav_sections_from_report(report)
        initial_state = HaimedaCore.EditorSession.load_editor_session(id, report, nav_sections)

        # instead of using session tabs, fetch each from DB
        loaded_tabs =
          Enum.map(initial_state.tabs, fn tab ->
            ContentPersistence.load_content_from_db(
              %{assigns: %{report_id: id}},
              tab,
              tab.section_id,
              tab.category
            )
          end)

        socket =
          socket
          |> assign(:report, report)
          |> assign(:report_id, id)
          |> assign(:page_title, "HAIMEDA - #{report["name"]}")
          |> assign(:tabs, loaded_tabs)
          |> assign(:active_tab, initial_state.active_tab)
          |> assign(:nav_sections, nav_sections)
          |> assign(:delete_modal, nil)
          |> assign(:logs, initial_state.logs)
          |> assign(:chat_messages, initial_state.chat_messages)
          |> assign(:chat_input, "")
          # Initialize chat history from chat messages - extract user messages
          |> assign(
            :chat_history,
            extract_chat_history_from_messages(initial_state.chat_messages)
          )
          |> assign(:chat_history_index, -1)
          |> assign(:loading, false)
          |> assign(:loading_menubar, false)
          |> assign(:verification_count, initial_state.verification_count)
          |> assign(:previous_content_mode, initial_state.previous_content_mode)
          |> assign(:llm_params, initial_state.llm_params)
          |> assign(:selected_llm, initial_state.selected_llm)
          |> assign(:llm_options, initial_state.llm_options)
          |> assign(:loading_message, :default)
          |> assign(:verification_degree, initial_state.verification_degree)
          |> assign(:page_type, "editor")
          # Explicitly set button states to disabled by default
          |> assign(:ai_correction_disabled, true)
          |> assign(:confirm_changes_disabled, true)
          |> assign(:discard_changes_disabled, true)
          |> assign(:auto_chapter_disabled, false)
          |> assign(:manual_verification_disabled, false)
          |> assign(:ai_optimize_disabled, false)
          |> assign(:js_debug_logs, [])
          |> assign(:show_JS_debug, @show_JS_debug)
          |> assign(:correction_mode, false)
          |> assign(:llm_initialized, initial_state.llm_initialized)
          |> assign(:rag_initialized, initial_state.rag_initialized)

        # After initial socket assignment in mount
        if connected?(socket) do
          tab_id = socket.assigns.active_tab

          if tab_id do
            tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

            if tab && Map.get(tab, :formatted_content) do
              # Update correction mode based on the active tab content
              correction_mode = ContentPersistence.check_correction_mode(socket, tab_id)

              socket =
                push_event(socket, "force_refresh_editor", %{
                  tab_id: tab_id,
                  content: tab.content,
                  formatted_content: Jason.encode!(tab.formatted_content)
                })
                |> assign(:correction_mode, correction_mode)

              # Apply appropriate button states based on correction mode
              socket =
                if correction_mode,
                  do: correction_mode_initiate(socket),
                  else: correction_mode_reset(socket)
            else
              socket
            end
          else
            socket
          end
        else
          socket
        end

        # Check if LLM has already been initialized from the database
        # Only initialize if it hasn't been done before
        socket =
          if connected?(socket) && !socket.assigns.llm_initialized do
            # Set loading message specific to LLM integration
            socket =
              socket |> assign(:loading, true) |> assign(:loading_message, :llm_integration)

            # Capture the LiveView PID before starting the task
            live_view_pid = self()

            # Initialize general system settings
            HaimedaCore.MainController.initialize_system()

            # Start LLM integration in async task
            Task.async(fn ->
              result = HaimedaCore.MainController.verify_llm_integration_ollama(live_view_pid)
              # After verification completes, mark as initialized in the database
              HaimedaCore.EditorSession.set_llm_initialized(id, true)

              IO.inspect(result, label: "LLM Integration Result")

              if result do
                # Format the success message to avoid string conversion errors
                success_message =
                  case result do
                    %{model_paths: paths} when is_list(paths) ->
                      "LLM-Integration erfolgreich: #{length(paths)} Modelle gefunden"

                    string when is_binary(string) ->
                      "LLM-Integration erfolgreich: #{string}"

                    _ ->
                      "LLM-Integration erfolgreich"
                  end

                FeedbackModule.send_status_message(
                  live_view_pid,
                  success_message,
                  "success"
                )
              end

              send(live_view_pid, {:loading_message, :rag_verification})

              case MainController.initialize_RIM(live_view_pid) do
                {:ok, :success} ->
                  HaimedaCore.EditorSession.set_rag_initialized(id, true)

                  FeedbackModule.send_status_message(
                    live_view_pid,
                    "Datenbankintegration für RAG erfolgreich",
                    "success"
                  )

                {:error, reason} ->
                  FeedbackModule.send_status_message(
                    live_view_pid,
                    "Datenbankintegration für RAG fehlgeschlagen: #{reason}",
                    "error"
                  )
              end

              # After integration completes, set loading to false
              send(live_view_pid, {:loading, false})

              result
            end)

            socket |> assign(:llm_initialized, true)
          else
            socket
          end

        {:ok, socket}

      {:error, reason} ->
        {:ok,
         socket
         |> put_flash(:error, "Fehler beim Laden des Gutachtens: #{reason}")
         |> push_navigate(to: ~p"/reports")}
    end
  end

  # Helper function to extract chat history from chat messages
  defp extract_chat_history_from_messages(chat_messages) do
    chat_messages
    |> Enum.filter(fn msg -> msg.sender == "user" end)
    |> Enum.map(fn msg -> msg.content end)
    |> Enum.take(20)
    |> Enum.reverse()
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if connected?(socket) do
      # Push the current state to the JavaScript client
      socket =
        push_event(socket, "state", %{
          active_tab: socket.assigns.active_tab,
          report_id: socket.assigns.report_id,
          page_type: socket.assigns.page_type,
          # Add any other relevant state that would be helpful for debugging
          loading: socket.assigns.loading,
          tabs_count: length(socket.assigns.tabs),
          debug_timestamp: DateTime.utc_now() |> DateTime.to_string()
        })

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:save_editor_session, socket) do
    save_editor_session(socket)
    {:noreply, socket}
  end

  # Make save_editor_session public so TabManagement can use it
  def save_editor_session(socket) do
    report_id = socket.assigns.report_id
    session_data = HaimedaCore.EditorSession.prepare_session_data(socket)
    HaimedaCore.EditorSession.save_session(report_id, session_data)
  end

  @impl true
  def handle_event("submit-chat", %{"message" => message}, socket) when message != "" do
    # First add the user message to the chat
    FeedbackModule.send_chat_message(
      self(),
      message,
      "user"
    )

    # Store the message in chat history - newest first
    chat_history = [message | socket.assigns.chat_history || []] |> Enum.take(20)

    # Then start processing the request
    live_view_pid = self()
    send(self(), {:loading, true})
    send(self(), {:loading_message, :chat_response})

    Task.start(fn ->
      MainController.handle_user_request(live_view_pid, message)
      send(live_view_pid, {:loading, false})
    end)

    # Clear the chat input and reset history position
    socket = assign(socket, chat_input: "", chat_history: chat_history, chat_history_index: -1)

    # Force push an update to the input field to ensure it clears
    if connected?(socket) do
      socket = push_event(socket, "update-chat-input", %{value: ""})
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("navigate-chat-history", %{"direction" => direction}, socket) do
    history = socket.assigns.chat_history || []
    current_index = socket.assigns.chat_history_index || -1

    Logger.debug(
      "Chat history navigation: direction=#{direction}, history count=#{length(history)}, current_index=#{current_index}"
    )

    {new_index, new_input} =
      case direction do
        "up" when length(history) > 0 and current_index < length(history) - 1 ->
          # Move up in history (older messages)
          next_index = current_index + 1
          message = Enum.at(history, next_index, "")
          Logger.debug("Moving up to index #{next_index}, message: #{message}")
          {next_index, message}

        "down" when current_index > 0 ->
          # Move down in history (newer messages)
          prev_index = current_index - 1
          message = Enum.at(history, prev_index, "")
          Logger.debug("Moving down to index #{prev_index}, message: #{message}")
          {prev_index, message}

        "down" when current_index == 0 ->
          # At newest message, go to empty input
          Logger.debug("At newest message, clearing input")
          {-1, ""}

        _ ->
          # No change
          Logger.debug("No change in history navigation")
          {current_index, socket.assigns.chat_input}
      end

    # Update our state but don't rely on this to update the UI
    socket = assign(socket, chat_input: new_input, chat_history_index: new_index)

    # Directly push an event to update the chat input field
    if connected?(socket) do
      # Add a unique timestamp to make sure the event is processed as a distinct message
      socket =
        push_event(socket, "update-chat-input", %{
          value: new_input,
          timestamp: DateTime.utc_now() |> DateTime.to_string()
        })
    end

    {:noreply, socket}
  end

  # Handle empty message case
  @impl true
  def handle_event("submit-chat", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:add_chat_message, message}, socket) do
    chat_messages = socket.assigns.chat_messages ++ [message]
    updated_socket = assign(socket, chat_messages: chat_messages)
    save_editor_session(updated_socket)

    # Add try/catch for debugging if needed
    updated_socket =
      try do
        push_event(updated_socket, "scroll-chat-bottom", %{})
      rescue
        e ->
          Logger.error("Failed to push scroll event: #{inspect(e)}")
          updated_socket
      end

    {:noreply, updated_socket}
  end

  @impl true
  def handle_info({:add_log, log_data}, socket) do
    formatted_timestamp =
      case log_data.timestamp do
        %DateTime{} ->
          log_data.timestamp
          |> Time.to_string()
          |> String.slice(0, 8)

        _ when is_binary(log_data.timestamp) ->
          log_data.timestamp

        _ ->
          Time.utc_now() |> Time.to_string() |> String.slice(0, 8)
      end

    log_entry = %{
      timestamp: formatted_timestamp,
      message: log_data.message,
      type: log_data.type
    }

    logs = socket.assigns.logs ++ [log_entry]
    updated_socket = assign(socket, logs: logs)
    save_editor_session(updated_socket)
    # Push event to scroll log down
    updated_socket = push_event(updated_socket, "scroll-log-bottom", %{})
    {:noreply, updated_socket}
  end

  @impl true
  def handle_info({:loading, state}, socket) when is_boolean(state) do
    # Update loading state and log the change
    Logger.debug("Setting loading state to: #{state}")
    {:noreply, assign(socket, :loading, state)}
  end

  @impl true
  def handle_info({:loading_message, message_type}, socket) when is_atom(message_type) do
    # Update loading message state
    Logger.debug("Setting loading message to: #{message_type}")
    {:noreply, assign(socket, :loading_message, message_type)}
  end

  def handle_info({:update_textarea_field, content, mode}, socket) do
    # Log different information based on content type
    log_message =
      case content do
        content when is_map(content) ->
          "Updating textarea field with content type: #{inspect(content |> Map.keys())}"

        content when is_binary(content) ->
          "Updating textarea field with string content (length: #{String.length(content)})"

        _ ->
          "Updating textarea field with content of type: #{inspect(typeof(content))}"
      end

    Logger.info(log_message)

    # Send to OutputArea component with update_field mode
    send_update(HaimedaCoreWeb.ReportsEditor.OutputArea,
      id: "output-area",
      textarea_content: content,
      textarea_mode: mode,
      # This is the key difference - using :update_field mode
      output_mode: :update_field,
      editor_pid: self(),
      report_id: socket.assigns.report_id
    )

    # Don't immediately reset loading state - we'll get ai_correction_complete when done
    {:noreply, socket}
  end

  def handle_info({:update_textarea_multiple_versions, content_map, mode}, socket) do
    Logger.info("Received multiple content versions: #{map_size(content_map)} versions")

    # Check the format of the content in the map for logging purposes
    sample_format =
      case content_map do
        %{1 => first_item} ->
          "First item type: #{typeof(first_item)}, " <>
            if is_tuple(first_item) && tuple_size(first_item) >= 1,
              do: "Content type: #{typeof(elem(first_item, 0))}",
              else: "Not a tuple"

        _ ->
          "No content at key 1"
      end

    Logger.info("Content format sample: #{sample_format}")

    # Send directly to the OutputArea component with the update_versions mode
    send_update(HaimedaCoreWeb.ReportsEditor.OutputArea,
      id: "output-area",
      # Map of {rank, {content, run_number}}
      textarea_content: content_map,
      textarea_mode: mode,
      output_mode: :update_versions,
      editor_pid: self(),
      # Explicitly pass report_id
      report_id: socket.assigns.report_id
    )

    # Enable correction mode for version navigation
    socket = assign(socket, :correction_mode, true)
    socket = correction_mode_initiate(socket)

    # Add a status message about multiple versions
    FeedbackModule.send_status_message(
      self(),
      "#{map_size(content_map)} Versionen wurden aktualisiert und nach Qualität sortiert.",
      "success"
    )

    FeedbackModule.send_chat_message(
      self(),
      "Ich habe #{map_size(content_map)} Versionen erstellt und nach Qualität sortiert. Die beste Version wird angezeigt.",
      "hybrid_ai"
    )

    # Make sure to set the textarea mode to writable after processing all versions
    send(self(), {:set_textarea_mode, "writable"})

    # Directly navigate to version 1 (best version) to ensure it's immediately displayed
    Process.send_after(self(), {:navigate_to_version, 1}, 500)

    {:noreply, socket}
  end

  # Handler for direct version navigation
  def handle_info({:navigate_to_version, version_num}, socket) do
    tab_id = socket.assigns.active_tab
    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab do
      {:ok, _} =
        ContentPersistence.set_current_chapter_version(
          socket.assigns.report_id,
          tab.section_id,
          version_num
        )

      updated_tab = reload_tab_after_version_change(socket, tab_id)

      updated_tabs =
        Enum.map(socket.assigns.tabs, fn t ->
          if t.id == tab_id, do: updated_tab, else: t
        end)

      socket =
        socket
        |> assign(:tabs, updated_tabs)

      if tab_id == socket.assigns.active_tab && connected?(socket) do
        socket =
          push_event(socket, "force_refresh_editor", %{
            tab_id: tab_id,
            content: updated_tab.content,
            formatted_content: Jason.encode!(updated_tab.formatted_content)
          })
      end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:update_textarea_field_new_version, content, mode}, socket) do
    # Forward the message to the OutputArea component using send_update
    # Similar to correction mode but with different output_mode

    # Log different information based on content type
    log_message =
      case content do
        content when is_map(content) ->
          "Creating new version with content type: #{inspect(content |> Map.keys())}"

        content when is_binary(content) ->
          "Creating new version with string content (length: #{String.length(content)})"

        _ ->
          "Creating new version with content of type: #{inspect(typeof(content))}"
      end

    Logger.info(log_message)

    send_update(HaimedaCoreWeb.ReportsEditor.OutputArea,
      id: "output-area",
      textarea_content: content,
      textarea_mode: mode,
      output_mode: :new_version,
      # Pass the current process PID
      editor_pid: self(),
      # Explicitly pass report_id
      report_id: socket.assigns.report_id
    )

    # Set loading state to true - we'll reset it when the process completes
    socket = assign(socket, :loading, true)
    socket = assign(socket, :loading_message, :creating_version)

    # Don't immediately reset loading state - we'll do that when we get the :new_version_created message
    {:noreply, socket}
  end

  @impl true
  def handle_info({:update_textarea_field_correction_mode, content, mode}, socket) do
    # Forward the message to the OutputArea component using send_update
    # This ensures we use the right callback function in the component
    # Explicitly include our PID so the component can send messages back to us
    Logger.info(
      "Updating textarea field in correction mode with content type: #{inspect(content |> Map.keys())}"
    )

    send_update(HaimedaCoreWeb.ReportsEditor.OutputArea,
      id: "output-area",
      textarea_content: content,
      textarea_mode: mode,
      output_mode: :correction,
      # Pass the current process PID
      editor_pid: self()
    )

    send(self(), {:loading, false})

    # Don't immediately reset loading state - the component will do it when ready
    {:noreply, socket}
  end

  @impl true
  def handle_info({:set_button_state, button, enabled}, socket) do
    # Reverse the logic: 'enabled' is now whether the button should be enabled
    # So we invert it to get 'disabled' which is what our assigns use
    disabled = not enabled

    # Update the socket's state directly so it's available in templates
    updated_socket =
      case button do
        :ai_correction -> assign(socket, :ai_correction_disabled, disabled)
        :confirm_changes -> assign(socket, :confirm_changes_disabled, disabled)
        :discard_changes -> assign(socket, :discard_changes_disabled, disabled)
        :auto_chapter -> assign(socket, :auto_chapter_disabled, disabled)
        :manual_verification -> assign(socket, :manual_verification_disabled, disabled)
        :ai_optimize -> assign(socket, :ai_optimize_disabled, disabled)
      end

    # Also update the OutputArea component to keep them in sync
    status_key = :"#{button}_disabled"

    send_update(HaimedaCoreWeb.ReportsEditor.OutputArea,
      id: "output-area",
      mode: [{status_key, disabled}]
    )

    {:noreply, updated_socket}
  end

  @impl true
  def handle_info({:set_textarea_mode, mode}, socket) do
    # Forward the message to the OutputArea component
    send_update(HaimedaCoreWeb.ReportsEditor.OutputArea, id: "output-area", mode: mode)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:navigate_version, direction}, socket) do
    case direction do
      :previous ->
        send_update(HaimedaCoreWeb.ReportsEditor.OutputArea,
          id: "output-area",
          action: :previous_version
        )

      :next ->
        send_update(HaimedaCoreWeb.ReportsEditor.OutputArea,
          id: "output-area",
          action: :next_version
        )
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:add_content_version, content}, socket) do
    # Add a new version to the OutputArea component
    send_update(HaimedaCoreWeb.ReportsEditor.OutputArea, id: "output-area", add_version: content)
    {:noreply, socket}
  end

  @impl true
  def handle_event("ai-optimization", %{"id" => tab_id}, socket) do
    FeedbackModule.send_chat_message(
      self(),
      "Bitte optimiere den Text.",
      "user"
    )

    FeedbackModule.send_status_message(
      self(),
      "Text-Optimierung gestartet.",
      "info"
    )

    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab do
      # First update the socket with loading states
      socket =
        socket
        |> assign(:loading, true)
        |> assign(:loading_message, :ai_optimization)

      # Now manually set all button states to disabled
      disable_all_button_states()

      # Extract the content to be optimized
      textarea_content = Map.get(tab, :content)

      live_view_pid = self()
      # Call the optimization function with the process PID
      Task.start(fn ->
        MainController.optimize_text(live_view_pid, textarea_content)
      end)

      {:noreply, socket}
    else
      FeedbackModule.send_status_message(
        self(),
        "Fehler: Tab nicht gefunden",
        "error"
      )

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("ai-correction", %{"id" => tab_id}, socket) do
    FeedbackModule.send_chat_message(
      self(),
      "Bitte verfasse den Text neu mit den fehldenen Entitäten.",
      "user"
    )

    FeedbackModule.send_status_message(
      self(),
      "Text-Neuverfassung und Verifizierung gestartet.",
      "info"
    )

    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab do
      disable_all_button_states()

      socket = assign(socket, :loading, true)
      socket = assign(socket, :loading_message, :ai_correction)

      formatted_content = Map.get(tab, :formatted_content, %{})
      IO.inspect(formatted_content, label: "Formatted Content")

      missing_entities = extract_entities_from_formatted_content(formatted_content)
      IO.inspect(missing_entities, label: "Missing Entities")

      # Clean text before sending to AI
      clean_formatted_content = clean_formatted_content_entities(formatted_content)

      final_formatted_content =
        TipTapEditor.transform_formatted_content_to_text(clean_formatted_content)

      clean_text = extract_plain_text_from_formatted(final_formatted_content)
      IO.inspect(clean_text, label: "Clean Text for AI Correction")

      textarea_content = clean_text

      tab =
        if not Map.has_key?(tab, :active_meta_info) do
          Map.put(tab, :active_meta_info, %{})
        else
          tab
        end

      meta_data = Map.get(tab, :active_meta_info, %{})
      chapter_num = Map.get(tab, :chapter_number, "")
      chapter_title = tab.label
      chapter_info = Map.get(tab, :chapter_info, "")
      previous_content_mode = String.to_atom(socket.assigns.previous_content_mode)

      verifier_config = %{
        verification_degree: socket.assigns.verification_degree,
        verification_count: socket.assigns.verification_count
      }

      previous_content =
        ContentPersistence.get_previous_contents(
          socket.assigns.report_id,
          chapter_num,
          previous_content_mode
        )

      input_info = %{
        chapter_num: chapter_num,
        title: chapter_title,
        meta_data: meta_data,
        chapter_info: chapter_info,
        previous_content: previous_content,
        missing_entities: missing_entities,
        previous_content_mode: previous_content_mode,
        verifier_config: verifier_config,
        textarea_content: textarea_content
      }

      socket = assign(socket, :loading, true)
      socket = assign(socket, :loading_message, :ai_correction)

      live_view_pid = self()

      Task.start(fn ->
        MainController.revise_text_with_changes(
          live_view_pid,
          input_info
        )
      end)

      {:noreply, socket}
    else
      FeedbackModule.send_status_message(
        self(),
        "Fehler: Tab nicht gefunden",
        "error"
      )

      {:noreply, socket}
    end
  end

  # Helper function to extract entities from formatted content
  defp extract_entities_from_formatted_content(formatted_content) do
    # Extract entities that are confirmed but not deleted
    extract_entities_from_node(formatted_content)
    |> Enum.filter(fn entity ->
      Map.get(entity, "confirmed", false) == true &&
        Map.get(entity, "deleted", true) == false
    end)
    |> Enum.map(fn entity ->
      %{
        text: Map.get(entity, "originalText", ""),
        category: Map.get(entity, "entityCategory", :unknown)
      }
    end)
  end

  # Recursively traverse the formatted content to find entities
  defp extract_entities_from_node(%{"content" => content}) when is_list(content) do
    Enum.flat_map(content, &extract_entities_from_node/1)
  end

  # Handle selectionList nodes with direct entityList
  defp extract_entities_from_node(%{
         "type" => "selectionList",
         "attrs" => %{"entityList" => entity_list}
       })
       when is_list(entity_list) do
    entity_list
  end

  # Keep the existing handler for marks-style entity lists
  defp extract_entities_from_node(%{"marks" => marks} = node) when is_list(marks) do
    # Extract entities from marks that contain entity lists
    entity_marks =
      Enum.filter(marks, fn mark ->
        mark["type"] == "coloredEntity" &&
          get_in(mark, ["attrs", "entityType"]) == "selection_list"
      end)

    entities =
      Enum.flat_map(entity_marks, fn mark ->
        get_in(mark, ["attrs", "entityList"]) || []
      end)

    # Also check if the node has content
    child_entities =
      if Map.has_key?(node, "content"), do: extract_entities_from_node(node), else: []

    entities ++ child_entities
  end

  defp extract_entities_from_node(_), do: []

  @impl true
  def handle_event("confirm-changes", %{"id" => tab_id}, socket) do
    Logger.info("Processing confirm-changes event for tab #{tab_id}")

    # Find the current tab
    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab do
      # Get the formatted content
      formatted_content = Map.get(tab, :formatted_content)

      if formatted_content do
        # First clean any deleted entities from the formatted content structure
        clean_formatted_content = clean_formatted_content_entities(formatted_content)

        # Then transform the clean formatted content to standard structure
        final_formatted_content =
          TipTapEditor.transform_formatted_content_to_text(clean_formatted_content)

        # Extract clean plain text (without deleted entities)
        clean_text = extract_plain_text_from_formatted(final_formatted_content)
        IO.inspect(clean_text, label: "Clean Text")

        updated_tab =
          tab
          |> Map.put(:content, clean_text)
          |> Map.put(:formatted_content, final_formatted_content)

        # Update the tabs list
        updated_tabs =
          Enum.map(socket.assigns.tabs, fn t ->
            if t.id == tab_id, do: updated_tab, else: t
          end)

        # Save the cleaned content to the database
        ContentPersistence.save_tab_content_to_db(socket, updated_tab)

        # Reload the tab from database to ensure we have fresh data
        reloaded_tab =
          ContentPersistence.load_content_from_db(
            socket,
            updated_tab,
            updated_tab.section_id,
            updated_tab.category
          )

        # Update tabs list with reloaded tab
        final_tabs =
          Enum.map(updated_tabs, fn t ->
            if t.id == tab_id, do: reloaded_tab, else: t
          end)

        # First update the socket with the new content
        socket = assign(socket, tabs: final_tabs)

        # THEN check correction mode using the updated socket so we get the latest content
        correction_mode = ContentPersistence.check_correction_mode(socket, tab_id)

        FeedbackModule.send_status_message(
          self(),
          "Änderungen wurden bestätigt und gespeichert.",
          "success"
        )

        # Apply appropriate button states immediately based on correction mode
        socket =
          if correction_mode,
            do: correction_mode_initiate(socket),
            else: correction_mode_reset(socket)

        # Force refresh the editor with new content
        socket =
          if tab_id == socket.assigns.active_tab && connected?(socket) do
            push_event(socket, "force_refresh_editor", %{
              tab_id: tab_id,
              content: reloaded_tab.content,
              formatted_content: Jason.encode!(reloaded_tab.formatted_content)
            })
          else
            socket
          end

        {:noreply, assign(socket, correction_mode: correction_mode)}
      else
        # Forward to the OutputArea component
        send_update(HaimedaCoreWeb.ReportsEditor.OutputArea,
          id: "output-area",
          action: :confirm_changes
        )

        {:noreply, socket}
      end
    else
      # Forward to the OutputArea component
      send_update(HaimedaCoreWeb.ReportsEditor.OutputArea,
        id: "output-area",
        action: :confirm_changes
      )

      {:noreply, socket}
    end
  end

  def handle_event("chapter-summarization", params, socket) do
    # Set loading state for UI feedback
    socket = assign(socket, :loading, true)
    socket = assign(socket, :loading_message, :summarization)

    # Get the current active tab ID if no specific tab ID was provided
    tab_id = Map.get(params, "id", socket.assigns.active_tab)

    FeedbackModule.send_status_message(
      self(),
      "Starte Zusammenfassung der Kapitel.",
      "info"
    )

    # Extract all chapters that can be summarized
    chapters_map = ContentPersistence.extract_chapters_for_summary_creation(socket)

    # Initialize updated_socket with loading state
    updated_socket = socket

    # Check if we have chapters to summarize
    if map_size(chapters_map) > 0 do
      # Launch async task to handle summarization
      live_view_pid = self()

      Task.start(fn ->
        # Summarize chapters
        summary_map = MainController.summarize_chapters(live_view_pid, chapters_map)

        # Save summaries back to database
        ContentPersistence.safe_summaries(socket, summary_map)

        # Trigger completion event
        send(live_view_pid, {:chapter_summarization_complete, tab_id})
      end)
    else
      # No chapters to summarize
      FeedbackModule.send_chat_message(
        self(),
        "Ich konnte keine Kapitel finden, die sich zusammenfassen lassen. Entweder existieren bereits Zusammenfassungen für alle Kapitel oder es gibt keine Kapiteltexte, die sich für eine Zusammenfassung eignen.",
        "system"
      )

      FeedbackModule.send_status_message(
        self(),
        "Zusammenfassung der Kapitel abgebrochen.",
        "error"
      )

      # Reset loading state and store in the shared updated_socket
      updated_socket = assign(updated_socket, :loading, false)
    end

    # Return the updated socket
    {:noreply, updated_socket}
  end

  # Keep only this handler and remove the other two
  def handle_info({:chapter_summarization_complete, tab_id}, socket) do
    # Reset loading state
    socket = assign(socket, :loading, false)

    FeedbackModule.send_status_message(
      self(),
      "Zusammenfassung der Kapitel beendet.",
      "success"
    )

    {:noreply, socket}
  end

  defp clean_formatted_content_entities(%{"content" => content} = formatted_content)
       when is_list(content) do
    cleaned_content = Enum.map(content, &clean_block_content/1)

    # Filter out any completely empty paragraph blocks resulting from deletions
    filtered_content =
      Enum.filter(cleaned_content, fn block ->
        # Keep non-paragraph blocks
        # For paragraphs, check if they have non-empty content
        # Check that it's not just a single empty text node
        block["type"] != "paragraph" ||
          (block["type"] == "paragraph" &&
             is_list(block["content"]) &&
             length(block["content"]) > 0 &&
             not (length(block["content"]) == 1 &&
                    block["content"] |> hd() |> Map.get("text", "") == ""))
      end)

    # Return formatted content with cleaned content
    Map.put(formatted_content, "content", filtered_content)
  end

  defp clean_formatted_content_entities(formatted_content), do: formatted_content

  # Clean a block of content by handling its type
  defp clean_block_content(%{"type" => "paragraph", "content" => content} = block)
       when is_list(content) do
    # Process each node in the paragraph content
    cleaned_content =
      content
      |> Enum.filter(fn node -> not has_deleted_entity?(node) end)
      |> Enum.map(&clean_node_content/1)
      # Remove any nil results from the list
      |> Enum.filter(&(&1 != nil))

    # Update the block with cleaned content
    Map.put(block, "content", cleaned_content)
  end

  # Preserve other types of blocks
  defp clean_block_content(block), do: block

  # Clean a node by handling its type
  defp clean_node_content(%{"type" => "text", "marks" => marks} = node) when is_list(marks) do
    # Check if this node has a deleted entity mark
    if has_deleted_entity?(node) do
      # Return nil to be filtered out later
      nil
    else
      # Keep the node but clean any nested content
      node
    end
  end

  # Process other types of nodes
  defp clean_node_content(node), do: node

  # Check if a node has a deleted entity mark
  defp has_deleted_entity?(%{"marks" => marks}) when is_list(marks) do
    Enum.any?(marks, fn mark ->
      mark["type"] == "coloredEntity" &&
        Map.get(mark["attrs"] || %{}, "deleted") == true
    end)
  end

  defp has_deleted_entity?(_), do: false

  # Helper function to extract plain text from formatted content
  defp extract_plain_text_from_formatted(%{"content" => content}) when is_list(content) do
    # Filter out selection lists entirely
    filtered_content =
      Enum.filter(content, fn node ->
        not (node["type"] == "selectionList" or
               (node["type"] == "list" && has_selection_list_mark?(node)))
      end)

    # Process the filtered content
    result =
      filtered_content
      |> Enum.map(fn node ->
        case node do
          %{"type" => "paragraph", "content" => para_content} when is_list(para_content) ->
            para_content
            |> Enum.map(&extract_text_from_node/1)
            |> Enum.join("")

          %{"type" => "hardBreak"} ->
            "\n"

          _ ->
            ""
        end
      end)
      |> Enum.join("\n")

    # Trim trailing newlines from the final result
    String.trim_trailing(result)
  end

  defp extract_plain_text_from_formatted(_), do: ""

  # Helper to check if a node has a selection_list mark
  defp has_selection_list_mark?(%{"marks" => marks}) when is_list(marks) do
    Enum.any?(marks, fn mark ->
      mark["type"] == "coloredEntity" &&
        get_in(mark, ["attrs", "entityType"]) == "selection_list"
    end)
  end

  defp has_selection_list_mark?(_), do: false

  # Extract text from a node
  defp extract_text_from_node(%{"type" => "text", "text" => text, "marks" => marks})
       when is_list(marks) do
    # Check if the node has a coloredEntity mark with deleted=true
    has_deleted_entity =
      Enum.any?(marks, fn mark ->
        mark["type"] == "coloredEntity" &&
          Map.get(mark["attrs"] || %{}, "deleted") == true
      end)

    # If the entity is marked as deleted, return empty string instead of the text
    if has_deleted_entity, do: "", else: text
  end

  defp extract_text_from_node(%{"type" => "text", "text" => text}), do: text
  defp extract_text_from_node(%{"type" => "hardBreak"}), do: "\n"
  defp extract_text_from_node(_), do: ""

  @impl true
  def handle_event("discard-changes", %{"id" => tab_id}, socket) do
    # Forward to the OutputArea component
    send_update(HaimedaCoreWeb.ReportsEditor.OutputArea,
      id: "output-area",
      action: :discard_changes
    )

    {:noreply, socket}
  end

  @impl true
  def handle_event("previous-version", %{"id" => tab_id}, socket) do
    # Forward to the OutputArea component
    send_update(HaimedaCoreWeb.ReportsEditor.OutputArea,
      id: "output-area",
      action: :previous_version
    )

    {:noreply, socket}
  end

  @impl true
  def handle_event("next-version", %{"id" => tab_id}, socket) do
    # Forward to the OutputArea component
    send_update(HaimedaCoreWeb.ReportsEditor.OutputArea, id: "output-area", action: :next_version)
    {:noreply, socket}
  end

  @impl true
  def handle_event("navigate_version", %{"id" => tab_id, "direction" => direction}, socket) do
    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab do
      current_version = Map.get(tab, :current_version, 1)

      version_count =
        ContentPersistence.get_chapter_version_count(socket.assigns.report_id, tab.section_id)

      new_version =
        case direction do
          "prev" when current_version > 1 -> current_version - 1
          "next" when current_version < version_count -> current_version + 1
          _ -> current_version
        end

      if new_version != current_version do
        # Set the current version in the database
        {:ok, _} =
          ContentPersistence.set_current_chapter_version(
            socket.assigns.report_id,
            tab.section_id,
            new_version
          )

        # Get the version data
        version_data =
          ContentPersistence.get_chapter_version(
            socket.assigns.report_id,
            tab.section_id,
            new_version
          )

        # Update the tab with the version content
        updated_tab =
          if version_data do
            tab
            |> Map.put(:content, Map.get(version_data, "plain_content", ""))
            |> Map.put(:formatted_content, Map.get(version_data, "formatted_content"))
            |> Map.put(:current_version, new_version)
          else
            tab
          end

        # Update the tabs list
        updated_tabs =
          Enum.map(socket.assigns.tabs, fn t ->
            if t.id == tab_id, do: updated_tab, else: t
          end)

        # Create updated socket with new tabs
        updated_socket = assign(socket, tabs: updated_tabs)

        # Check correction mode for the new version
        correction_mode = ContentPersistence.check_correction_mode(updated_socket, tab_id)

        Logger.info(
          "[VERSION NAVIGATION] New correction mode: #{correction_mode} for version #{new_version}"
        )

        # Update correction mode in socket
        updated_socket = assign(updated_socket, :correction_mode, correction_mode)

        # Apply appropriate button states based on correction mode
        updated_socket =
          if correction_mode,
            do: correction_mode_initiate(updated_socket),
            else: correction_mode_reset(updated_socket)

        # Add a direct event to force editor refresh if this is the active tab
        updated_socket =
          if tab_id == socket.assigns.active_tab && connected?(updated_socket) do
            if @show_JS_debug do
              Logger.info(
                "[VERSION SWITCH] Forcing editor refresh for tab #{tab_id}, direction: #{direction}, new version: #{new_version}"
              )
            end

            # Push event to force refresh the editor with new content
            push_event(updated_socket, "force_refresh_editor", %{
              tab_id: tab_id,
              content: updated_tab.content,
              formatted_content: Jason.encode!(updated_tab.formatted_content)
            })
          else
            updated_socket
          end

        {:noreply, updated_socket}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("delete_version", %{"id" => tab_id}, socket) do
    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab do
      current_version = Map.get(tab, :current_version, 1)

      version_count =
        ContentPersistence.get_chapter_version_count(socket.assigns.report_id, tab.section_id)

      if version_count > 1 do
        # Delete the version and get the updated versions and new current version
        {:ok, updated_versions, new_current_version} =
          ContentPersistence.delete_chapter_version(
            socket.assigns.report_id,
            tab.section_id,
            current_version
          )

        # Get the new current version data
        current_version_data =
          Enum.find(updated_versions, fn v ->
            Map.get(v, "version") == new_current_version
          end)

        # Update the tab with the new version data
        updated_tab =
          if current_version_data do
            tab
            |> Map.put(:content, Map.get(current_version_data, "plain_content", ""))
            |> Map.put(:formatted_content, Map.get(current_version_data, "formatted_content"))
            |> Map.put(:current_version, new_current_version)
            |> Map.put(:chapter_versions, updated_versions)
          else
            tab
          end

        # Update the tabs list
        updated_tabs =
          Enum.map(socket.assigns.tabs, fn t ->
            if t.id == tab_id, do: updated_tab, else: t
          end)

        {:noreply, assign(socket, tabs: updated_tabs)}
      else
        # We don't want to delete the last version
        {:noreply, put_flash(socket, :error, "Die letzte Version kann nicht gelöscht werden.")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event(
        "show-version-delete-confirmation",
        %{"id" => tab_id, "version" => version},
        socket
      ) do
    Logger.info("Showing version delete confirmation for tab #{tab_id}, version #{version}")

    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab do
      version_number = String.to_integer(version)

      version_count =
        ContentPersistence.get_chapter_version_count(socket.assigns.report_id, tab.section_id)

      if version_count > 1 do
        delete_modal = %{
          id: tab_id,
          category: "version",
          item_label: "Version #{version} von #{tab.label}",
          version: version_number
        }

        {:noreply, assign(socket, :delete_modal, delete_modal)}
      else
        {:noreply, put_flash(socket, :error, "Die letzte Version kann nicht gelöscht werden.")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event(
        "confirm-delete",
        %{"id" => item_id, "category" => "version"} = params,
        socket
      ) do
    # Try to get the version from params first, then fall back to delete_modal
    version_number =
      case params do
        %{"version" => version} when is_binary(version) and version != "" ->
          String.to_integer(version)

        _ ->
          case socket.assigns.delete_modal do
            %{version: version} when is_integer(version) ->
              version

            _ ->
              nil
          end
      end

    if version_number do
      Logger.info("Processing deletion for version: #{version_number} in tab: #{item_id}")

      tab = Enum.find(socket.assigns.tabs, &(&1.id == item_id))

      if tab do
        # Check if we're deleting the current version
        is_current_version = Map.get(tab, :current_version) == version_number

        # Delete the version
        {:ok, updated_versions, new_current_version} =
          ContentPersistence.delete_chapter_version(
            socket.assigns.report_id,
            tab.section_id,
            version_number
          )

        # Reload the tab to get the updated versions
        updated_tab = reload_tab_after_version_change(socket, item_id)

        # Update the tabs list
        updated_tabs =
          Enum.map(socket.assigns.tabs, fn t ->
            if t.id == item_id, do: updated_tab, else: t
          end)

        socket = socket |> assign(:tabs, updated_tabs) |> assign(:delete_modal, nil)

        # Force refresh the editor with new content
        socket =
          if item_id == socket.assigns.active_tab && connected?(socket) do
            push_event(socket, "force_refresh_editor", %{
              tab_id: item_id,
              content: updated_tab.content,
              formatted_content: Jason.encode!(updated_tab.formatted_content)
            })
          else
            socket
          end

        # If we were deleting the current version, trigger previous-version to switch
        if is_current_version do
          send_update(HaimedaCoreWeb.ReportsEditor.OutputArea,
            id: "output-area",
            action: :previous_version
          )
        end

        {:noreply, socket}
      else
        {:noreply,
         socket |> assign(:delete_modal, nil) |> put_flash(:error, "Tab nicht gefunden")}
      end
    else
      {:noreply,
       socket
       |> assign(:delete_modal, nil)
       |> put_flash(:error, "Version konnte nicht gelöscht werden: Versionsnummer fehlt")}
    end
  end

  @impl true
  def handle_event("confirm-delete", %{"id" => item_id, "category" => category} = params, socket)
      when category != "version" do
    Logger.info("Confirming deletion for item: #{item_id} in category: #{category}")

    updated_sections =
      TiptapActions.remove_item_from_section(socket.assigns.nav_sections, category, item_id)

    updated_tabs =
      Enum.reject(socket.assigns.tabs, fn tab ->
        tab.section_id == item_id && tab.category == category
      end)

    updated_tabs =
      if not Enum.any?(updated_tabs, &(&1.id == "new_tab")) do
        updated_tabs ++
          [%{id: "new_tab", label: "+", content: "", category: nil, section_id: nil}]
      else
        updated_tabs
      end

    new_active_tab =
      if Enum.any?(socket.assigns.tabs, fn tab ->
           tab.id == socket.assigns.active_tab && tab.section_id == item_id &&
             tab.category == category
         end) do
        "new_tab"
      else
        socket.assigns.active_tab
      end

    Report.delete_report_section(socket.assigns.report_id, category, item_id)

    {:noreply,
     socket
     |> assign(:nav_sections, updated_sections)
     |> assign(:tabs, updated_tabs)
     |> assign(:active_tab, new_active_tab)
     |> assign(:delete_modal, nil)}
  end

  @impl true
  def handle_event(
        "show-delete-confirmation",
        %{"item_id" => item_id, "category" => category},
        socket
      ) do
    Logger.info("Showing delete confirmation for #{category} item: #{item_id}")

    # Find the item in the navigation sections to get its label
    section = Enum.find(socket.assigns.nav_sections, &(&1.id == category))

    item_label =
      if section do
        item = Enum.find(section.items, &(&1.id == item_id))

        if item do
          Map.get(item, :label, "Unbekannter Eintrag")
        else
          "Unbekannter Eintrag"
        end
      else
        "Unbekannter Eintrag"
      end

    # Set up the delete modal data
    delete_modal = %{
      id: item_id,
      category: category,
      item_label: item_label
    }

    {:noreply, assign(socket, :delete_modal, delete_modal)}
  end

  defp reload_tab_after_version_change(socket, tab_id) do
    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab do
      ContentPersistence.load_content_from_db(
        socket,
        tab,
        tab.section_id,
        tab.category
      )
    else
      tab
    end
  end

  @impl true
  def handle_event("cancel-delete", _params, socket) do
    {:noreply, assign(socket, :delete_modal, nil)}
  end

  @impl true
  def handle_event("start-auto-chapter-creation", %{"id" => tab_id}, socket) do
    FeedbackModule.send_status_message(
      self(),
      "Automatische Kapitelerstellung gestartet",
      "info"
    )

    FeedbackModule.send_chat_message(
      self(),
      "Bitte erstelle einen Inhalt für dieses Kapitel.",
      "user"
    )

    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    socket = assign(socket, :loading, true)
    socket = assign(socket, :loading_message, :chapter_creation)

    Process.send_after(self(), {:chapter_creation, tab_id, tab}, 1000)

    {:noreply, socket}
  end

  @impl true
  def handle_event("start-manual-verification", %{"id" => tab_id}, socket) do
    FeedbackModule.send_chat_message(
      self(),
      "Bitte verifiziere den Inhalt dieses Kapitels.",
      "user"
    )

    FeedbackModule.send_status_message(
      self(),
      "KI-Anfrage gesendet: Manuelle Verifikation gestartet",
      "info"
    )

    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab do
      textarea_content = Map.get(tab, :content, "")
      # Remove any trailing newlines from the textarea content
      textarea_content = String.trim_trailing(textarea_content)
      IO.inspect(textarea_content, label: "Textarea Content")

      tab =
        if not Map.has_key?(tab, :active_meta_info) do
          Map.put(tab, :active_meta_info, %{})
        else
          tab
        end

      meta_data = Map.get(tab, :active_meta_info, %{})
      chapter_num = Map.get(tab, :chapter_number, "")
      chapter_title = tab.label
      chapter_info = Map.get(tab, :chapter_info, "")
      previous_content_mode = String.to_atom(socket.assigns.previous_content_mode)

      verifier_config = %{
        verification_degree: socket.assigns.verification_degree,
        verification_count: socket.assigns.verification_count
      }

      previous_content =
        ContentPersistence.get_previous_contents(
          socket.assigns.report_id,
          chapter_num,
          previous_content_mode
        )

      IO.inspect(previous_content, label: "Previous Content")

      input_info = %{
        chapter_num: chapter_num,
        title: chapter_title,
        meta_data: meta_data,
        chapter_info: chapter_info,
        previous_content: previous_content,
        previous_content_mode: previous_content_mode
      }

      socket = assign(socket, :loading, true)
      socket = assign(socket, :loading_message, :verification)

      live_view_pid = self()

      Task.start(fn ->
        MainController.start_postprocessor(
          live_view_pid,
          input_info,
          textarea_content,
          :manual,
          verifier_config
        )
      end)

      {:noreply, socket}
    else
      FeedbackModule.send_status_message(
        self(),
        "Fehler: Tab nicht gefunden",
        "error"
      )

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("update-verification-count", %{"value" => value}, socket) do
    count =
      case Integer.parse(value) do
        {num, _} when num < 1 -> 1
        {num, _} when num > 20 -> 20
        {num, _} -> num
        :error -> 1
      end

    HaimedaCore.EditorSession.update_verification_count(socket.assigns.report_id, count)

    if value != to_string(count) do
      Process.send_after(self(), {:reset_verification_count_ui, count}, 50)
    end

    {:noreply, assign(socket, :verification_count, count)}
  end

  @impl true
  def handle_info({:reset_verification_count_ui, count}, socket) do
    {:noreply, assign(socket, :verification_count, count)}
  end

  @impl true
  def handle_event("toggle-content-mode", _params, socket) do
    current_mode = socket.assigns.previous_content_mode
    current_mode = current_mode || "full_chapters"
    new_mode = if current_mode == "summaries", do: "full_chapters", else: "summaries"

    {:ok, _} =
      HaimedaCore.EditorSession.update_previous_content_mode(socket.assigns.report_id, new_mode)

    mode_description =
      if new_mode == "summaries", do: "Kapitelzusammenfassungen", else: "vollständige Kapitel"

    send(
      self(),
      {:add_log,
       %{
         message: "Kontextmodus geändert: Verwende nun #{mode_description}",
         type: "info",
         timestamp: DateTime.utc_now()
       }}
    )

    {:noreply, assign(socket, :previous_content_mode, new_mode)}
  end

  @impl true
  def handle_info({:chapter_creation, tab_id, tab}, socket) do
    if tab do
      tab =
        if not Map.has_key?(tab, :active_meta_info) do
          Map.put(tab, :active_meta_info, %{})
        else
          tab
        end

      meta_data = Map.get(tab, :active_meta_info, %{})
      chapter_num = Map.get(tab, :chapter_number, "")
      chapter_title = tab.label
      chapter_info = Map.get(tab, :chapter_info, "")
      previous_content_mode = String.to_atom(socket.assigns.previous_content_mode)

      previous_content =
        ContentPersistence.get_previous_contents(
          socket.assigns.report_id,
          chapter_num,
          previous_content_mode
        )

      input_info = %{
        chapter_num: chapter_num,
        title: chapter_title,
        meta_data: meta_data,
        chapter_info: chapter_info,
        previous_content: previous_content,
        previous_content_mode: previous_content_mode
      }

      live_view_pid = self()

      # Create model_params with atom-keyed llm_params instead of string-keyed
      model_params = %{
        selected_llm: socket.assigns.selected_llm,
        llm_params: %{
          temperature: socket.assigns.llm_params["temperature"],
          top_p: socket.assigns.llm_params["top_p"],
          top_k: socket.assigns.llm_params["top_k"],
          max_tokens: socket.assigns.llm_params["max_tokens"],
          repeat_penalty: socket.assigns.llm_params["repeat_penalty"]
        }
      }

      verifier_config = %{
        verification_degree: socket.assigns.verification_degree,
        verification_count: socket.assigns.verification_count
      }

      result =
        MainController.initiate_chapter_creation_with_AI(
          live_view_pid,
          input_info,
          verifier_config,
          model_params
        )

      case result do
        :ok ->
          # Loading will be reset by output_area after content is updated
          # We don't need to reset it here, as OutputArea will send {:loading, false}
          {:noreply, socket}

        {:error, reason} ->
          # If error occurs, explicitly set loading to false
          # FeedbackModule.send_status_message(
          #   self(),
          #   "Fehler bei der Kapitelerstellung: #{reason}",
          #   "error"
          # )

          socket = reset_loading(socket)
          {:noreply, socket}
      end
    else
      FeedbackModule.send_status_message(self(), "Fehler: Tab nicht gefunden", "error")
      socket = reset_loading(socket)
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:verification_complete, tab_id}, socket) do
    FeedbackModule.send_status_message(
      self(),
      "Manuelle Verifikation abgeschlossen",
      "success"
    )

    FeedbackModule.send_chat_message(
      self(),
      "Ich habe den Inhalt dieses Kapitels verifiziert. In der Zukunft wird hier die symbolische KI eine detaillierte Analyse durchführen.",
      "symbolic_ai"
    )

    socket = reset_loading(socket)

    {:noreply, socket}
  end

  @impl true
  def handle_event("update-llm-param", params, socket) do
    param = params["param"]
    value = params["value"]

    case HaimedaCore.EditorSession.update_llm_param(socket.assigns.report_id, param, value) do
      {:ok, updated_value} ->
        # Update the specific parameter in the socket's llm_params
        updated_params = Map.put(socket.assigns.llm_params, param, updated_value)
        {:noreply, assign(socket, :llm_params, updated_params)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  @impl true
  def handle_event("update-verification-degree", %{"value" => value}, socket) do
    options = [
      "Keine Übereinstimmung",
      "Schwache Übereinstimmung",
      "Mittlere Übereinstimmung",
      "Starke Übereinstimmung",
      "Exakte Übereinstimmung"
    ]

    index =
      case Integer.parse(value) do
        {num, _} when num >= 0 and num < length(options) -> num
        _ -> 2
      end

    selected_degree = Enum.at(options, index)

    Logger.debug("Selected verification degree display value: #{selected_degree}")

    case HaimedaCore.EditorSession.update_verification_degree(
           socket.assigns.report_id,
           selected_degree
         ) do
      {:ok, _} ->
        verification_degree_atom =
          HaimedaCore.EditorSession.get_verification_degree(socket.assigns.report_id)

        updated_socket = assign(socket, :verification_degree, verification_degree_atom)
        save_editor_session(updated_socket)

        Logger.debug(
          "Updated socket verification degree: #{inspect(updated_socket.assigns.verification_degree)}"
        )

        {:noreply, updated_socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  @impl true
  def handle_event("update-selected-llm", %{"value" => llm_name}, socket) do
    case HaimedaCore.EditorSession.update_selected_llm(socket.assigns.report_id, llm_name) do
      {:ok, _} ->
        updated_socket = assign(socket, :selected_llm, llm_name)
        save_editor_session(updated_socket)
        {:noreply, updated_socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  # Modified handle_info for LLM integration task result
  @impl true
  def handle_info({ref, %{model_paths: model_paths}}, socket) when is_reference(ref) do
    # Process is complete, flush the DOWN message
    Process.demonitor(ref, [:flush])

    # Extract basenames without file extension
    basenames =
      Enum.map(model_paths, fn path ->
        path
        |> Path.basename()
        # Remove file extension
        |> Path.rootname()
      end)

    # Get current selected LLM
    current_selected = socket.assigns.selected_llm

    # Determine if basenames have changed
    current_llm_options = socket.assigns.llm_options
    basenames_changed = basenames != current_llm_options

    # Determine new selected LLM
    new_selected =
      cond do
        # If current selection is still valid, keep it
        Enum.member?(basenames, current_selected) ->
          current_selected

        # If we have any models, use the first one
        length(basenames) > 0 ->
          List.first(basenames)

        # Otherwise, use empty string
        true ->
          ""
      end

    # Update selected LLM in database if needed
    if basenames_changed && new_selected != current_selected do
      HaimedaCore.EditorSession.update_selected_llm(socket.assigns.report_id, new_selected)
    end

    # Update socket assigns
    updated_socket =
      socket
      |> assign(:llm_options, basenames)
      |> assign(:selected_llm, new_selected)
      |> reset_loading()

    # Save session with updated LLM options
    if basenames_changed do
      save_editor_session(updated_socket)
    end

    {:noreply, updated_socket}
  end

  # Handle any errors in the async task
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) do
    # Task failed
    Logger.error("Error integrating local LLMs: #{inspect(reason)}")

    # Update socket assigns
    socket = reset_loading(socket)

    {:noreply, socket}
  end

  # Add handler for synchronous report_id requests
  def handle_info({:get_report_id, requester_pid}, socket) when is_pid(requester_pid) do
    send(requester_pid, {:report_id, socket.assigns.report_id})
    {:noreply, socket}
  end

  # Add these event handlers to delegate to MetadataSection

  @impl true
  def handle_event("add-key-value-pair", params, socket) do
    case MetadataSection.handle_event("add-key-value-pair", params, socket) do
      {:tabs, tabs} ->
        updated_socket = assign(socket, tabs: tabs)
        save_editor_session(updated_socket)
        {:noreply, updated_socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  @impl true
  def handle_event("remove-key-value-pair", params, socket) do
    case MetadataSection.handle_event("remove-key-value-pair", params, socket) do
      {:tabs, tabs} ->
        updated_socket = assign(socket, tabs: tabs)
        save_editor_session(updated_socket)
        {:noreply, updated_socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  @impl true
  def handle_event("update-key-value-pair", params, socket) do
    case MetadataSection.handle_event("update-key-value-pair", params, socket) do
      {:tabs, tabs} ->
        updated_socket = assign(socket, tabs: tabs)
        save_editor_session(updated_socket)
        {:noreply, updated_socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  @impl true
  def handle_event("toggle-meta-info-button", params, socket) do
    case MetadataSection.handle_event("toggle-meta-info-button", params, socket) do
      {:tabs, tabs} ->
        updated_socket = assign(socket, tabs: tabs)
        save_editor_session(updated_socket)
        {:noreply, updated_socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  # Add these party-related event handlers to delegate to PartiesSection

  @impl true
  def handle_event("add-person-statement", params, socket) do
    case PartiesSection.handle_event("add-person-statement", params, socket) do
      {:tabs, tabs} ->
        updated_socket = assign(socket, tabs: tabs)
        save_editor_session(updated_socket)
        {:noreply, updated_socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  @impl true
  def handle_event("remove-person-statement", params, socket) do
    case PartiesSection.handle_event("remove-person-statement", params, socket) do
      {:tabs, tabs} ->
        updated_socket = assign(socket, tabs: tabs)
        save_editor_session(updated_socket)
        {:noreply, updated_socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  @impl true
  def handle_event("update-person-statement", params, socket) do
    case PartiesSection.handle_event("update-person-statement", params, socket) do
      {:tabs, tabs} ->
        updated_socket = assign(socket, tabs: tabs)
        save_editor_session(updated_socket)
        {:noreply, updated_socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  @impl true
  def handle_event("update-person-statement-id", params, socket) do
    case PartiesSection.handle_event("update-person-statement-id", params, socket) do
      {:tabs, tabs} ->
        updated_socket = assign(socket, tabs: tabs)
        save_editor_session(updated_socket)
        {:noreply, updated_socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  @impl true
  def handle_event("add-analysis-statement", params, socket) do
    case PartiesSection.handle_event("add-analysis-statement", params, socket) do
      {:tabs, tabs} ->
        updated_socket = assign(socket, tabs: tabs)
        save_editor_session(updated_socket)
        {:noreply, updated_socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  @impl true
  def handle_event("remove-analysis-statement", params, socket) do
    case PartiesSection.handle_event("remove-analysis-statement", params, socket) do
      {:tabs, tabs} ->
        updated_socket = assign(socket, tabs: tabs)
        save_editor_session(updated_socket)
        {:noreply, updated_socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  @impl true
  def handle_event("update-analysis-statement", params, socket) do
    case PartiesSection.handle_event("update-analysis-statement", params, socket) do
      {:tabs, tabs} ->
        updated_socket = assign(socket, tabs: tabs)
        save_editor_session(updated_socket)
        {:noreply, updated_socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  @impl true
  def handle_event("update-analysis-statement-related", params, socket) do
    case PartiesSection.handle_event("update-analysis-statement-related", params, socket) do
      {:tabs, tabs} ->
        updated_socket = assign(socket, tabs: tabs)
        save_editor_session(updated_socket)
        {:noreply, updated_socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  @impl true
  def handle_event("add-section-item", params, socket) do
    case TabManagement.handle_event("add-section-item", params, socket) do
      %{tabs: tabs, active_tab: active_tab, nav_sections: nav_sections} ->
        updated_socket =
          socket
          |> assign(:tabs, tabs)
          |> assign(:active_tab, active_tab)
          |> assign(:nav_sections, nav_sections)

        save_editor_session(updated_socket)
        {:noreply, updated_socket}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select-section-item", %{"id" => item_id, "category" => category}, socket) do
    case TabManagement.handle_select_section_item(socket, item_id, category) do
      %{tabs: tabs, active_tab: active_tab} ->
        updated_socket =
          socket
          |> assign(:tabs, tabs)
          |> assign(:active_tab, active_tab)

        save_editor_session(updated_socket)
        {:noreply, updated_socket}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select-tab", %{"id" => tab_id}, socket) do
    case TabManagement.handle_select_tab(socket, tab_id) do
      %{tabs: tabs, active_tab: active_tab} ->
        # Check correction mode using the new function
        correction_mode = ContentPersistence.check_correction_mode(socket, active_tab)
        Logger.info("Correction Mode for tab #{active_tab}: #{correction_mode}")

        updated_socket =
          socket
          |> assign(:tabs, tabs)
          |> assign(:active_tab, active_tab)
          |> assign(:correction_mode, correction_mode)

        # Apply appropriate button states based on correction mode
        updated_socket =
          if correction_mode,
            do: correction_mode_initiate(updated_socket),
            else: correction_mode_reset(updated_socket)

        save_editor_session(updated_socket)
        {:noreply, updated_socket}

      %{active_tab: active_tab} ->
        # Check correction mode using the new function
        correction_mode = ContentPersistence.check_correction_mode(socket, active_tab)
        Logger.info("Correction Mode for tab #{active_tab}: #{correction_mode}")

        updated_socket =
          socket
          |> assign(:active_tab, active_tab)
          |> assign(:correction_mode, correction_mode)

        # Apply appropriate button states based on correction mode
        updated_socket =
          if correction_mode,
            do: correction_mode_initiate(updated_socket),
            else: correction_mode_reset(updated_socket)

        save_editor_session(updated_socket)
        {:noreply, updated_socket}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("close-tab", %{"id" => tab_id}, socket) do
    case TabManagement.handle_close_tab(socket, tab_id) do
      %{tabs: tabs, active_tab: active_tab} ->
        updated_socket =
          socket
          |> assign(:tabs, tabs)
          |> assign(:active_tab, active_tab)

        save_editor_session(updated_socket)
        {:noreply, updated_socket}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("update-tab-title", %{"id" => tab_id, "value" => value}, socket) do
    case TabManagement.handle_update_tab_title(socket, tab_id, value) do
      %{tabs: tabs, nav_sections: nav_sections} ->
        updated_socket =
          socket
          |> assign(:tabs, tabs)
          |> assign(:nav_sections, nav_sections)

        # Update chapter numbers if needed
        updated_socket =
          if socket.assigns.active_tab == tab_id do
            updated_tab = Enum.find(tabs, &(&1.id == tab_id))

            if updated_tab && updated_tab.category == "chapters" do
              nav_sections = update_chapter_numbers_and_order(nav_sections, updated_tab)
              assign(updated_socket, :nav_sections, nav_sections)
            else
              updated_socket
            end
          else
            updated_socket
          end

        save_editor_session(updated_socket)
        {:noreply, updated_socket}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("update-chapter-number", %{"id" => tab_id, "value" => value}, socket) do
    case TabManagement.handle_update_chapter_number(socket, tab_id, value) do
      %{tabs: tabs, nav_sections: nav_sections} ->
        updated_socket =
          socket
          |> assign(:tabs, tabs)
          |> assign(:nav_sections, nav_sections)

        save_editor_session(updated_socket)
        {:noreply, updated_socket}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("save-chapter-info", %{"id" => tab_id, "value" => value}, socket) do
    # Update the in‐memory tab
    updated_tabs =
      Enum.map(socket.assigns.tabs, fn
        t when t.id == tab_id -> Map.put(t, :chapter_info, value)
        t -> t
      end)

    # Persist the change
    updated_tab = Enum.find(updated_tabs, &(&1.id == tab_id))
    ContentPersistence.save_tab_content_to_db(socket, updated_tab)

    # Reassign tabs
    {:noreply, assign(socket, :tabs, updated_tabs)}
  end

  defp ensure_integer(value) do
    PartiesSection.ensure_integer(value)
  end

  defp get_metadata_value(report_id, section, key) do
    MetadataSection.get_metadata_value(report_id, section, key)
  end

  defp update_chapter_numbers_and_order(sections, updated_tab) do
    case updated_tab do
      %{category: "chapters", section_id: section_id, chapter_number: chapter_number} ->
        Enum.map(sections, fn section ->
          if section.id == "chapters" do
            updated_items =
              Enum.map(section.items, fn item ->
                if item.id == section_id do
                  Map.put(item, :chapter_number, chapter_number)
                else
                  item
                end
              end)

            sorted_items = sort_items_by_chapter_number(updated_items)

            %{section | items: sorted_items}
          else
            section
          end
        end)

      _ ->
        sections
    end
  end

  defp sort_items_by_chapter_number(items) do
    Enum.sort_by(items, fn item ->
      chapter_num = Map.get(item, :chapter_number, "")

      chapter_num
      |> String.trim()
      |> String.split(".")
      |> Enum.filter(&(&1 != ""))
      |> Enum.map(fn segment ->
        case Integer.parse(segment) do
          {num, _} -> num
          :error -> 0
        end
      end)
      |> pad_with_zeros()
    end)
  end

  defp pad_with_zeros(nums) do
    nums ++ List.duplicate(0, 10 - length(nums))
  end

  @impl true
  def handle_event("add_version", %{"id" => tab_id}, socket) do
    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab do
      # Create a new empty version with a summary field
      # Use empty map for formatted content (function modified to create default empty formatting)
      ContentPersistence.save_chapter_version(
        socket.assigns.report_id,
        tab.section_id,
        # Don't pass the content (the function will create empty content)
        nil,
        # Don't pass formatting (the function will create default empty formatting)
        nil
      )

      # Reload the tab to get the updated versions and switch to the new version
      updated_tab =
        ContentPersistence.load_content_from_db(
          socket,
          tab,
          tab.section_id,
          tab.category
        )

      # Update the tabs list
      updated_tabs =
        Enum.map(socket.assigns.tabs, fn t ->
          if t.id == tab_id, do: updated_tab, else: t
        end)

      # Switch to the newly created version by using the next-version event
      socket = assign(socket, tabs: updated_tabs)

      # Force refresh the editor with new content
      socket =
        if tab_id == socket.assigns.active_tab && connected?(socket) do
          push_event(socket, "force_refresh_editor", %{
            tab_id: tab_id,
            content: updated_tab.content,
            formatted_content: Jason.encode!(updated_tab.formatted_content)
          })
        else
          socket
        end

      # Trigger next-version to switch to the newly created version
      send_update(HaimedaCoreWeb.ReportsEditor.OutputArea,
        id: "output-area",
        action: :next_version
      )

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("set_version", %{"id" => tab_id, "version" => version}, socket) do
    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))
    version = String.to_integer(version)

    if tab do
      # Set the specified version as current
      {:ok, _} =
        ContentPersistence.set_current_chapter_version(
          socket.assigns.report_id,
          tab.section_id,
          version
        )

      # Get the version data
      version_data =
        ContentPersistence.get_chapter_version(
          socket.assigns.report_id,
          tab.section_id,
          version
        )

      # Update the tab with the version content
      updated_tab =
        if version_data do
          tab
          |> Map.put(:content, Map.get(version_data, "plain_content", ""))
          |> Map.put(:formatted_content, Map.get(version_data, "formatted_content"))
          |> Map.put(:current_version, version)
        else
          tab
        end

      # Update the tabs list
      updated_tabs =
        Enum.map(socket.assigns.tabs, fn t ->
          if t.id == tab_id, do: updated_tab, else: t
        end)

      # Create updated socket with new tabs
      updated_socket = assign(socket, tabs: updated_tabs)

      # Check correction mode for the newly set version
      correction_mode = ContentPersistence.check_correction_mode(updated_socket, tab_id)
      Logger.info("[VERSION SET] New correction mode: #{correction_mode} for version #{version}")

      # Update correction mode in socket
      updated_socket = assign(updated_socket, :correction_mode, correction_mode)

      # Apply appropriate button states based on correction mode
      updated_socket =
        if correction_mode,
          do: correction_mode_initiate(updated_socket),
          else: correction_mode_reset(updated_socket)

      # Add a direct event to force editor refresh if this is the active tab
      updated_socket =
        if tab_id == socket.assigns.active_tab && connected?(updated_socket) do
          if @show_JS_debug do
            Logger.info(
              "[VERSION SWITCH] Forcing editor refresh for tab #{tab_id}, version #{version}"
            )
          end

          # Push event to force refresh the editor with new content
          push_event(updated_socket, "force_refresh_editor", %{
            tab_id: tab_id,
            content: updated_tab.content,
            formatted_content: Jason.encode!(updated_tab.formatted_content)
          })
        else
          updated_socket
        end

      {:noreply, updated_socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event(
        "js_debug",
        %{"message" => message, "level" => level, "timestamp" => timestamp} = payload,
        socket
      ) do
    # Only process debug messages if @show_JS_debug is true
    if @show_JS_debug do
      # Extract metadata
      metadata = Map.get(payload, "metadata", %{})
      url = Map.get(payload, "url", "unknown")

      # Make a clear prefix so these logs stand out in the console
      log_prefix = "[JS->ELIXIR #{String.upcase(level)}]"

      # Log message with appropriate level
      case level do
        "error" -> Logger.error("#{log_prefix} #{message} (#{url})", metadata)
        "warn" -> Logger.warning("#{log_prefix} #{message} (#{url})", metadata)
        "info" -> Logger.info("#{log_prefix} #{message} (#{url})", metadata)
        "debug" -> Logger.debug("#{log_prefix} #{message} (#{url})", metadata)
        _ -> Logger.info("#{log_prefix} #{message} (#{url})", metadata)
      end

      # Store logs in LiveView state (not displayed in UI, but available for inspection)
      js_debug_logs =
        socket.assigns.js_debug_logs ++
          [
            %{
              message: message,
              level: level,
              timestamp: timestamp,
              metadata: metadata
            }
          ]

      # Keep only the last 100 logs to prevent memory issues
      js_debug_logs =
        if length(js_debug_logs) > 100, do: Enum.take(js_debug_logs, -100), else: js_debug_logs

      {:noreply, assign(socket, :js_debug_logs, js_debug_logs)}
    else
      # If debug is disabled, just return the socket unchanged
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("clear-js-debug-logs", _params, socket) do
    {:noreply, assign(socket, :js_debug_logs, [])}
  end

  # Add a direct logging helper to use from LiveView contexts
  defp js_log(message, level \\ "info") do
    timestamp = DateTime.utc_now() |> DateTime.to_string()
    Logger.info("[ELIXIR->JS #{String.upcase(level)}] #{message} (#{timestamp})")
  end

  @impl true
  def handle_event("selection-entity-update", params, socket) do
    # Delegate to TiptapActions
    HaimedaCoreWeb.ReportsEditor.TiptapActions.handle_event(
      "selection-entity-update",
      params,
      socket
    )
  end

  @impl true
  def handle_event("entity-replace", params, socket) do
    TiptapActions.handle_event("entity-replace", params, socket)
  end

  @impl true
  def handle_event("entity-deletion", params, socket) do
    IO.puts("Handling entity deletion event")
    result = TiptapActions.handle_event("entity-deletion", params, socket)
    # IO.inspect(socket.assigns.tabs, label: ":tabs after entity deletion 2")
    result
  end

  @impl true
  def handle_event("entity-restore", params, socket) do
    TiptapActions.handle_event("entity-restore", params, socket)
  end

  @impl true
  def handle_event("entity-marked-for-deletion", params, socket) do
    TiptapActions.handle_event("entity-marked-for-deletion", params, socket)
  end

  @impl true
  def handle_event("content-updated", params, socket) do
    TiptapActions.handle_event("content-updated", params, socket)
  end

  @impl true
  def handle_event("force_refresh_editor", params, socket) do
    TiptapActions.handle_event("force_refresh_editor", params, socket)
  end

  @impl true
  def handle_info({:selection_entity_update, entity_id, deleted, confirmed}, socket) do
    # Pass the event to TiptapActions as a regular handle_event
    HaimedaCoreWeb.ReportsEditor.TiptapActions.handle_event(
      "selection-entity-update",
      %{"entity_id" => entity_id, "deleted" => deleted, "confirmed" => confirmed},
      socket
    )
  end

  # Add handlers for all tiptap messages to delegate to TiptapActions
  @impl true
  def handle_info(
        {:tiptap_entity_replaced, tab_id, entity_id, replacement, switched, original,
         display_text},
        socket
      ) do
    # Delegate to TiptapActions handle_info
    TiptapActions.handle_info(
      {:tiptap_entity_replaced, tab_id, entity_id, replacement, switched, original, display_text},
      socket
    )
  end

  @impl true
  def handle_info(
        {:tiptap_entity_replaced, tab_id, entity_id, replacement, switched, original,
         display_text, color},
        socket
      ) do
    # Delegate to TiptapActions handle_info
    TiptapActions.handle_info(
      {:tiptap_entity_replaced, tab_id, entity_id, replacement, switched, original, display_text,
       color},
      socket
    )
  end

  @impl true
  def handle_info({:tiptap_entity_marked_for_deletion, tab_id, entity_id}, socket) do
    TiptapActions.handle_info({:tiptap_entity_marked_for_deletion, tab_id, entity_id}, socket)
  end

  @impl true
  def handle_info({:tiptap_entity_restored, tab_id, entity_id}, socket) do
    TiptapActions.handle_info({:tiptap_entity_restored, tab_id, entity_id}, socket)
  end

  @impl true
  def handle_info({:tiptap_content_updated, tab_id, content, formatted_content}, socket) do
    TiptapActions.handle_info(
      {:tiptap_content_updated, tab_id, content, formatted_content},
      socket
    )
  end

  @impl true
  def handle_info({:tiptap_entity_removed, tab_id, entity_id}, socket) do
    TiptapActions.handle_info({:tiptap_entity_removed, tab_id, entity_id}, socket)
  end

  @impl true
  def handle_info({:content_save_complete, tab_id, content, formatted_content}, socket) do
    TiptapActions.handle_info(
      {:content_save_complete, tab_id, content, formatted_content},
      socket
    )
  end

  @impl true
  def handle_info({:new_version_created, tab_id, content, formatted_content}, socket) do
    # First update the tab data to make sure we have the latest content
    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    # Reload the tab from database to ensure we have the latest version data
    updated_tab =
      if tab do
        ContentPersistence.load_content_from_db(
          socket,
          tab,
          tab.section_id,
          tab.category
        )
      else
        tab
      end

    # Update tabs list with reloaded tab
    updated_tabs =
      Enum.map(socket.assigns.tabs, fn t ->
        if t.id == tab_id, do: updated_tab, else: t
      end)

    # Update socket with the new tabs
    socket = assign(socket, tabs: updated_tabs)

    # Set the content mode to read-only
    send(self(), {:set_textarea_mode, "read-only"})

    # Make sure we're showing version 1 (the newly created version)
    if updated_tab && updated_tab.current_version != 1 do
      # Set the current version to 1 in the database
      {:ok, _} =
        ContentPersistence.set_current_chapter_version(
          socket.assigns.report_id,
          updated_tab.section_id,
          1
        )

      # Update the tab with version 1 settings
      updated_tab = Map.put(updated_tab, :current_version, 1)

      # Update tabs list again with the version 1 settings
      updated_tabs =
        Enum.map(socket.assigns.tabs, fn t ->
          if t.id == tab_id, do: updated_tab, else: t
        end)

      socket = assign(socket, tabs: updated_tabs)
    end

    # Force refresh the editor UI with the new content
    socket =
      if tab_id == socket.assigns.active_tab && connected?(socket) do
        push_event(socket, "force_refresh_editor", %{
          tab_id: tab_id,
          content: updated_tab.content,
          formatted_content: Jason.encode!(updated_tab.formatted_content)
        })
      else
        socket
      end

    # Add a success message about the new version
    FeedbackModule.send_status_message(
      self(),
      "Neue Version erstellt und als aktuelle Version festgelegt.",
      "success"
    )

    # Set correction mode for new version
    correction_mode = ContentPersistence.check_correction_mode(socket, tab_id)
    socket = assign(socket, :correction_mode, correction_mode)

    # Apply appropriate button states
    socket =
      if correction_mode,
        do: correction_mode_initiate(socket),
        else: correction_mode_reset(socket)

    # Reset loading state
    socket = reset_loading(socket)

    # Explicitly ensure we're showing version 1 by triggering a version navigation
    Process.send_after(self(), {:navigate_to_version, 1}, 200)

    {:noreply, socket}
  end

  @impl true
  def handle_event("clear-messages", _params, socket) do
    # Clear both chat messages and logs
    updated_socket =
      socket
      |> assign(:chat_messages, [])
      |> assign(:logs, [])

    # Save the updated state to persist the changes
    save_editor_session(updated_socket)

    # Add a page refresh by redirecting to the same page
    # This will ensure the UI is completely reset
    report_id = socket.assigns.report_id
    {:noreply, push_navigate(updated_socket, to: ~p"/reports/#{report_id}/editor")}
  end

  defp reset_loading(socket) do
    socket
    |> assign(:loading, false)
    |> assign(:loading_message, :default)
  end

  @impl true
  def handle_event("handle-chat-keydown", %{"key" => "ArrowUp"}, socket) do
    # Send ourselves the same navigate-chat-history event but handle it directly
    send(self(), {:navigate_chat_history_direct, "up"})
    {:noreply, socket}
  end

  @impl true
  def handle_event("handle-chat-keydown", %{"key" => "ArrowDown"}, socket) do
    # Send ourselves the same navigate-chat-history event but handle it directly
    send(self(), {:navigate_chat_history_direct, "down"})
    {:noreply, socket}
  end

  @impl true
  def handle_event("handle-chat-keydown", _params, socket) do
    # Ignore other keys
    {:noreply, socket}
  end

  @impl true
  def handle_event("update-chat-input", %{"message" => value}, socket) do
    # Update the chat input value directly
    {:noreply, assign(socket, :chat_input, value)}
  end

  @impl true
  def handle_info({:navigate_chat_history_direct, direction}, socket) do
    history = socket.assigns.chat_history || []
    current_index = socket.assigns.chat_history_index || -1

    Logger.debug(
      "Direct chat history navigation: direction=#{direction}, history count=#{length(history)}, current_index=#{current_index}"
    )

    {new_index, new_input} =
      case direction do
        "up" when length(history) > 0 and current_index < length(history) - 1 ->
          # Move up in history (older messages)
          next_index = current_index + 1
          message = Enum.at(history, next_index, "")
          Logger.debug("Moving up to index #{next_index}, message: #{message}")
          {next_index, message}

        "down" when current_index > 0 ->
          # Move down in history (newer messages)
          prev_index = current_index - 1
          message = Enum.at(history, prev_index, "")
          Logger.debug("Moving down to index #{prev_index}, message: #{message}")
          {prev_index, message}

        "down" when current_index == 0 ->
          # At newest message, go to empty input
          Logger.debug("At newest message, clearing input")
          {-1, ""}

        _ ->
          # No change
          Logger.debug("No change in history navigation")
          {current_index, socket.assigns.chat_input}
      end

    # Update socket directly - no JavaScript events
    updated_socket = assign(socket, chat_input: new_input, chat_history_index: new_index)

    # Log to confirm the value is updated
    Logger.debug("Updated chat_input to: '#{updated_socket.assigns.chat_input}'")

    {:noreply, updated_socket}
  end
end
