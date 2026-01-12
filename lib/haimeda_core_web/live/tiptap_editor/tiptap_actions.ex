defmodule HaimedaCoreWeb.ReportsEditor.TiptapActions do
  alias HaimedaCore.Report
  alias HaimedaCoreWeb.ReportsEditor.ContentPersistence
  alias HaimedaCoreWeb.ReportsEditor.TipTapSnippets
  require Logger

  import Phoenix.LiveView

  # Make this function public for external use
  def remove_item_from_section(sections, category_id, item_id) do
    Enum.map(sections, fn section ->
      if section.id == category_id do
        %{section | items: Enum.reject(section.items, &(&1.id == item_id))}
      else
        section
      end
    end)
  end

  # Helper function to find all entities in selection lists
  defp find_selection_list_entities(formatted_content) do
    try do
      # Get the content blocks from the formatted content
      content_blocks = get_in(formatted_content, ["content"]) || []

      # Find all selection list nodes
      selection_lists =
        Enum.filter(content_blocks, fn block ->
          block["type"] == "selectionList"
        end)

      # Extract entities from all selection lists
      entities =
        Enum.flat_map(selection_lists, fn selection_list ->
          entity_list = get_in(selection_list, ["attrs", "entityList"]) || []
          entity_list
        end)

      # Also check for legacy format with list + marks
      legacy_entities =
        Enum.flat_map(content_blocks, fn block ->
          if is_map(block) && Map.has_key?(block, "type") && block["type"] == "list" &&
               is_list(block["marks"]) do
            # Find the selection_list mark
            selection_mark =
              Enum.find(block["marks"], fn mark ->
                mark["type"] == "coloredEntity" &&
                  get_in(mark, ["attrs", "entityType"]) == "selection_list"
              end)

            if selection_mark do
              get_in(selection_mark, ["attrs", "entityList"]) || []
            else
              []
            end
          else
            []
          end
        end)

      # Combine both types of entities
      entities ++ legacy_entities
    rescue
      e ->
        Logger.error("Error finding selection list entities: #{inspect(e)}")
        []
    end
  end

  # Helper function to update an entity in a selection list
  defp update_entity_in_selection_list(formatted_content, entity_id, deleted, confirmed) do
    try do
      content_blocks = get_in(formatted_content, ["content"]) || []

      updated_blocks =
        Enum.map(content_blocks, fn block ->
          if block["type"] == "selectionList" do
            entity_list = get_in(block, ["attrs", "entityList"]) || []

            updated_entities =
              Enum.map(entity_list, fn entity ->
                if Map.get(entity, "id") == entity_id do
                  # Update the entity's state
                  entity
                  |> Map.put("deleted", deleted)
                  |> Map.put("confirmed", confirmed)
                else
                  entity
                end
              end)

            # Update the entity list in the selection list
            put_in(block, ["attrs", "entityList"], updated_entities)
          else
            block
          end
        end)

      # Update the content blocks in the formatted content
      put_in(formatted_content, ["content"], updated_blocks)
    rescue
      e ->
        Logger.error("Error updating entity in selection list: #{inspect(e)}")
        formatted_content
    end
  end

  # Helper function to handle selection entity updates
  @impl true
  def handle_event(
        "selection-entity-update",
        %{"entity_id" => entity_id, "deleted" => deleted, "confirmed" => confirmed},
        socket
      ) do
    # Log the entity update with better entity ID identification
    Logger.info(
      "Selection entity update for specific entity: #{entity_id}, deleted: #{deleted}, confirmed: #{confirmed}"
    )

    # Get current tab
    tab_id = socket.assigns.active_tab
    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab do
      # Update the entity's state in the formatted content
      formatted_content = Map.get(tab, :formatted_content)

      updated_formatted_content =
        update_selection_entity_state(
          formatted_content,
          entity_id,
          deleted,
          confirmed
        )

      # Update the tab with the modified formatted content
      updated_tab = Map.put(tab, :formatted_content, updated_formatted_content)

      # Update the tabs list
      updated_tabs =
        Enum.map(socket.assigns.tabs, fn t ->
          if t.id == tab_id, do: updated_tab, else: t
        end)

      # Save to DB immediately (not in a Task)
      # This ensures data is saved before we refresh the UI
      ContentPersistence.save_tab_content_to_db(
        %{assigns: %{report_id: socket.assigns.report_id}},
        updated_tab
      )

      # Push event to force refresh the editor
      socket =
        if connected?(socket) do
          # Create a unique key to force refresh
          refresh_key = "#{DateTime.utc_now() |> DateTime.to_unix()}_#{:rand.uniform(1000)}"

          push_event(socket, "force_refresh_editor", %{
            tab_id: tab_id,
            content: updated_tab.content,
            formatted_content: Jason.encode!(updated_formatted_content),
            refresh_key: refresh_key
          })
        else
          socket
        end

      socket = assign(socket, :tabs, updated_tabs)

      # Update socket state
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Improved selection entity state update function
  defp update_selection_entity_state(formatted_content, entity_id, deleted, confirmed) do
    try do
      case formatted_content do
        %{"content" => content} when is_list(content) ->
          # Process each block in the content
          updated_content =
            Enum.map(content, fn
              # Find selectionList nodes (new format)
              %{"type" => "selectionList", "attrs" => %{"entityList" => entity_list}} = block ->
                # Find and update ONLY the specific entity with matching ID
                updated_list =
                  Enum.map(entity_list || [], fn entity ->
                    if entity["entityId"] == entity_id do
                      # Log the entity we're updating
                      Logger.debug(
                        "Updating entity #{entity_id} state: deleted=#{deleted}, confirmed=#{confirmed}"
                      )

                      # Update the entity state
                      Map.merge(entity, %{
                        "deleted" => deleted,
                        "confirmed" => confirmed
                      })
                    else
                      # Leave other entities unchanged
                      entity
                    end
                  end)

                # Return block with updated entityList
                put_in(block, ["attrs", "entityList"], updated_list)

              # Check for legacy format with list and marks
              %{"type" => "list", "marks" => marks} = block when is_list(marks) ->
                # Find the selection_list mark
                selection_mark =
                  Enum.find(marks, fn mark ->
                    mark["type"] == "coloredEntity" &&
                      get_in(mark, ["attrs", "entityType"]) == "selection_list"
                  end)

                if selection_mark do
                  entity_list = get_in(selection_mark, ["attrs", "entityList"])

                  # Find and update ONLY the specific entity with matching ID
                  updated_list =
                    Enum.map(entity_list || [], fn entity ->
                      if entity["entityId"] == entity_id do
                        # Log the entity we're updating in legacy format
                        Logger.debug(
                          "Updating legacy entity #{entity_id} state: deleted=#{deleted}, confirmed=#{confirmed}"
                        )

                        # Update the entity state
                        Map.merge(entity, %{
                          "deleted" => deleted,
                          "confirmed" => confirmed
                        })
                      else
                        # Leave other entities unchanged
                        entity
                      end
                    end)

                  # Create updated mark
                  updated_marks =
                    Enum.map(marks, fn mark ->
                      if mark["type"] == "coloredEntity" &&
                           get_in(mark, ["attrs", "entityType"]) == "selection_list" do
                        # Update the entityList
                        put_in(mark, ["attrs", "entityList"], updated_list)
                      else
                        mark
                      end
                    end)

                  # Return block with updated marks
                  %{block | "marks" => updated_marks}
                else
                  block
                end

              # Pass through other blocks unchanged
              other ->
                other
            end)

          # Return updated content
          Map.put(formatted_content, "content", updated_content)

        _ ->
          # If content is missing or not a list, return unchanged
          formatted_content
      end
    rescue
      e ->
        Logger.error("Error updating selection entity state: #{inspect(e)}")
        formatted_content
    end
  end

  # Consolidated handler for selection-entity-update (accepts different param shapes)
  @impl true
  def handle_event("selection-entity-update", params, socket) do
    entity_id =
      params
      |> (fn p ->
            Map.get(p, "entity_id") || Map.get(p, :entity_id) || Map.get(p, "entityId") ||
              Map.get(p, :entityId)
          end).()

    deleted =
      case Map.get(params, "deleted") || Map.get(params, :deleted) do
        v when is_boolean(v) -> v
        "true" -> true
        "false" -> false
        nil -> false
        _ -> false
      end

    confirmed =
      case Map.get(params, "confirmed") || Map.get(params, :confirmed) do
        v when is_boolean(v) -> v
        "true" -> true
        "false" -> false
        nil -> false
        _ -> false
      end

    if entity_id do
      Logger.info(
        "Selection entity update for #{entity_id}, deleted: #{deleted}, confirmed: #{confirmed}"
      )

      tab_id = socket.assigns.active_tab
      tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

      if tab do
        formatted_content = Map.get(tab, :formatted_content)

        updated_formatted_content =
          update_selection_entity_state(formatted_content, entity_id, deleted, confirmed)

        updated_tab = Map.put(tab, :formatted_content, updated_formatted_content)

        updated_tabs =
          Enum.map(socket.assigns.tabs, fn t -> if t.id == tab_id, do: updated_tab, else: t end)

        ContentPersistence.save_tab_content_to_db(
          %{assigns: %{report_id: socket.assigns.report_id}},
          updated_tab
        )

        socket =
          if connected?(socket) do
            refresh_key = "#{DateTime.utc_now() |> DateTime.to_unix()}_#{:rand.uniform(1000)}"

            push_event(socket, "force_refresh_editor", %{
              tab_id: tab_id,
              content: updated_tab.content,
              formatted_content: Jason.encode!(updated_formatted_content),
              refresh_key: refresh_key
            })
          else
            socket
          end

        socket = assign(socket, :tabs, updated_tabs)
        {:noreply, socket}
      else
        {:noreply, socket}
      end
    else
      Logger.error("Cannot process selection-entity-update without entity_id")
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event(
        "content-updated",
        %{
          "content" => content,
          "formatted_content" => formatted_content,
          "persist_entities" => true
        },
        socket
      ) do
    # Enhanced version of content-updated that prioritizes entity persistence
    formatted_content_parsed =
      case Jason.decode(formatted_content) do
        {:ok, decoded} ->
          decoded

        _ ->
          HaimedaCoreWeb.ReportsEditor.ContentPersistence.create_default_formatted_content(
            content
          )
      end

    # IO.inspect(formatted_content, label: "Formatted content before processing")

    # # preserve deleted flags from existing formatted_content
    # tab_id = socket.assigns.active_tab
    # tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))
    # existing_formatted = Map.get(tab, :formatted_content, %{})
    # deleted_ids = find_deleted_entity_ids(existing_formatted)

    # formatted_content_parsed =
    #   if deleted_ids != [] do
    #     Enum.reduce(deleted_ids, formatted_content_parsed, fn entity_id, acc ->
    #       mark_entity_as_deleted(acc, entity_id, true)
    #     end)
    #   else
    #     formatted_content_parsed
    #   end

    # IO.inspect(content, label: "Raw content")
    # IO.inspect(formatted_content_parsed, label: "Parsed formatted content")

    # Get current tab
    tab_id = socket.assigns.active_tab
    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab do
      # Update the tab content
      updated_tab =
        tab
        |> Map.put(:content, content)
        |> Map.put(:formatted_content, formatted_content_parsed)

      updated_tabs =
        Enum.map(socket.assigns.tabs, fn t ->
          if t.id == tab_id, do: updated_tab, else: t
        end)

      # Prioritize persistence for entity changes - use synchronous save
      result =
        ContentPersistence.save_tab_content_to_db(
          %{assigns: %{report_id: socket.assigns.report_id}},
          updated_tab
        )

      Logger.info("Entity persistence result: #{inspect(result)}")

      # Make sure we push the formatted content back to the editor to maintain consistency
      if tab.id == socket.assigns.active_tab && connected?(socket) do
        push_event(socket, "editor_content_update", %{
          editorId: "tiptap-editor-#{tab_id}",
          content: content,
          formattedContent: formatted_content
        })
      end

      # Send message back to LiveView when save is complete
      # send(self(), {:content_save_complete, tab_id, content, formatted_content_parsed})

      # Immediately update the UI without waiting for save to complete
      {:noreply, assign(socket, tabs: updated_tabs)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event(
        "content-updated",
        %{"content" => content, "formatted_content" => formatted_content},
        socket
      ) do
    # This is the original event handler - unchanged
    formatted_content_parsed =
      case Jason.decode(formatted_content) do
        {:ok, decoded} ->
          decoded

        _ ->
          HaimedaCoreWeb.ReportsEditor.ContentPersistence.create_default_formatted_content(
            content
          )
      end

    # Get current tab
    tab_id = socket.assigns.active_tab
    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab do
      # IMPORTANT: Preserve deleted entity states from existing formatted content
      existing_formatted_content = Map.get(tab, :formatted_content, %{})

      # Find all entities currently marked as deleted
      deleted_entity_ids = find_deleted_entity_ids(existing_formatted_content)

      # If we found any deleted entities, ensure they stay deleted in the new content
      updated_formatted_content =
        if length(deleted_entity_ids) > 0 do
          Logger.info("Preserving deletion state for #{length(deleted_entity_ids)} entities")

          # Apply each deleted entity to the new formatted content
          Enum.reduce(deleted_entity_ids, formatted_content_parsed, fn entity_id, acc ->
            mark_entity_as_deleted(acc, entity_id, true)
          end)
        else
          formatted_content_parsed
        end

      # Update the tab content with our processed content that preserves deletions
      updated_tab =
        tab
        |> Map.put(:content, content)
        |> Map.put(:formatted_content, updated_formatted_content)

      updated_tabs =
        Enum.map(socket.assigns.tabs, fn t ->
          if t.id == tab_id, do: updated_tab, else: t
        end)

      # Save content to DB
      result =
        ContentPersistence.save_tab_content_to_db(
          %{assigns: %{report_id: socket.assigns.report_id}},
          updated_tab
        )

      # Log result for debugging
      Logger.debug("Async content save result: #{inspect(result)}")

      # Make sure we push the formatted content back to the editor to maintain consistency
      if tab.id == socket.assigns.active_tab && connected?(socket) do
        push_event(socket, "editor_content_update", %{
          editorId: "tiptap-editor-#{tab_id}",
          content: content,
          formattedContent: Jason.encode!(updated_formatted_content)
        })
      end

      # Send message back to LiveView when save is complete
      send(self(), {:content_save_complete, tab_id, content, updated_formatted_content})

      # Immediately update the UI without waiting for save to complete
      {:noreply, assign(socket, tabs: updated_tabs)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(
        {:content_save_complete, tab_id, _content, formatted_content_from_save},
        socket
      ) do
    # Instead of using the tab from memory, reload it directly from MongoDB
    # to ensure we have the most up-to-date content
    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab && connected?(socket) do
      # Get the current version of the tab
      current_version = Map.get(tab, :current_version, 1)

      # Get the version data from the database
      version_data =
        ContentPersistence.get_chapter_version(
          socket.assigns.report_id,
          tab.section_id,
          current_version
        )

      # Update the tab with the version content - same approach as in navigate_version
      updated_tab =
        if version_data do
          tab
          |> Map.put(:content, Map.get(version_data, "plain_content", ""))
          |> Map.put(:formatted_content, Map.get(version_data, "formatted_content"))
          |> Map.put(:current_version, current_version)
        else
          # If the specific version isn't found, reload the entire tab
          Logger.info("Version data not found, reloading entire tab from DB")

          ContentPersistence.load_content_from_db(
            %{assigns: %{report_id: socket.assigns.report_id}},
            tab,
            tab.section_id,
            tab.category
          )
        end

      # Update the tabs list with the reloaded tab
      updated_tabs =
        Enum.map(socket.assigns.tabs, fn t ->
          if t.id == tab_id, do: updated_tab, else: t
        end)

      # Update the socket with the fresh data
      socket = assign(socket, :tabs, updated_tabs)

      # Now check correction mode using the updated socket with latest content
      correction_mode = ContentPersistence.check_correction_mode(socket, tab_id)

      # Apply appropriate button states based on correction mode
      socket =
        if correction_mode,
          do: HaimedaCoreWeb.ReportsEditor.Editor.correction_mode_initiate(socket),
          else: HaimedaCoreWeb.ReportsEditor.Editor.correction_mode_reset(socket)

      # Update correction_mode in socket assigns
      socket = assign(socket, :correction_mode, correction_mode)
      socket = assign(socket, :loading, false)

      Logger.info("Forcing editor refresh after MongoDB reload for tab #{tab_id}")

      # Push event to force refresh the editor with the reloaded content
      socket =
        push_event(socket, "force_refresh_editor", %{
          tab_id: tab_id,
          content: updated_tab.content,
          formatted_content: Jason.encode!(updated_tab.formatted_content)
        })

      {:noreply, socket}
    else
      # If tab not found or socket not connected, just return the socket unchanged
      Logger.debug(
        "Content save complete for tab #{tab_id} - no refresh needed (tab not found or not connected)"
      )

      {:noreply, socket}
    end
  end

  # Helper function to log any deleted entities for debugging
  defp log_deleted_entities(formatted_content) do
    case formatted_content do
      %{"content" => content} when is_list(content) ->
        # Recursively search for deleted entities in the content
        find_deleted_entities(content, "root")

      _ ->
        :ok
    end
  end

  defp find_deleted_entities(content_list, path) when is_list(content_list) do
    Enum.with_index(content_list, fn node, idx ->
      node_path = "#{path}.#{idx}"

      # Check if this node has content to recurse into
      if is_map(node) && Map.has_key?(node, "content") && is_list(node["content"]) do
        find_deleted_entities(node["content"], node_path)
      end

      # Check if this node has marks
      if is_map(node) && Map.has_key?(node, "marks") && is_list(node["marks"]) do
        # Find any coloredEntity marks with deleted: true
        deleted_marks =
          Enum.filter(node["marks"], fn mark ->
            mark["type"] == "coloredEntity" &&
              is_map(mark["attrs"]) &&
              Map.get(mark["attrs"], "deleted") == true
          end)

        # Log any found deleted entities
        Enum.each(deleted_marks, fn mark ->
          entity_id = get_in(mark, ["attrs", "entityId"])
          Logger.info("Found deleted entity in formatted content at #{node_path}: #{entity_id}")
        end)
      end
    end)
  end

  # Helper function to process formatted content
  defp process_formatted_content(formatted_content) do
    # Use TipTapSnippets to extract and potentially modify entities
    entities = TipTapSnippets.get_entities_from_formatted_content(formatted_content)

    # Log found entities
    if length(entities) > 0 do
      Logger.debug("Found #{length(entities)} entities in formatted content")

      # Example of how we could modify entities if needed
      # This just logs them for now
      Enum.each(entities, fn entity ->
        Logger.debug(
          "Entity found: #{inspect(entity.text)} (#{inspect(entity.attrs["entityType"])})"
        )
      end)
    end

    # For now, just return the original content
    # In the future, we could modify entities here if needed
    formatted_content
  end

  @impl true
  def handle_event("force_refresh_editor", %{"tab_id" => tab_id}, socket) do
    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    IO.puts("Handling force_refresh_editor ")

    if tab do
      content = Map.get(tab, :content, "")
      formatted_content = Map.get(tab, :formatted_content)

      # Add logger output to debug
      if formatted_content do
        Logger.debug("Force refreshing editor with formatted content")
        # Check for hardBreak nodes
        has_hardbreaks = check_for_hardbreaks(formatted_content)
        Logger.debug("Content has hardBreaks: #{has_hardbreaks}")
      end

      socket =
        push_event(socket, "force_refresh_editor", %{
          content: content,
          formatted_content: Jason.encode!(formatted_content)
        })

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Helper to check for hardBreak nodes in content
  defp check_for_hardbreaks(%{"content" => content}) when is_list(content) do
    Enum.any?(content, fn
      %{"content" => block_content} when is_list(block_content) ->
        Enum.any?(block_content, fn
          %{"type" => "hardBreak"} -> true
          _ -> false
        end)

      _ ->
        false
    end)
  end

  defp check_for_hardbreaks(_), do: false

  @impl true
  def handle_event("entity-deletion", %{"entity_id" => entity_id}, socket) do
    # This is the handler for entity deletion
    Logger.info("Entity marked for deletion: #{entity_id}")

    # Send notification to the LiveView process
    send(
      self(),
      {:tiptap_entity_marked_for_deletion, socket.assigns.active_tab, entity_id}
    )

    # Ensure we save the state immediately to persist the deletion
    tab = Enum.find(socket.assigns.tabs, &(&1.id == socket.assigns.active_tab))

    if tab do
      ContentPersistence.save_tab_content_to_db(
        %{assigns: %{report_id: socket.assigns.report_id}},
        tab
      )
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event(
        "entity-replace",
        %{"entity_id" => entity_id, "replacement" => replacement, "original" => original},
        socket
      ) do
    Logger.info("Entity replacement: #{entity_id} -> #{replacement} (was: #{original})")

    # For backward compatibility, use the replacement as display text
    send(
      self(),
      {:tiptap_entity_replaced, socket.assigns.active_tab, entity_id, replacement, true, original,
       replacement}
    )

    # Set flag for persistence
    socket = assign(socket, :persist_entity_change, true)

    {:noreply, socket}
  end

  @impl true
  def handle_event(
        "entity-replace",
        %{"entity_id" => entity_id, "replacement" => replacement},
        socket
      ) do
    Logger.info("Old Entity replacement: #{entity_id} -> #{replacement}")

    # For backward compatibility, use the replacement as display text
    send(
      self(),
      {:tiptap_entity_replaced, socket.assigns.active_tab, entity_id, replacement, true, nil,
       replacement}
    )

    # Set flag for persistence
    socket = assign(socket, :persist_entity_change, true)

    {:noreply, socket}
  end

  @impl true
  def handle_event("entity-restore", %{"entity_id" => entity_id}, socket) do
    # This handles entity restoration (undoing deletion)
    Logger.info("Entity restore request received for: #{entity_id}")

    # Send notification to the LiveView process
    send(
      self(),
      {:tiptap_entity_restored, socket.assigns.active_tab, entity_id}
    )

    {:noreply, socket}
  end

  @impl true
  def handle_event("entity-marked-for-deletion", %{"index" => entity_id}, socket) do
    handle_event("entity-deletion", %{"entity_id" => entity_id}, socket)
  end

  @impl true
  def handle_info({:tiptap_entity_marked_for_deletion, tab_id, entity_id}, socket) do
    # Log the entity marked for deletion
    Logger.info("Entity #{entity_id} marked for deletion in tab #{tab_id}")

    # Get current tab
    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab do
      # Update the entity's "deleted" flag in the formatted content
      formatted_content = Map.get(tab, :formatted_content)

      # Mark the entity as deleted in the formatted content
      updated_formatted_content = mark_entity_as_deleted(formatted_content, entity_id, true)

      IO.inspect(updated_formatted_content, label: "Updated formatted content after deletion")

      # Update the tab with the modified formatted content
      updated_tab = Map.put(tab, :formatted_content, updated_formatted_content)

      # Update the tabs list
      updated_tabs =
        Enum.map(socket.assigns.tabs, fn t ->
          if t.id == tab_id, do: updated_tab, else: t
        end)

      # Assign updated tabs to socket
      socket = assign(socket, :tabs, updated_tabs)

      # Force an immediate save to MongoDB to ensure entity changes are persisted
      # This is crucial for maintaining entity state between page loads
      ContentPersistence.save_tab_content_to_db(
        %{assigns: %{report_id: socket.assigns.report_id}},
        updated_tab
      )

      # Immediately update the editor with the deletion flag
      if connected?(socket) do
        push_event(socket, "editor_content_update", %{
          editorId: "tiptap-editor-#{tab_id}",
          content: updated_tab.content,
          formattedContent: Jason.encode!(updated_formatted_content)
        })
      end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("selection-entity-update", params, socket) do
    # Log the received params for debugging
    Logger.warning("Received selection-entity-update with unexpected params: #{inspect(params)}")

    # Extract parameters as best we can
    entity_id = Map.get(params, "entityId") || Map.get(params, :entityId)
    deleted = Map.get(params, "deleted", false)
    confirmed = Map.get(params, "confirmed", false)

    if entity_id do
      # Recursively call the properly-matched function with correct parameter structure
      handle_event(
        "selection-entity-update",
        %{"entity_id" => entity_id, "deleted" => deleted, "confirmed" => confirmed},
        socket
      )
    else
      # Cannot proceed without entity_id
      Logger.error("Cannot process selection-entity-update without entity_id")
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:tiptap_content_updated, tab_id, content, formatted_content}, socket) do
    # Update the tab content in memory
    updated_tabs =
      Enum.map(socket.assigns.tabs, fn tab ->
        if tab.id == tab_id do
          tab
          |> Map.put(:content, content)
          |> Map.put(:formatted_content, formatted_content)
        else
          tab
        end
      end)

    # Start a background task for saving content
    tab = Enum.find(updated_tabs, &(&1.id == tab_id))

    if tab do
      Task.start(fn ->
        result =
          ContentPersistence.save_tab_content_to_db(
            %{assigns: %{report_id: socket.assigns.report_id}},
            tab
          )

        Logger.debug("Background save result: #{inspect(result)}")
      end)
    end

    # Immediately update UI state
    {:noreply, assign(socket, tabs: updated_tabs)}
  end

  @impl true
  def handle_info({:tiptap_entity_removed, tab_id, entity_id}, socket) do
    # Log the entity removal
    Logger.info("Entity #{entity_id} removed from tab #{tab_id}")

    # You can implement additional processing here if needed

    {:noreply, socket}
  end

  @impl true
  def handle_info(
        {:tiptap_entity_replaced, tab_id, entity_id, replacement, switched, original,
         display_text, color},
        socket
      ) do
    # Log the entity replacement with display text and color
    if switched do
      Logger.info(
        "Entity #{entity_id} in tab #{tab_id} switched: #{original} -> #{replacement} (displayed as: #{display_text}, color: #{color})"
      )
    else
      Logger.info(
        "Entity #{entity_id} in tab #{tab_id} replaced with: #{replacement} (displayed as: #{display_text}, color: #{color})"
      )
    end

    # Get current tab - always persist the entity change, don't rely on a flag
    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab do
      formatted_content = Map.get(tab, :formatted_content, %{})

      # ===== FIRST CASE: Check if display_text matches any selection list entity =====
      selection_list_entities = find_selection_list_entities(formatted_content)

      # Check if display_text matches originalText in any selection list entity
      matching_display_entities =
        Enum.filter(selection_list_entities, fn entity ->
          # Match when originalText equals display_text
          Map.get(entity, "originalText") == display_text
        end)

      # IMPORTANT CHANGE: Instead of handling selection list updates directly,
      # Send them back to the client first with a special event
      if length(matching_display_entities) > 0 do
        # Send a single event with all matching entities that need updating
        push_event(socket, "queue_selection_entity_updates", %{
          entities:
            Enum.map(matching_display_entities, fn entity ->
              %{
                entity_id: Map.get(entity, "entityId"),
                deleted: true,
                confirmed: false
              }
            end)
        })

        Logger.info(
          "Queued #{length(matching_display_entities)} selection entity updates to client"
        )
      end

      # ===== SECOND CASE: Check for original text matching selection list entities =====
      # First, extract all colored entities from the document
      colored_entities = find_colored_entities(formatted_content)

      # Check if there's NO existing colored entity with displayText matching the original
      no_matching_colored_entity =
        not Enum.any?(colored_entities, fn entity ->
          Map.get(entity, :display_text) == original
        end)

      # Check if there IS a selection list entity with originalText matching the original
      matching_original_entities =
        Enum.filter(selection_list_entities, fn entity ->
          Map.get(entity, "originalText") == original
        end)

      # If both conditions are true, queue these updates too
      if !no_matching_colored_entity && length(matching_original_entities) > 0 do
        # Again, send these to the client for proper queueing
        push_event(socket, "queue_selection_entity_updates", %{
          entities:
            Enum.map(matching_original_entities, fn entity ->
              %{
                entity_id: Map.get(entity, "entityId"),
                deleted: false,
                confirmed: false
              }
            end)
        })

        Logger.info(
          "Queued #{length(matching_original_entities)} additional selection entity updates to client"
        )
      end

      # Proceed with saving the entity replacement content
      result = ContentPersistence.save_tab_content_to_db(socket, tab)
      Logger.info("Entity replacement saved in tab #{tab_id}: #{inspect(result)}")

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  defp update_replaced_entity(formatted_content, entity_id, replacement, display_text, color) do
    try do
      case formatted_content do
        %{"content" => content} when is_list(content) ->
          # Update content by finding and updating the specific entity
          updated_content =
            Enum.map(content, fn block ->
              update_entity_in_block(block, entity_id, replacement, display_text, color)
            end)

          # Return the updated formatted content
          Map.put(formatted_content, "content", updated_content)

        _ ->
          # If not the expected structure, return unchanged
          Logger.warn("Could not update entity - invalid formatted content structure")
          formatted_content
      end
    rescue
      e ->
        Logger.error("Error updating replaced entity: #{inspect(e)}")
        formatted_content
    end
  end

  # Update entity in a block
  defp update_entity_in_block(
         %{"content" => block_content} = block,
         entity_id,
         replacement,
         display_text,
         color
       )
       when is_list(block_content) do
    # Process each node in the content
    updated_content =
      Enum.map(block_content, fn node ->
        update_entity_in_node(node, entity_id, replacement, display_text, color)
      end)

    # Return block with updated content
    Map.put(block, "content", updated_content)
  end

  defp update_entity_in_block(block, _entity_id, _replacement, _display_text, _color), do: block

  # Update entity in a node
  defp update_entity_in_node(
         %{"marks" => marks} = node,
         entity_id,
         replacement,
         display_text,
         color
       )
       when is_list(marks) do
    # Try to find the specific entity mark
    {updated_marks, found} =
      Enum.map_reduce(marks, false, fn mark, found ->
        if mark["type"] == "coloredEntity" && get_in(mark, ["attrs", "entityId"]) == entity_id do
          # Update the entity attributes
          updated_attrs =
            mark["attrs"]
            |> Map.put("currentText", replacement)
            |> Map.put("displayText", display_text || replacement)

          # Only update color if provided
          updated_attrs =
            if color, do: Map.put(updated_attrs, "entityColor", color), else: updated_attrs

          # Put the updated attributes back in the mark
          {Map.put(mark, "attrs", updated_attrs), true}
        else
          {mark, found || false}
        end
      end)

    if found do
      # If we found and updated the entity, update the node text and marks
      node
      |> Map.put("marks", updated_marks)
      |> Map.put("text", display_text || replacement)
    else
      # Check for nested content
      if Map.has_key?(node, "content") && is_list(node["content"]) do
        updated_content =
          Enum.map(node["content"], fn child_node ->
            update_entity_in_node(child_node, entity_id, replacement, display_text, color)
          end)

        Map.put(node, "content", updated_content)
      else
        node
      end
    end
  end

  # Helper function to find colored entities in formatted content
  defp find_colored_entities(formatted_content) do
    try do
      # Only process valid content
      if is_map(formatted_content) && Map.has_key?(formatted_content, "content") do
        extract_colored_entities(formatted_content["content"], [], [])
      else
        Logger.warn("Invalid formatted content structure for entity extraction")
        []
      end
    rescue
      e ->
        Logger.error("Error extracting colored entities: #{inspect(e)}")
        []
    end
  end

  # Process a list of content blocks
  defp extract_colored_entities(blocks, path, acc) when is_list(blocks) do
    # Process each block with its index for path tracking
    Enum.with_index(blocks)
    |> Enum.reduce(acc, fn {block, index}, entities ->
      current_path = path ++ [index]
      extract_colored_entities_from_block(block, current_path, entities)
    end)
  end

  # Base case - not a list or map
  defp extract_colored_entities(_, _, acc), do: acc

  # Handle different block types
  defp extract_colored_entities_from_block(
         %{"type" => "list", "marks" => marks} = block,
         path,
         acc
       ) do
    # Check if this is a selection list - if so, skip it entirely
    if Enum.any?(marks, fn mark ->
         mark["type"] == "coloredEntity" &&
           get_in(mark, ["attrs", "entityType"]) == "selection_list"
       end) do
      # This is a selection list - don't process it
      acc
    else
      # Regular list - process its content if it has any
      case Map.get(block, "content") do
        content when is_list(content) ->
          extract_colored_entities(content, path ++ ["content"], acc)

        _ ->
          acc
      end
    end
  end

  # Handle selectionList block type directly
  defp extract_colored_entities_from_block(%{"type" => "selectionList"}, _path, acc) do
    # Skip selection lists entirely
    acc
  end

  # Handle paragraph and other block types with content
  defp extract_colored_entities_from_block(%{"type" => _type, "content" => content}, path, acc)
       when is_list(content) do
    # Process the block's content
    extract_colored_entities(content, path ++ ["content"], acc)
  end

  # Handle text nodes with colored entity marks
  defp extract_colored_entities_from_block(
         %{"type" => "text", "marks" => marks, "text" => text} = node,
         path,
         acc
       )
       when is_list(marks) do
    # Look for coloredEntity marks
    colored_entity_marks = Enum.filter(marks, fn mark -> mark["type"] == "coloredEntity" end)

    if colored_entity_marks != [] do
      # Extract each entity info
      entities =
        Enum.map(colored_entity_marks, fn mark ->
          attrs = Map.get(mark, "attrs", %{})

          # Extract key attributes with defaults
          %{
            id: Map.get(attrs, "entityId", "unknown-id"),
            text: text,
            type: Map.get(attrs, "entityType", "unknown"),
            category: Map.get(attrs, "entityCategory", "unknown"),
            color: Map.get(attrs, "entityColor", "#d8b5ff"),
            deleted: Map.get(attrs, "deleted", false),
            original_text: Map.get(attrs, "originalText", text),
            display_text: Map.get(attrs, "displayText", text),
            current_text: Map.get(attrs, "currentText", text),
            replacements: Map.get(attrs, "replacements", []),
            path: path
          }
        end)

      # Add this entity to our accumulated list
      acc ++ entities
    else
      # No entity marks, return unchanged accumulator
      acc
    end
  end

  # Catch-all for any other node type
  defp extract_colored_entities_from_block(_, _, acc), do: acc

  @impl true
  def handle_info(
        {:tiptap_entity_replaced, tab_id, entity_id, replacement, switched, original,
         display_text},
        socket
      ) do
    # Call the new handler with color defaulting to nil
    handle_info(
      {:tiptap_entity_replaced, tab_id, entity_id, replacement, switched, original, display_text,
       nil},
      socket
    )
  end

  # Further backward compatibility
  @impl true
  def handle_info(
        {:tiptap_entity_replaced, tab_id, entity_id, replacement, switched, original},
        socket
      ) do
    # Call the handler with display_text defaulting to replacement and color to nil
    handle_info(
      {:tiptap_entity_replaced, tab_id, entity_id, replacement, switched, original, replacement,
       nil},
      socket
    )
  end

  @impl true
  def handle_info({:tiptap_entity_restored, tab_id, entity_id}, socket) do
    # Log the entity restoration
    Logger.info("Processing entity restoration for #{entity_id} in tab #{tab_id}")

    # Get current tab
    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab do
      # Update the entity's "deleted" flag in the formatted content
      formatted_content = Map.get(tab, :formatted_content)

      # Mark the entity as not deleted in the formatted content
      updated_formatted_content = mark_entity_as_deleted(formatted_content, entity_id, false)

      IO.inspect(updated_formatted_content,
        label: "Updated formatted content after restoration"
      )

      # Log verification that the entity was marked as not deleted
      if updated_formatted_content != formatted_content do
        Logger.info("Entity #{entity_id} successfully marked as not deleted in formatted content")
      else
        Logger.warn("No change in formatted content when restoring entity #{entity_id}")
      end

      # Update the tab with the modified formatted content
      updated_tab = Map.put(tab, :formatted_content, updated_formatted_content)

      # Update the tabs list
      updated_tabs =
        Enum.map(socket.assigns.tabs, fn t ->
          if t.id == tab_id, do: updated_tab, else: t
        end)

      # Assign updated tabs to socket
      socket = assign(socket, :tabs, updated_tabs)

      # Force an immediate save to MongoDB
      ContentPersistence.save_tab_content_to_db(
        %{assigns: %{report_id: socket.assigns.report_id}},
        updated_tab
      )

      # Send an update to the client to refresh the editor state
      if connected?(socket) do
        push_event(socket, "editor_content_update", %{
          editorId: "tiptap-editor-#{tab_id}",
          content: updated_tab.content,
          formattedContent: Jason.encode!(updated_formatted_content)
        })
      end
    else
      Logger.warn("Tab #{tab_id} not found when restoring entity #{entity_id}")
    end

    {:noreply, socket}
  end

  # Helper function to mark an entity as deleted or not in formatted content
  defp mark_entity_as_deleted(formatted_content, entity_id, is_deleted) do
    try do
      case formatted_content do
        %{"content" => content} when is_list(content) ->
          # Process each block in the content
          updated_content =
            Enum.map(content, fn block ->
              update_entity_deletion_in_block(block, entity_id, is_deleted)
            end)

          # Return updated content
          Map.put(formatted_content, "content", updated_content)

        _ ->
          # If not the expected structure, return as is

          formatted_content
      end
    rescue
      e ->
        Logger.error("Error updating entity deletion state: #{inspect(e)}")
        formatted_content
    end
  end

  # Update entity in a content block for deletion status
  defp update_entity_deletion_in_block(
         %{"content" => block_content} = block,
         entity_id,
         is_deleted
       )
       when is_list(block_content) do
    updated_block_content =
      Enum.map(block_content, fn node ->
        update_entity_deletion_in_node(node, entity_id, is_deleted)
      end)

    Map.put(block, "content", updated_block_content)
  end

  defp update_entity_deletion_in_block(block, _entity_id, _is_deleted), do: block

  # Update entity deletion state in a node
  defp update_entity_deletion_in_node(%{"marks" => marks} = node, entity_id, is_deleted)
       when is_list(marks) do
    # Find any coloredEntity mark
    {updated_marks, found} =
      Enum.map_reduce(marks, false, fn mark, found ->
        if mark["type"] == "coloredEntity" && get_in(mark, ["attrs", "entityId"]) == entity_id do
          # Found our entity, update its attributes with the deleted flag
          updated_attrs = Map.put(mark["attrs"], "deleted", is_deleted)
          {Map.put(mark, "attrs", updated_attrs), true}
        else
          {mark, found}
        end
      end)

    if found do
      # If we found and updated the entity, update the marks
      Map.put(node, "marks", updated_marks)
    else
      node
    end
  end

  defp update_entity_deletion_in_node(node, _entity_id, _is_deleted), do: node

  # # Helper function to mark an entity as deleted or not in formatted content
  # defp mark_entity_as_deleted(formatted_content, entity_id, is_deleted) do
  #   try do
  #     case formatted_content do
  #       %{"content" => content} when is_list(content) ->
  #         # Process each block in the content
  #         updated_content = mark_entity_in_blocks(content, entity_id, is_deleted)

  #         # Log how many entities were updated
  #         entities_updated =
  #           count_marked_entities(content, entity_id, is_deleted) -
  #             count_marked_entities(updated_content, entity_id, !is_deleted)

  #         if entities_updated > 0 do
  #           Logger.info(
  #             "Marked #{entities_updated} instances of entity #{entity_id} as #{if is_deleted, do: "deleted", else: "not deleted"}"
  #           )
  #         end

  #         # Return updated content
  #         Map.put(formatted_content, "content", updated_content)

  #       _ ->
  #         # If not the expected structure, return as is
  #         formatted_content
  #     end
  #   rescue
  #     e ->
  #       Logger.error("Error updating entity deletion state: #{inspect(e)}")
  #       formatted_content
  #   end
  # end

  # # Helper to mark entities in all blocks recursively
  # defp mark_entity_in_blocks(blocks, entity_id, is_deleted) when is_list(blocks) do
  #   Enum.map(blocks, fn block ->
  #     mark_entity_in_block(block, entity_id, is_deleted)
  #   end)
  # end

  # defp mark_entity_in_blocks(_, _, _), do: []

  # # Helper to mark a single block (recursively) for entity deletion state
  # defp mark_entity_in_block(%{"content" => block_content} = block, entity_id, is_deleted)
  #      when is_list(block_content) do
  #   updated_block_content =
  #     Enum.map(block_content, fn node ->
  #       mark_entity_in_node(node, entity_id, is_deleted)
  #     end)

  #   Map.put(block, "content", updated_block_content)
  # end

  # defp mark_entity_in_block(block, _entity_id, _is_deleted), do: block

  # defp mark_entity_in_node(%{"marks" => marks} = node, entity_id, is_deleted)
  #      when is_list(marks) do
  #   {updated_marks, found} =
  #     Enum.map_reduce(marks, false, fn mark, found ->
  #       if mark["type"] == "coloredEntity" && get_in(mark, ["attrs", "entityId"]) == entity_id do
  #         updated_attrs = Map.put(mark["attrs"], "deleted", is_deleted)
  #         {Map.put(mark, "attrs", updated_attrs), true}
  #       else
  #         {mark, found}
  #       end
  #     end)

  #   updated_node =
  #     if found do
  #       Map.put(node, "marks", updated_marks)
  #     else
  #       node
  #     end

  #   # Recurse into children if present
  #   if is_map(updated_node) and Map.has_key?(updated_node, "content") and
  #        is_list(updated_node["content"]) do
  #     Map.put(
  #       updated_node,
  #       "content",
  #       Enum.map(updated_node["content"], fn child ->
  #         mark_entity_in_node(child, entity_id, is_deleted)
  #       end)
  #     )
  #   else
  #     updated_node
  #   end
  # end

  # # Count marked entities before and after (for logging)
  # defp count_marked_entities(blocks, entity_id, marked_state) when is_list(blocks) do
  #   Enum.reduce(blocks, 0, fn block, count ->
  #     count + count_marked_entities_in_block(block, entity_id, marked_state)
  #   end)
  # end

  # defp count_marked_entities_in_block(%{"content" => content}, entity_id, marked_state)
  #      when is_list(content) do
  #   Enum.reduce(content, 0, fn node, count ->
  #     count + count_marked_entities_in_node(node, entity_id, marked_state)
  #   end)
  # end

  # defp count_marked_entities_in_block(_, _, _), do: 0

  # defp count_marked_entities_in_node(%{"marks" => marks} = node, entity_id, marked_state)
  #      when is_list(marks) do
  #   marks_matching =
  #     Enum.count(marks, fn mark ->
  #       mark["type"] == "coloredEntity" &&
  #         get_in(mark, ["attrs", "entityId"]) == entity_id &&
  #         get_in(mark, ["attrs", "deleted"]) == marked_state
  #     end)

  #   # Also check content if this is a parent node
  #   child_count =
  #     if Map.has_key?(node, "content") && is_list(node["content"]) do
  #       Enum.reduce(node["content"], 0, fn child, count ->
  #         count + count_marked_entities_in_node(child, entity_id, marked_state)
  #       end)
  #     else
  #       0
  #     end

  #   marks_matching + child_count
  # end

  # defp count_marked_entities_in_block(%{"content" => content}, entity_id, marked_state)
  #      when is_list(content) do
  #   Enum.reduce(content, 0, fn node, count ->
  #     count + count_marked_entities_in_node(node, entity_id, marked_state)
  #   end)
  # end

  # defp count_marked_entities_in_block(_, _, _), do: 0

  # defp count_marked_entities_in_node(%{"marks" => marks} = node, entity_id, marked_state)
  #      when is_list(marks) do
  #   marks_matching =
  #     Enum.count(marks, fn mark ->
  #       mark["type"] == "coloredEntity" &&
  #         get_in(mark, ["attrs", "entityId"]) == entity_id &&
  #         get_in(mark, ["attrs", "deleted"]) == marked_state
  #     end)

  #   # Also check content if this is a parent node
  #   child_count =
  #     if Map.has_key?(node, "content") && is_list(node["content"]) do
  #       Enum.reduce(node["content"], 0, fn child, count ->
  #         count + count_marked_entities_in_node(child, entity_id, marked_state)
  #       end)
  #     else
  #       0
  #     end

  #   marks_matching + child_count
  # end

  # defp count_marked_entities_in_block(_, _, _), do: 0

  # Helper function to find IDs of entities marked as deleted
  defp find_deleted_entity_ids(formatted_content) do
    try do
      case formatted_content do
        %{"content" => content} when is_list(content) ->
          # Search through content recursively for deleted entities
          extract_deleted_entity_ids(content, [])

        _ ->
          []
      end
    rescue
      e ->
        Logger.error("Error finding deleted entity IDs: #{inspect(e)}")
        []
    end
  end

  # Extract IDs of entities marked as deleted from content blocks
  defp extract_deleted_entity_ids(blocks, acc) when is_list(blocks) do
    Enum.reduce(blocks, acc, fn block, entity_ids ->
      case block do
        # Process blocks with content
        %{"content" => content} when is_list(content) ->
          # First check entities directly in this block's content
          ids_in_content = extract_deleted_entity_ids(content, [])

          # Add any found IDs to our accumulator
          ids_in_content ++ entity_ids

        # Process text nodes with marks
        %{"type" => "text", "marks" => marks} when is_list(marks) ->
          # Find any coloredEntity marks with deleted: true
          deleted_ids =
            Enum.reduce(marks, [], fn mark, ids ->
              if mark["type"] == "coloredEntity" &&
                   is_map(mark["attrs"]) &&
                   Map.get(mark["attrs"], "deleted") == true do
                # Extract the entity ID
                entity_id = get_in(mark, ["attrs", "entityId"])
                if entity_id, do: [entity_id | ids], else: ids
              else
                ids
              end
            end)

          # Add any found deleted entity IDs to our accumulator
          entity_ids ++ deleted_ids

        # Handle other block types
        _ ->
          entity_ids
      end
    end)
  end

  defp extract_deleted_entity_ids(_, acc), do: acc
end
