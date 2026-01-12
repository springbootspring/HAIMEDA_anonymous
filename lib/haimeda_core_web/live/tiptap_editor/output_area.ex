defmodule HaimedaCoreWeb.ReportsEditor.OutputArea do
  use HaimedaCoreWeb, :live_component
  alias HaimedaCoreWeb.ReportsEditor.{ContentPersistence, TipTapEditor}
  require Logger

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       versions: [],
       current_version_index: 0,
       has_unsaved_changes: false,
       ai_correction_disabled: true,
       confirm_changes_disabled: true,
       discard_changes_disabled: true,
       auto_chapter_disabled: false,
       manual_verification_disabled: false,
       ai_optimize_disabled: false
     )}
  end

  @impl true
  def update(
        %{textarea_content: content, textarea_mode: ta_mode, output_mode: o_mode} = assigns,
        socket
      ) do
    # Extract the editor PID if provided and store it
    editor_pid = Map.get(assigns, :editor_pid)
    socket = if editor_pid, do: assign(socket, :editor_pid, editor_pid), else: socket

    # Extract report_id - either from assigns or parent socket if available
    report_id = get_report_id(assigns, socket)

    socket =
      assign(
        socket,
        Map.drop(assigns, [:textarea_content, :textarea_mode, :editor_pid, :output_mode])
      )

    tab_id = socket.assigns.active_tab
    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab do
      # Process the content based on its type
      {safe_content, formatted_content} =
        case content do
          # Handle nested version map with structure %{rank => {tiptap_content, run_number}}
          content when is_map(content) and map_size(content) > 0 and o_mode == :update_versions ->
            # For multiple versions, we'll handle this in the :update_versions case
            # Just return empty values here as placeholders
            {"", %{}}

          # Handle first rank content from nested map
          %{1 => {%{"content" => _} = tiptap_content, _run_number}} ->
            # Extract the TipTap content from the first rank
            formatted =
              HaimedaCoreWeb.ReportsEditor.TipTapEditor.format_tiptap_content(tiptap_content)

            plain_text = extract_plain_text_from_tiptap(formatted)
            {plain_text, formatted}

          # Handle TipTap formatted content map structure
          %{"content" => _} = tiptap_content ->
            # Use our new formatter for TipTap content
            formatted =
              HaimedaCoreWeb.ReportsEditor.TipTapEditor.format_tiptap_content(tiptap_content)

            plain_text = extract_plain_text_from_tiptap(formatted)
            {plain_text, formatted}

          # Plain text content
          text when is_binary(text) ->
            # For plain text, use the existing text formatter
            formatted = ContentPersistence.create_default_formatted_content(text)
            {text, formatted}

          # Error case
          {:error, message} when is_binary(message) ->
            {tab.content, Map.get(tab, :formatted_content)}

          # Fallback for unexpected input
          _ ->
            Logger.warning("Unexpected content type for textarea: #{inspect(content)}")
            {Map.get(tab, :content, ""), Map.get(tab, :formatted_content)}
        end

      # Handle content based on output mode
      case o_mode do
        :update_field ->
          # Direct update of the content field, useful for AI correction
          updated_tab =
            tab
            |> Map.put(:content, safe_content)
            |> Map.put(:formatted_content, formatted_content)
            |> Map.put(:read_only, ta_mode == "read-only")

          # Update tabs list
          updated_tabs =
            Enum.map(socket.assigns.tabs, fn t ->
              if t.id == tab_id, do: updated_tab, else: t
            end)

          # Save the changes to MongoDB
          ContentPersistence.save_tab_content_to_db(
            %{assigns: %{report_id: report_id}},
            updated_tab
          )

          # Get editor PID
          editor_pid = socket.assigns[:editor_pid] || socket.parent_pid

          if editor_pid do
            # Notify the editor that content save is complete (not using ai_correction_complete)
            send(editor_pid, {:content_save_complete, tab_id, safe_content, formatted_content})
          end

          # Return socket with updated tabs
          {:ok, assign(socket, tabs: updated_tabs)}

        :update_versions when is_map(content) ->
          # For multiple versions from verification, content is a map of {rank, {content, run_number}}
          section_id = tab.section_id

          # Get the chapter from the report
          case HaimedaCore.Report.get_report(report_id) do
            {:ok, report} ->
              chapters = Map.get(report, "chapters", [])
              chapter = Enum.find(chapters, fn ch -> Map.get(ch, "id") == section_id end)

              if chapter do
                current_versions = Map.get(chapter, "chapter_versions", [])

                Logger.info(
                  "Found #{length(current_versions)} existing versions for chapter #{section_id}"
                )

                # Get the version numbers we're updating from the content map
                content_run_numbers =
                  content
                  |> Enum.map(fn {_rank, {_content, run_number}} -> run_number end)
                  |> MapSet.new()

                # Preserve existing versions that are not in the update set
                preserved_versions =
                  current_versions
                  |> Enum.filter(fn version ->
                    version_num = Map.get(version, "version")
                    not MapSet.member?(content_run_numbers, version_num)
                  end)

                # Special handling for complex nested format: %{rank => {tiptap_content, run_number}}
                updated_versions =
                  if Enum.any?(content, fn {_rank, value} ->
                       is_tuple(value) and tuple_size(value) == 2 and
                         is_map(elem(value, 0)) and is_map_key(elem(value, 0), "content")
                     end) do
                    Enum.map(content, fn {rank, {version_content, run_number}} ->
                      # For TipTap content, extract the formatted document first
                      formatted_content =
                        HaimedaCoreWeb.ReportsEditor.TipTapEditor.format_tiptap_content(
                          version_content
                        )

                      plain_text = extract_plain_text_from_tiptap(formatted_content)

                      # Find existing version by run_number
                      matching_version =
                        Enum.find(current_versions, fn v ->
                          Map.get(v, "version") == run_number
                        end)

                      # Create or update version
                      base_version =
                        matching_version ||
                          %{
                            "type" => ContentPersistence.determine_chapter_type(tab.label),
                            "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
                            "summary" => ""
                          }

                      # Update content and assign rank as version number
                      Map.merge(base_version, %{
                        "version" => rank,
                        "plain_content" => plain_text,
                        "formatted_content" => formatted_content
                      })
                    end)
                  else
                    # Handle original simple content format (string content)
                    Enum.map(content, fn {rank, {version_content, run_number}} ->
                      # Find existing version by run_number
                      matching_version =
                        Enum.find(current_versions, fn v ->
                          Map.get(v, "version") == run_number
                        end)

                      # Create formatted content for this version
                      version_formatted =
                        ContentPersistence.create_default_formatted_content(version_content)

                      # Update version with new content and assign rank as new version number
                      base_version =
                        matching_version ||
                          %{
                            "type" => ContentPersistence.determine_chapter_type(tab.label),
                            "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
                            "summary" => ""
                          }

                      # Update content and assign rank as version number
                      Map.merge(base_version, %{
                        "version" => rank,
                        "plain_content" => version_content,
                        "formatted_content" => version_formatted
                      })
                    end)
                  end

                # Combine updated versions with preserved versions
                final_versions = updated_versions ++ preserved_versions

                # Sort versions by rank (version number)
                sorted_versions =
                  Enum.sort_by(final_versions, fn v -> Map.get(v, "version") end)

                # Update database with new versions and set current version to 1 (best rank)
                update_data = %{
                  "chapter_versions" => sorted_versions,
                  # Best version has rank 1
                  "current_version" => 1
                }

                HaimedaCore.Report.update_report_section(
                  report_id,
                  "chapters",
                  section_id,
                  update_data
                )

                # Get the best version (rank 1)
                best_version = Enum.find(sorted_versions, fn v -> Map.get(v, "version") == 1 end)
                best_content = Map.get(best_version, "plain_content", "")
                best_formatted = Map.get(best_version, "formatted_content", %{})

                # Update the tab with the best content version (rank 1)
                updated_tab =
                  Map.merge(tab, %{
                    content: best_content,
                    formatted_content: best_formatted,
                    current_version: 1,
                    chapter_versions: sorted_versions
                  })

                # Update tabs list
                updated_tabs =
                  Enum.map(socket.assigns.tabs, fn t ->
                    if t.id == tab_id, do: updated_tab, else: t
                  end)

                # Send status message about success
                if editor_pid do
                  message =
                    "#{length(sorted_versions)} Versionen aktualisiert. Zeige beste Version (Rang 1)."

                  send(
                    editor_pid,
                    {:add_log,
                     %{
                       message: message,
                       type: "success",
                       timestamp: DateTime.utc_now()
                     }}
                  )

                  # Turn off loading state
                  send(editor_pid, {:loading, false})
                end

                # Return updated socket with new tabs
                {:ok, assign(socket, tabs: updated_tabs)}
              else
                Logger.error("Chapter not found for section_id: #{section_id}")
                if editor_pid, do: send(editor_pid, {:loading, false})
                {:ok, socket}
              end

            {:error, reason} ->
              Logger.error("Failed to get report: #{inspect(reason)}")
              if editor_pid, do: send(editor_pid, {:loading, false})
              {:ok, socket}
          end

        :new_version ->
          # Get existing chapter data from the database
          section_id = tab.section_id

          # Get the chapter from the report
          case HaimedaCore.Report.get_report(report_id) do
            {:ok, report} ->
              chapters = Map.get(report, "chapters", [])
              chapter = Enum.find(chapters, fn ch -> Map.get(ch, "id") == section_id end)

              if chapter do
                # Get current chapter versions
                current_versions = Map.get(chapter, "chapter_versions", [])

                # Increment all existing version numbers
                updated_versions =
                  Enum.map(current_versions, fn version ->
                    version_num = Map.get(version, "version")
                    Map.put(version, "version", version_num + 1)
                  end)

                # Create the new version with number 1
                new_version = %{
                  "version" => 1,
                  "plain_content" => safe_content,
                  "formatted_content" => formatted_content,
                  "summary" => "",
                  "type" => ContentPersistence.determine_chapter_type(tab.label),
                  "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
                }

                final_versions = [new_version] ++ updated_versions

                # Update the database with new versions and set current version to 1
                update_data = %{
                  "chapter_versions" => final_versions,
                  "current_version" => 1
                }

                HaimedaCore.Report.update_report_section(
                  report_id,
                  "chapters",
                  section_id,
                  update_data
                )

                # Update the tab with the new content and version info
                updated_tab =
                  Map.merge(tab, %{
                    content: safe_content,
                    formatted_content: formatted_content,
                    current_version: 1,
                    chapter_versions: final_versions,
                    read_only: true
                  })

                # Update the tabs list
                updated_tabs =
                  Enum.map(socket.assigns.tabs, fn t ->
                    if t.id == tab_id, do: updated_tab, else: t
                  end)

                # Send notification that version creation is complete
                editor_pid = socket.assigns[:editor_pid] || socket.parent_pid

                if editor_pid do
                  send(
                    editor_pid,
                    {:new_version_created, tab_id, safe_content, formatted_content}
                  )

                  # Turn off loading state
                  send(editor_pid, {:loading, false})
                end

                # Return updated socket with new tabs
                {:ok, assign(socket, tabs: updated_tabs)}
              else
                Logger.error("Chapter not found for section_id: #{section_id}")

                if editor_pid = socket.assigns[:editor_pid],
                  do: send(editor_pid, {:loading, false})

                {:ok, socket}
              end

            {:error, reason} ->
              Logger.error("Failed to get report: #{inspect(reason)}")
              if editor_pid = socket.assigns[:editor_pid], do: send(editor_pid, {:loading, false})
              {:ok, socket}
          end

        :correction ->
          # Handle correction mode - existing code for correction mode
          updated_tabs =
            Enum.map(socket.assigns.tabs, fn t ->
              if t.id == tab_id do
                t
                |> Map.put(:content, safe_content)
                |> Map.put(:formatted_content, formatted_content)
                |> Map.put(:read_only, ta_mode == "read-only")
              else
                t
              end
            end)

          updated_tab = Enum.find(updated_tabs, &(&1.id == tab_id))

          editor_pid = socket.assigns[:editor_pid] || socket.parent_pid

          if updated_tab do
            ContentPersistence.save_tab_content_to_db(socket, updated_tab)

            # Send a message that content save is complete
            if editor_pid do
              send(editor_pid, {:content_save_complete, tab_id, safe_content, formatted_content})
            end
          end

          {:ok, assign(socket, tabs: updated_tabs)}

        # Default case - regular content update
        _ ->
          updated_tabs =
            Enum.map(socket.assigns.tabs, fn t ->
              if t.id == tab_id do
                t
                |> Map.put(:content, safe_content)
                |> Map.put(:formatted_content, formatted_content)
                |> Map.put(:read_only, ta_mode == "read-only")
              else
                t
              end
            end)

          updated_tab = Enum.find(updated_tabs, &(&1.id == tab_id))

          editor_pid = socket.assigns[:editor_pid] || socket.parent_pid

          if updated_tab do
            ContentPersistence.save_tab_content_to_db(socket, updated_tab)

            # Send a message that content save is complete
            if editor_pid do
              send(editor_pid, {:content_save_complete, tab_id, safe_content, formatted_content})
            end
          end

          {:ok, assign(socket, tabs: updated_tabs)}
      end
    else
      {:ok, assign(socket, loading: false)}
    end
  end

  # Helper function to safely get report_id from different sources
  defp get_report_id(assigns, socket) do
    cond do
      # Try to get report_id from direct assigns (preferred)
      Map.has_key?(assigns, :report_id) ->
        Map.get(assigns, :report_id)

      # Try to get from socket assigns
      Map.has_key?(socket.assigns, :report_id) ->
        socket.assigns.report_id

      # Try to get from parent_assigns if it exists
      Map.has_key?(socket, :parent_assigns) && Map.has_key?(socket.parent_assigns, :report_id) ->
        socket.parent_assigns.report_id

      # If all fails, try to get from the editor process
      editor_pid = Map.get(assigns, :editor_pid) || Map.get(socket.assigns, :editor_pid) ->
        # Request report_id from the editor process
        try do
          # Send synchronous request for report_id
          send(editor_pid, {:get_report_id, self()})

          receive do
            {:report_id, id} -> id
          after
            # Timeout after 100ms
            100 -> nil
          end
        rescue
          _ -> nil
        end

      # Fallback
      true ->
        Logger.error("Failed to get report_id from any source")
        nil
    end
  end

  # Helper function to extract plain text from TipTap document
  defp extract_plain_text_from_tiptap(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map(&extract_text_from_paragraph/1)
    |> Enum.join("\n")
  end

  defp extract_plain_text_from_tiptap(_), do: ""

  defp extract_text_from_paragraph(%{"type" => "paragraph", "content" => content})
       when is_list(content) do
    content
    |> Enum.map(&extract_text_from_inline/1)
  end

  defp extract_text_from_paragraph(_), do: ""

  defp extract_text_from_inline(%{"type" => "text", "text" => text}), do: text
  defp extract_text_from_inline(%{"type" => "hardBreak"}), do: "\n"
  defp extract_text_from_inline(_), do: ""

  @impl true
  def update(%{content: content, mode: mode} = assigns, socket)
      when is_binary(content) or is_binary(mode) do
    update(
      %{
        textarea_content: content,
        textarea_mode: mode,
        action: Map.get(assigns, :action),
        tabs: Map.get(assigns, :tabs),
        active_tab: Map.get(assigns, :active_tab)
      },
      socket
    )
  end

  @impl true
  def update(%{content: content, mode: mode} = assigns, socket) do
    socket = assign(socket, assigns)

    tab_id = socket.assigns.active_tab
    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab do
      safe_content =
        case content do
          {:ok, text} when is_binary(text) ->
            text

          {:error, message} when is_binary(message) ->
            tab.content

          content when is_binary(content) ->
            content

          _ ->
            Logger.warning("Unexpected content type for textarea: #{inspect(content)}")
            to_string(content)
        end

      updated_tabs =
        Enum.map(socket.assigns.tabs, fn t ->
          if t.id == tab_id do
            t
            |> Map.put(:content, safe_content)
            |> Map.put(:read_only, mode == "read-only")
          else
            t
          end
        end)

      updated_tab = Enum.find(updated_tabs, &(&1.id == tab_id))

      if updated_tab do
        ContentPersistence.save_tab_content_to_db(socket, updated_tab)
      end

      {:ok, assign(socket, tabs: updated_tabs, loading: false)}
    else
      {:ok, assign(socket, loading: false)}
    end
  end

  @impl true
  def update(%{mode: mode} = assigns, socket) do
    socket = assign(socket, assigns)

    tab_id = socket.assigns.active_tab
    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab do
      updated_tabs =
        Enum.map(socket.assigns.tabs, fn t ->
          if t.id == tab_id do
            Map.put(t, :read_only, mode == "read-only")
          else
            t
          end
        end)

      {:ok, assign(socket, tabs: updated_tabs)}
    else
      {:ok, socket}
    end
  end

  @impl true
  def update(%{versions: versions, current_version_index: index} = assigns, socket) do
    socket = assign(socket, assigns)

    {:ok,
     assign(socket,
       versions: versions,
       current_version_index: index,
       has_unsaved_changes: false
     )}
  end

  @impl true
  def update(%{add_version: content} = assigns, socket) do
    socket = assign(socket, Map.drop(assigns, [:add_version]))
    versions = socket.assigns.versions ++ [content]

    {:ok,
     assign(socket,
       versions: versions,
       current_version_index: length(versions) - 1,
       has_unsaved_changes: false
     )}
  end

  @impl true
  def update(%{action: action} = assigns, socket) do
    socket = assign(socket, Map.drop(assigns, [:action]))

    case action do
      :confirm_changes ->
        {:ok, updated_socket} = confirm_changes(socket)
        {:ok, updated_socket}

      :discard_changes ->
        {:ok, updated_socket} = discard_changes(socket)
        {:ok, updated_socket}

      :previous_version ->
        {:ok, updated_socket} = navigate_to_previous_version(socket)

        if updated_socket.assigns.current_version_index != socket.assigns.current_version_index do
          content =
            Enum.at(
              updated_socket.assigns.versions,
              updated_socket.assigns.current_version_index,
              ""
            )

          send(updated_socket.parent_pid, {:update_textarea_field, content, "writable"})
        end

        {:ok, updated_socket}

      :next_version ->
        {:ok, updated_socket} = navigate_to_next_version(socket)

        if updated_socket.assigns.current_version_index != socket.assigns.current_version_index do
          content =
            Enum.at(
              updated_socket.assigns.versions,
              updated_socket.assigns.current_version_index,
              ""
            )

          send(updated_socket.parentPid, {:update_textarea_field, content, "writable"})
        end

        {:ok, updated_socket}

      _ ->
        {:ok, socket}
    end
  end

  @impl true
  def update(%{ai_correction_disabled: state} = assigns, socket) do
    socket = assign(socket, :ai_correction_disabled, state)

    send(socket.parentPid, {:update_button_state, :ai_correction_disabled, state})

    {:ok, socket}
  end

  @impl true
  def update(%{confirm_changes_disabled: state} = assigns, socket) do
    socket = assign(socket, :confirm_changes_disabled, state)

    send(socket.parentPid, {:update_button_state, :confirm_changes_disabled, state})

    {:ok, socket}
  end

  @impl true
  def update(%{discard_changes_disabled: state} = assigns, socket) do
    socket = assign(socket, :discard_changes_disabled, state)

    send(socket.parentPid, {:update_button_state, :discard_changes_disabled, state})

    {:ok, socket}
  end

  @impl true
  def update(%{auto_chapter_disabled: state} = assigns, socket) do
    socket = assign(socket, :auto_chapter_disabled, state)

    send(socket.parentPid, {:update_button_state, :auto_chapter_disabled, state})

    {:ok, socket}
  end

  @impl true
  def update(%{manual_verification_disabled: state} = assigns, socket) do
    socket = assign(socket, :manual_verification_disabled, state)

    send(socket.parentPid, {:update_button_state, :manual_verification_disabled, state})

    {:ok, socket}
  end

  @impl true
  def update(%{ai_optimize_disabled: state} = assigns, socket) do
    socket = assign(socket, :ai_optimize_disabled, state)

    send(socket.parentPid, {:update_button_state, :ai_optimize_disabled, state})

    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_info({:update_textarea_field, content}, socket) do
    handle_info({:update_textarea_field, content, "writable"}, socket)
  end

  @impl true
  def handle_info({:set_textarea_mode, mode}, socket) do
    tab_id = socket.assigns.active_tab
    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab do
      updated_tabs =
        Enum.map(socket.assigns.tabs, fn t ->
          if t.id == tab_id do
            Map.put(t, :read_only, mode == "read-only")
          else
            t
          end
        end)

      {:noreply, assign(socket, tabs: updated_tabs)}
    else
      {:noreply, socket}
    end
  end

  def navigate_to_previous_version(socket) do
    current_index = socket.assigns.current_version_index

    if current_index > 0 do
      new_index = current_index - 1
      {:ok, assign(socket, current_version_index: new_index)}
    else
      {:ok, socket}
    end
  end

  def navigate_to_next_version(socket) do
    current_index = socket.assigns.current_version_index
    versions = socket.assigns.versions

    if current_index < length(versions) - 1 do
      new_index = current_index + 1
      {:ok, assign(socket, current_version_index: new_index)}
    else
      {:ok, socket}
    end
  end

  def confirm_changes(socket) do
    {:ok, assign(socket, has_unsaved_changes: false)}
  end

  def discard_changes(socket) do
    {:ok, assign(socket, has_unsaved_changes: false)}
  end

  def add_version(socket, content) do
    send_update(__MODULE__, id: socket.assigns.id, add_version: content)
    socket
  end

  def previous_version(socket) do
    send(socket.parentPid, {:navigate_version, :previous})
    socket
  end

  def next_version(socket) do
    send(socket.parentPid, {:navigate_version, :next})
    socket
  end

  def update_textarea(socket, content, mode \\ "writable") do
    send(socket.parentPid, {:update_textarea_field, content, mode})
    socket
  end

  def set_textarea_mode(socket, mode) do
    send(socket.parentPid, {:set_textarea_mode, mode})
    socket
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="output-area">
      <!-- This component is now just for state management, no visible UI -->
    </div>
    """
  end

  @impl true
  def handle_event("previous-version", _params, socket) do
    case navigate_to_previous_version(socket) do
      {:ok, updated_socket} ->
        tab_id = updated_socket.assigns.active_tab

        content =
          Enum.at(
            updated_socket.assigns.versions,
            updated_socket.assigns.current_version_index,
            ""
          )

        send(updated_socket.parentPid, {:update_textarea_field, content, "writable"})

        {:noreply, updated_socket}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("next-version", _params, socket) do
    case navigate_to_next_version(socket) do
      {:ok, updated_socket} ->
        tab_id = updated_socket.assigns.active_tab

        content =
          Enum.at(
            updated_socket.assigns.versions,
            updated_socket.assigns.current_version_index,
            ""
          )

        send(updated_socket.parentPid, {:update_textarea_field, content, "writable"})

        {:noreply, updated_socket}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("confirm-changes", _params, socket) do
    case confirm_changes(socket) do
      {:ok, updated_socket} ->
        {:noreply, updated_socket}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("discard-changes", _params, socket) do
    case discard_changes(socket) do
      {:ok, updated_socket} ->
        tab_id = updated_socket.assigns.active_tab

        content =
          Enum.at(
            updated_socket.assigns.versions,
            updated_socket.assigns.current_version_index,
            ""
          )

        send(updated_socket.parentPid, {:update_textarea_field, content, "writable"})

        {:noreply, updated_socket}

      _ ->
        {:noreply, socket}
    end
  end

  defp get_formatted_content_text(formatted_content) do
    try do
      case formatted_content do
        %{"content" => content} when is_list(content) and length(content) > 0 ->
          # Extract text from all paragraphs
          content
          |> Enum.map(fn paragraph ->
            case paragraph do
              %{"content" => para_content} when is_list(para_content) ->
                # Extract text from each content element in paragraph
                para_content
                |> Enum.map(fn
                  %{"type" => "text", "text" => text} -> text
                  _ -> ""
                end)
                |> Enum.join("")

              _ ->
                ""
            end
          end)
          |> Enum.join("\n")

        _ ->
          nil
      end
    rescue
      e ->
        Logger.error("Error accessing formatted content: #{inspect(e)}")
        nil
    end
  end
end
