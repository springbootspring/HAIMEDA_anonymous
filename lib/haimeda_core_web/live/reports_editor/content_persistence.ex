defmodule HaimedaCoreWeb.ReportsEditor.ContentPersistence do
  alias HaimedaCoreWeb.ReportsEditor.PreviousContent
  alias Jason
  alias HaimedaCore.Report
  alias IIV
  require Logger

  @doc """
  Main dispatcher function that handles all content saving based on tab type.
  """
  def save_tab_content_to_db(socket, tab) do
    # Check if tab has formatted_content and verify it
    content = tab.formatted_content
    # IO.inspect(content, label: "Content before saving")

    tab =
      if Map.has_key?(tab, :formatted_content) && tab.formatted_content != nil do
        verified_content = verify_formatted_content(tab.formatted_content)

        # Ensure it has the proper structure needed for TipTap
        verified_content =
          if Map.has_key?(verified_content, "type") && Map.has_key?(verified_content, "content") do
            verified_content
          else
            Logger.warn("Fixed malformed content structure during save")
            create_default_formatted_content(tab.content || "")
          end

        tab = Map.put(tab, :formatted_content, verified_content)
        # IO.inspect(verified_content, label: "Verified content after saving")
        tab
      else
        # If no formatted_content, create default from plain content
        default_content = create_default_formatted_content(tab.content || "")
        Map.put(tab, :formatted_content, default_content)
      end

    # Proceed with the existing case matching
    case tab do
      %{category: "general"} ->
        save_general_section_to_db(socket, tab)

      %{category: "chapters", section_id: section_id, content: content} ->
        # Get existing chapter data to avoid losing existing fields
        existing_chapter = get_existing_chapter(socket.assigns.report_id, section_id)

        # Format chapter number correctly
        chapter_number = Map.get(tab, :chapter_number, "")
        formatted_chapter_number = PreviousContent.format_chapter_number_string(chapter_number)

        # Get current chapters to calculate position
        current_chapters = get_all_chapters(socket.assigns.report_id)

        # Calculate position based on chapter numbers
        position =
          calculate_chapter_position(formatted_chapter_number, current_chapters, section_id)

        # Check token length of content to determine if it's a heading-only chapter
        token_length = estimate_token_length(content)

        # Determine chapter type based on token length or title
        chapter_type =
          if token_length < 10 do
            "heading_only"
          else
            determine_chapter_type(tab.label)
          end

        # Get the chapter versions from both sources (tab and existing data)
        # Prefer tab versions if available
        chapter_versions =
          case Map.get(tab, :chapter_versions) do
            versions when is_list(versions) and length(versions) > 0 ->
              versions

            _ ->
              Map.get(existing_chapter, "chapter_versions", [])
          end

        # Get current version index - prefer from tab
        current_version_index =
          Map.get(tab, :current_version) ||
            Map.get(existing_chapter, "current_version", 1)

        # Add debug logging to help diagnose issues
        # Logger.debug("Current versions: #{inspect(chapter_versions)}")
        # Logger.debug("Current version index: #{inspect(current_version_index)}")

        # Ensure the formatted content in the version is synchronized with the plain content
        updated_versions =
          Enum.map(chapter_versions, fn version ->
            if Map.get(version, "version") == current_version_index do
              # For the current version, ALWAYS use the tab's formatted_content if available
              formatted_content =
                if Map.has_key?(tab, :formatted_content) && tab.formatted_content != nil do
                  # Determine a human-friendly description of the formatted_content
                  fc_string =
                    case tab.formatted_content do
                      fc when is_map(fc) ->
                        if Map.has_key?(fc, "type") && Map.has_key?(fc, "content") do
                          "valid TipTap structure"
                        else
                          "INVALID MAP STRUCTURE: #{inspect(fc)}"
                        end

                      other ->
                        "INVALID: #{inspect(other)}"
                    end

                  Logger.debug(
                    "Saving formatted_content (#{fc_string}) to version #{current_version_index}"
                  )

                  # Use the verified content from the tab
                  tab.formatted_content
                else
                  # Fall back to existing or create new if needed
                  create_default_formatted_content(content)
                end

              # Update the version with both the new plain_content and formatted_content
              # When updating content, ALWAYS reset the summary to empty string
              # This is because the content has changed and the summary is no longer valid
              version
              |> Map.put("plain_content", content)
              |> Map.put("formatted_content", formatted_content)
              # Explicitly reset summary when content changes
              |> Map.put("summary", "")
              |> Map.put("type", chapter_type)
            else
              # Keep other versions unchanged
              version
            end
          end)

        # Verify the formatted_content in the version being saved
        current_version =
          Enum.find(updated_versions, fn v ->
            Map.get(v, "version") == current_version_index
          end)

        if current_version do
          # Safely access nested structure to extract text preview
          text_content = get_formatted_content_text(current_version["formatted_content"])

          # Logger.debug(
          #   "CHECKING VERSION BEFORE MONGODB - Version #{current_version_index} text content: #{inspect(text_content)}"
          # )
        end

        # Build update data - do not include formatted_content at the root level to avoid duplication.
        update_data = %{
          "id" => section_id,
          "title" => tab.label,
          "chapter_info" => Map.get(tab, :chapter_info, ""),
          "chapter_versions" => updated_versions,
          "current_version" => current_version_index,
          "chapter_number" => formatted_chapter_number,
          "active_meta_info" => Map.get(tab, :active_meta_info, %{}),
          "position" => position
        }

        # Log the update data for debugging
        # Logger.debug("Saving chapter update: #{inspect(update_data)}")

        # After building update_data, verify the formatted_content is preserved
        updated_version =
          Enum.find(update_data["chapter_versions"], fn v ->
            Map.get(v, "version") == current_version_index
          end)

        if updated_version do
          # Safely examine nested formatted content for diagnostics
          updated_text = get_formatted_content_text(updated_version["formatted_content"])

          # Logger.debug(
          #   "CHECKING UPDATE DATA - Version #{current_version_index} text content in update_data: #{inspect(updated_text)}"
          # )
        end

        # Save the chapter with the merged data
        result =
          Report.update_report_section(
            socket.assigns.report_id,
            "chapters",
            section_id,
            update_data
          )

        Logger.debug("MongoDB update result: #{inspect(result)}")

        # Update positions of other chapters if needed
        update_other_chapters_positions(
          socket.assigns.report_id,
          current_chapters,
          formatted_chapter_number,
          position,
          section_id
        )

      %{category: "parties", section_id: section_id} ->
        person_statements = parse_statements(Map.get(tab, :person_statements, "[]"))
        analysis_statements = parse_statements(Map.get(tab, :analysis_statements, "[]"))

        Report.update_report_section(
          socket.assigns.report_id,
          "parties",
          section_id,
          %{
            id: section_id,
            title: tab.label,
            person_statements: person_statements,
            analysis_statements: analysis_statements
          }
        )

      _ ->
        nil
    end
  end

  # Create default formatted content structure for TipTap - made public
  @doc """
  Creates a default formatted content structure for TipTap editor
  """
  def create_default_formatted_content(plain_text) do
    # If empty, create an empty paragraph
    if plain_text == "" do
      %{
        "type" => "doc",
        "content" => [
          %{
            "type" => "paragraph",
            "content" => [
              %{"type" => "text", "text" => ""}
            ]
          }
        ]
      }
    else
      # Process the entire text preserving hard breaks
      segments = String.split(plain_text, "\n", trim: false)

      # Create nodes with proper hardBreak nodes and correct whitespace handling
      content_nodes =
        segments
        |> Enum.with_index()
        |> Enum.flat_map(fn {segment, idx} ->
          is_last = idx == length(segments) - 1

          # For each segment, create a text node followed by hardBreak and whitespace nodes
          text_node = %{"type" => "text", "text" => segment}

          if is_last do
            [text_node]
          else
            # Use proper hardBreak node
            [
              text_node,
              %{"type" => "hardBreak"}
            ]
          end
        end)

      %{
        "type" => "doc",
        "content" => [
          %{
            "type" => "paragraph",
            "content" => content_nodes
          }
        ]
      }
    end
  end

  @doc """
  Verifies and repairs formatted content to ensure it has valid structure
  """
  def verify_formatted_content(formatted_content) do
    case formatted_content do
      # Valid structure
      %{"type" => "doc", "content" => content} when is_list(content) ->
        # Verify and repair each paragraph's content
        updated_content =
          Enum.map(content, fn
            # Process paragraph nodes
            %{"type" => "paragraph", "content" => para_content} = para when is_list(para_content) ->
              # Filter out invalid nodes and fix common typos
              fixed_content =
                para_content
                |> Enum.filter(fn
                  # Keep valid text nodes
                  %{"type" => "text"} -> true
                  # Keep hardBreak nodes
                  %{"type" => "hardBreak"} -> true
                  # Filter out malformed nodes
                  _ -> false
                end)
                |> Enum.map(fn node ->
                  # Fix "ttext" typo if present
                  if is_map(node) && Map.has_key?(node, "ttext") do
                    node
                    |> Map.put("text", Map.get(node, "ttext"))
                    |> Map.delete("ttext")
                  else
                    node
                  end
                end)
                |> ensure_whitespace_after_hardbreaks()

              # Update paragraph with fixed content
              Map.put(para, "content", fixed_content)

            # Return other nodes as-is
            other ->
              other
          end)

        # Return updated document
        Map.put(formatted_content, "content", updated_content)

      # Invalid or empty structure, create default
      _ ->
        Logger.warning("Invalid formatted content structure, creating default")
        create_default_formatted_content("")
    end
  end

  # Helper to ensure whitespace after hardbreaks - modified to include hardBreak nodes
  defp ensure_whitespace_after_hardbreaks(nodes) do
    # Process nodes and add proper space after hardBreak nodes
    Enum.flat_map(nodes, fn
      # For hardBreak nodes, keep them and add a space after
      %{"type" => "hardBreak"} ->
        [
          %{"type" => "hardBreak"}
        ]

      # Keep other nodes unchanged
      other_node ->
        [other_node]
    end)
  end

  @doc """
  Returns existing rich formatted content or creates default when invalid
  """
  def preserve_rich_formatted_content(plain_text, formatted_content) do
    cond do
      # If formatted_content is a map with proper TipTap structure, use it
      is_map(formatted_content) &&
          (Map.has_key?(formatted_content, "type") || Map.has_key?(formatted_content, "content")) ->
        formatted_content

      # If formatted_content is nil or invalid, create default
      true ->
        create_default_formatted_content(plain_text)
    end
  end

  # Create an empty new chapter version
  def save_chapter_version(report_id, section_id, _plain_content, _formatted_content) do
    existing_chapter = get_existing_chapter(report_id, section_id)

    current_versions = Map.get(existing_chapter, "chapter_versions", [])
    next_version = length(current_versions) + 1

    # Create a new EMPTY version (remove the content parameters)
    new_version = %{
      "version" => next_version,
      # Now creating an empty version
      "plain_content" => "",
      "summary" => "",
      "type" => "only_heading",
      "formatted_content" => create_default_formatted_content(""),
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    # Add the new empty version to the end of the list
    updated_versions = current_versions ++ [new_version]

    update_data = %{
      "chapter_versions" => updated_versions,
      "current_version" => next_version
    }

    Report.update_report_section(
      report_id,
      "chapters",
      section_id,
      update_data
    )
  end

  # Delete a chapter version and renumber remaining versions
  def delete_chapter_version(report_id, section_id, version_to_delete) do
    existing_chapter = get_existing_chapter(report_id, section_id)

    current_versions = Map.get(existing_chapter, "chapter_versions", [])
    current_version_index = Map.get(existing_chapter, "current_version", 1)

    # Filter out the version to delete
    filtered_versions =
      Enum.reject(current_versions, fn v ->
        Map.get(v, "version") == version_to_delete
      end)

    # If no versions remain, create a default empty version
    updated_versions =
      if Enum.empty?(filtered_versions) do
        [
          %{
            "version" => 1,
            "plain_content" => "",
            "summary" => "",
            "type" => "only_heading",
            "formatted_content" => create_default_formatted_content(""),
            "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        ]
      else
        # Renumber the remaining versions (decrement versions after the deleted one)
        filtered_versions
        |> Enum.sort_by(fn v -> Map.get(v, "version") end)
        |> Enum.map(fn version ->
          version_num = Map.get(version, "version")

          if version_num > version_to_delete do
            # Decrement version numbers after the deleted one
            Map.put(version, "version", version_num - 1)
          else
            # Keep version numbers before the deleted one
            version
          end
        end)
      end

    # Adjust the current version index if needed
    new_current_version =
      cond do
        # If the deleted version was the current version
        current_version_index == version_to_delete ->
          # Check if there's a version after the one we're deleting
          has_next_version =
            Enum.any?(current_versions, fn v ->
              Map.get(v, "version") == version_to_delete + 1
            end)

          if has_next_version do
            # After renumbering, version X+1 becomes version X
            version_to_delete
          else
            # No next version, go to the highest remaining version
            length(updated_versions)
          end

        # If the deleted version was before the current version, decrement the current version
        current_version_index > version_to_delete ->
          current_version_index - 1

        # Otherwise keep the same current version
        true ->
          current_version_index
      end

    # Get the current version's plain content for backward compatibility
    current_version =
      Enum.find(updated_versions, fn v ->
        Map.get(v, "version") == new_current_version
      end)

    plain_content =
      if current_version do
        Map.get(current_version, "plain_content", "")
      else
        ""
      end

    # Update the chapter with new versions and adjusted current version
    update_data = %{
      "chapter_versions" => updated_versions,
      "current_version" => new_current_version
    }

    Report.update_report_section(
      report_id,
      "chapters",
      section_id,
      update_data
    )

    # Return the updated versions and new current version
    {:ok, updated_versions, new_current_version}
  end

  # Get the version count for a chapter
  def get_chapter_version_count(report_id, section_id) do
    existing_chapter = get_existing_chapter(report_id, section_id)
    versions = Map.get(existing_chapter, "chapter_versions", [])
    length(versions)
  end

  # Function to get a specific version from a chapter
  def get_chapter_version(report_id, section_id, version) do
    existing_chapter = get_existing_chapter(report_id, section_id)

    versions = Map.get(existing_chapter, "chapter_versions", [])

    Enum.find(versions, fn v -> Map.get(v, "version") == version end)
  end

  # Function to get the current version from a chapter
  def get_current_chapter_version(report_id, section_id) do
    existing_chapter = get_existing_chapter(report_id, section_id)

    current_version = Map.get(existing_chapter, "current_version")
    get_chapter_version(report_id, section_id, current_version)
  end

  # Function to set which version is current
  def set_current_chapter_version(report_id, section_id, version) do
    update_data = %{"current_version" => version}

    Report.update_report_section(
      report_id,
      "chapters",
      section_id,
      update_data
    )
  end

  @doc """
  Determines the chapter type based on the title using IIV classification
  """
  def determine_chapter_type(title) do
    case IIV.classify_filename(title) do
      "Technische_Daten" -> "technical"
      _ -> "regular_chapter"
    end
  rescue
    e ->
      Logger.error("Error determining chapter type: #{inspect(e)}")
      # Default type in case of errors
      "regular_chapter"
  end

  @doc """
  Retrieves all chapters for a report
  """
  def get_all_chapters(report_id) do
    case Report.get_report(report_id) do
      {:ok, report} ->
        chapters = Map.get(report, "chapters", [])

        # Map each chapter to include formatted chapter numbers and positions
        Enum.map(chapters, fn chapter ->
          chapter_number = Map.get(chapter, "chapter_number", "")
          formatted_number = PreviousContent.format_chapter_number_string(chapter_number)

          chapter
          |> Map.put("formatted_chapter_number", formatted_number)
          # Default position if not set
          |> Map.put_new("position", 0)
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Calculates the position of a chapter based on its chapter number compared to other chapters
  """
  def calculate_chapter_position(formatted_chapter_number, all_chapters, current_chapter_id) do
    if formatted_chapter_number == "" do
      # If no chapter number, put at the end
      length(all_chapters) + 1
    else
      # Get all chapters except the current one
      other_chapters =
        Enum.filter(all_chapters, fn ch -> Map.get(ch, "id") != current_chapter_id end)

      # Find how many chapters have a smaller chapter number
      smaller_chapters =
        Enum.count(other_chapters, fn ch ->
          other_number = Map.get(ch, "formatted_chapter_number", "")
          PreviousContent.chapter_number_less_than?(other_number, formatted_chapter_number)
        end)

      # Position is 1-based, so add 1 to the count of smaller chapters
      smaller_chapters + 1
    end
  end

  @doc """
  Find the position of a chapter in a sorted list of chapters
  """
  def find_position_in_sorted_list(chapter_number, sorted_chapters) do
    # Find where this chapter number should be inserted in the sorted list
    insertion_index =
      Enum.find_index(sorted_chapters, fn ch ->
        other_number = Map.get(ch, "formatted_chapter_number", "")
        PreviousContent.compare_chapter_numbers_strings(chapter_number, other_number) == :lt
      end)

    if insertion_index == nil do
      # If not found, it goes at the end
      length(sorted_chapters) + 1
    else
      # Otherwise, it goes at the found position
      insertion_index + 1
    end
  end

  @doc """
  Updates positions of other chapters after a chapter's position has changed
  """
  def update_other_chapters_positions(
        report_id,
        all_chapters,
        changed_chapter_number,
        new_position,
        changed_chapter_id
      ) do
    # Sort all chapters including the changed one by their chapter numbers
    sorted_chapters =
      all_chapters
      |> Enum.map(fn ch ->
        # If this is the changed chapter, update its chapter number
        if Map.get(ch, "id") == changed_chapter_id do
          Map.put(ch, "formatted_chapter_number", changed_chapter_number)
        else
          ch
        end
      end)
      |> Enum.sort_by(
        fn ch -> Map.get(ch, "formatted_chapter_number", "") end,
        fn a, b -> PreviousContent.chapter_number_less_than?(a, b) end
      )

    # Assign positions based on the sorted order
    sorted_chapters_with_positions =
      sorted_chapters
      |> Enum.with_index(1)
      |> Enum.map(fn {ch, idx} -> Map.put(ch, "position", idx) end)

    # Update each chapter's position in the database, except the changed one
    # which is already updated in the main save function
    Enum.each(sorted_chapters_with_positions, fn ch ->
      ch_id = Map.get(ch, "id")

      if ch_id != changed_chapter_id do
        # Retrieve the old position
        old_position =
          Enum.find_value(all_chapters, 0, fn old_ch ->
            if Map.get(old_ch, "id") == ch_id, do: Map.get(old_ch, "position", 0), else: nil
          end)

        # Only update if position changed
        new_position = Map.get(ch, "position")

        if old_position != new_position do
          Report.update_report_section(
            report_id,
            "chapters",
            ch_id,
            %{"position" => new_position}
          )
        end
      end
    end)
  end

  @doc """
  Saves chapter metadata info (active_meta_info).
  """
  def save_tab_meta_info_to_db(socket, %{category: "chapters", section_id: section_id} = tab) do
    # Get existing chapter data to avoid overwriting other fields
    current_chapter = get_existing_chapter(socket.assigns.report_id, section_id)

    # Convert stringified map keys to strings if needed
    active_meta_info = Map.get(tab, :active_meta_info, %{})

    # Update with new active_meta_info while preserving other fields
    Report.update_report_section(
      socket.assigns.report_id,
      "chapters",
      section_id,
      Map.merge(current_chapter, %{
        "id" => section_id,
        "active_meta_info" => active_meta_info
      })
    )
  end

  def save_tab_meta_info_to_db(_, _), do: nil

  # Helper to get existing chapter data - default current_version is 1
  defp get_existing_chapter(report_id, section_id) do
    case Report.get_report(report_id) do
      {:ok, report} ->
        chapters = Map.get(report, "chapters", [])
        chapter = Enum.find(chapters, fn ch -> Map.get(ch, "id") == section_id end)

        if chapter do
          # Log the retrieved chapter for debugging
          # Logger.debug("Retrieved existing chapter: #{inspect(chapter)}")
          chapter
        else
          # Default structure for a new chapter - current_version = 1
          %{
            "id" => section_id,
            "title" => "",
            "chapter_info" => "",
            "chapter_text" => "",
            "chapter_number" => "",
            "active_meta_info" => %{},
            "chapter_versions" => [],
            "current_version" => 1
          }
        end

      {:error, _} ->
        # Default structure for error case - current_version = 1
        %{
          "id" => section_id,
          "title" => "",
          "chapter_info" => "",
          "chapter_text" => "",
          "chapter_number" => "",
          "active_meta_info" => %{},
          "chapter_versions" => [],
          "current_version" => 1
        }
    end
  end

  @doc """
  Saves chapter metadata and content.
  """
  def save_tab_chapter_info_to_db(socket, %{category: "chapters", section_id: section_id} = tab) do
    # Ensure active_meta_info exists with default empty map
    active_meta_info = Map.get(tab, :active_meta_info, %{})

    # Get the content to check its token length
    content = tab.content

    # Check token length of content to determine if it's a heading-only chapter
    token_length = estimate_token_length(content)

    # Determine chapter type based on token length or title
    chapter_type =
      if token_length < 20 do
        "heading_only"
      else
        determine_chapter_type(tab.label)
      end

    # Get existing chapter to access version information
    existing_chapter = get_existing_chapter(socket.assigns.report_id, section_id)

    # Get current version information to update the type
    current_version_index = Map.get(existing_chapter, "current_version", 1)
    chapter_versions = Map.get(existing_chapter, "chapter_versions", [])

    # Get the summary from tab only if it's explicitly provided
    tab_summary = Map.get(tab, :summary)

    # Update the chapter type in the current version
    updated_versions =
      if length(chapter_versions) > 0 do
        Enum.map(chapter_versions, fn version ->
          if Map.get(version, "version") == current_version_index do
            # Only update type and keep the existing summary
            # unless we're explicitly updating content
            current_summary = Map.get(version, "summary", "")

            # Only use tab_summary if provided (content is being updated)
            # Otherwise keep the existing summary
            summary_to_use = if tab_summary != nil, do: tab_summary, else: current_summary

            version
            |> Map.put("type", chapter_type)
            |> Map.put("summary", summary_to_use)
          else
            version
          end
        end)
      else
        # If no versions exist, create a default one with the type
        [
          %{
            "version" => 1,
            "plain_content" => content,
            "formatted_content" => create_default_formatted_content(content),
            "summary" => tab_summary || "",
            "type" => chapter_type,
            "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        ]
      end

    Report.update_report_section(
      socket.assigns.report_id,
      "chapters",
      section_id,
      %{
        id: section_id,
        title: tab.label,
        chapter_info: Map.get(tab, :chapter_info, ""),
        chapter_text: content,
        chapter_number: Map.get(tab, :chapter_number, ""),
        active_meta_info: active_meta_info,
        # Remove type from the chapter root level
        chapter_versions: updated_versions
      }
    )
  end

  def save_tab_chapter_info_to_db(_, _), do: nil

  @doc """
  Handles person-related data.
  """
  def save_tab_person_info_to_db(socket, %{category: "parties", section_id: section_id} = tab) do
    save_party_statements_to_db(socket, tab)
  end

  def save_tab_person_info_to_db(_, _), do: nil

  @doc """
  Saves key-value pairs for general sections.
  """
  def save_general_section_to_db(socket, %{
        category: "general",
        section_id: section_id,
        content: content
      }) do
    pairs = parse_key_value_pairs(content)

    Report.update_report_section(
      socket.assigns.report_id,
      "general",
      section_id,
      pairs
    )
  end

  def save_general_section_to_db(_, _), do: nil

  @doc """
  Specifically handles party statements.
  """
  def save_party_statements_to_db(socket, %{category: "parties", section_id: section_id} = tab) do
    Logger.info("Saving party statements for section ID: #{section_id}")

    # Use a more robust way to extract statements from the tab
    person_statements_json = Map.get(tab, :person_statements, "[]")
    Logger.debug("Raw person statements JSON: #{inspect(person_statements_json)}")

    person_statements = parse_person_statements(person_statements_json)
    analysis_statements = parse_analysis_statements(Map.get(tab, :analysis_statements, "[]"))

    # Add detailed debug info about the data structures
    Logger.debug("Parsed person statements: #{inspect(person_statements)}")
    Logger.debug("Person statement IDs: #{inspect(Enum.map(person_statements, & &1["id"]))}")

    # Verify the section_id and tab.id to make sure we're updating the right document
    Logger.debug("Using section_id: #{section_id}, tab.id: #{tab.id}")

    # Prepare the update data with string keys for MongoDB
    update_data = %{
      "id" => section_id,
      "title" => tab.label,
      "person_statements" => person_statements,
      "analysis_statements" => analysis_statements
    }

    # Log the exact data being sent to MongoDB
    # Logger.debug("MongoDB update data: #{inspect(update_data)}")

    # Call the update function with detailed error handling
    result =
      Report.update_report_section(
        socket.assigns.report_id,
        "parties",
        section_id,
        update_data
      )

    case result do
      {:ok, message} ->
        Logger.info("Successfully saved party statements to MongoDB: #{message}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to save party statements: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def save_party_statements_to_db(_, _), do: nil

  @doc """
  Batch operation for saving all tab content.
  """
  def save_all_tabs_content(socket) do
    content_tabs = Enum.filter(socket.assigns.tabs, &(&1.id != "new_tab"))

    Enum.each(content_tabs, fn tab ->
      save_tab_content_to_db(socket, tab)
    end)
  end

  @doc """
  Loads appropriate content based on tab type.
  """
  def load_content_from_db(socket, tab, item_id, category) do
    # First ensure tab has all the required fields for backward compatibility
    # This is needed before we do any database operations
    tab = ensure_backward_compatibility(tab, category)

    case Report.get_report(socket.assigns.report_id) do
      {:ok, report} ->
        case category do
          "general" ->
            general_data = Map.get(report, "general", %{})
            section_data = Map.get(general_data, item_id, [])

            content = if is_list(section_data), do: Jason.encode!(section_data), else: "[]"
            %{tab | content: content}

          "chapters" ->
            chapters = Map.get(report, "chapters", [])
            chapter = Enum.find(chapters, fn ch -> Map.get(ch, "id") == item_id end)

            if chapter do
              # Ensure backward compatibility for active_meta_info
              active_meta_info = Map.get(chapter, "active_meta_info", %{})

              # Get chapter versions or create default structure
              chapter_versions = Map.get(chapter, "chapter_versions", [])

              # Get current version or default to the last one
              current_version = Map.get(chapter, "current_version", length(chapter_versions))

              # Find the version data
              version_data =
                if Enum.empty?(chapter_versions) do
                  # Handle legacy data with no versions
                  %{
                    "version" => 1,
                    "plain_content" => Map.get(chapter, "chapter_text", ""),
                    "formatted_content" =>
                      create_default_formatted_content(Map.get(chapter, "chapter_text", ""))
                  }
                else
                  # Find the specific version
                  version =
                    Enum.find(
                      chapter_versions,
                      List.last(chapter_versions),
                      fn v -> Map.get(v, "version") == current_version end
                    )

                  # Ensure it has all required fields
                  version
                  |> Map.put_new(
                    "plain_content",
                    Map.get(version, "plain_content", Map.get(chapter, "chapter_text", ""))
                  )
                  |> Map.put_new(
                    "formatted_content",
                    create_default_formatted_content(Map.get(version, "plain_content", ""))
                  )
                end

              # Parse stored formatted_content if it's JSON, else keep map or fallback
              raw_fc = Map.get(version_data, "formatted_content")
              # IO.inspect(raw_fc, label: "Raw formatted content after loading from DB")

              formatted =
                cond do
                  # If formatted_content is a string (JSON), parse it
                  is_binary(raw_fc) ->
                    case Jason.decode(raw_fc) do
                      {:ok, decoded} ->
                        # Ensure we're using the content structure correctly
                        if is_map(decoded) && Map.has_key?(decoded, "type") &&
                             Map.has_key?(decoded, "content") do
                          # Valid TipTap structure - sanitize selection lists
                          sanitize_selection_lists(decoded)
                        else
                          # Create default from plain content if structure is wrong
                          Logger.warn("Formatted content has invalid structure, regenerating")
                          create_default_formatted_content(version_data["plain_content"] || "")
                        end

                      _ ->
                        create_default_formatted_content(version_data["plain_content"] || "")
                    end

                  # If formatted_content is a map (already parsed), ensure it has correct structure and sanitize selection lists
                  is_map(raw_fc) ->
                    if Map.has_key?(raw_fc, "type") && Map.has_key?(raw_fc, "content") do
                      # Valid structure, but needs sanitization for selection lists
                      sanitize_selection_lists(raw_fc)
                    else
                      # Invalid structure, regenerate
                      Logger.warn(
                        "Formatted content has invalid structure (as map), regenerating"
                      )

                      create_default_formatted_content(version_data["plain_content"] || "")
                    end

                  # Default case - no formatted_content
                  true ->
                    create_default_formatted_content(version_data["plain_content"] || "")
                end

              # IO.inspect(formatted, label: "Formatted content after parsing")

              # Attach detailed diagnostic info to help debugging
              logged_plain = Map.get(version_data, "plain_content", "[NO PLAIN CONTENT]")
              extract_short = String.slice(logged_plain, 0, 30)

              # Debug output that shows relevant information about the loaded content
              IO.puts("Loaded chapter content (version #{current_version}): #{extract_short}...")

              # IO.inspect(formatted, label: "Formatted content structure")

              # Build the updated tab with all version data
              %{
                tab
                | content: Map.get(version_data, "plain_content", ""),
                  formatted_content: formatted,
                  chapter_info: Map.get(chapter, "chapter_info", ""),
                  chapter_number: Map.get(chapter, "chapter_number", ""),
                  active_meta_info: active_meta_info,
                  summary: Map.get(version_data, "summary", ""),
                  label: Map.get(chapter, "title", tab.label),
                  chapter_versions: chapter_versions,
                  current_version: current_version
              }
            else
              # Return original tab (which already has defaults set by ensure_backward_compatibility)
              tab
            end

          "parties" ->
            parties = Map.get(report, "parties", [])
            party = Enum.find(parties, fn p -> Map.get(p, "id") == item_id end)

            if party do
              # Handle the new data structure
              person_statements = Map.get(party, "person_statements", [])
              analysis_statements = Map.get(party, "analysis_statements", [])

              %{
                tab
                | content: "",
                  person_statements: Jason.encode!(person_statements),
                  analysis_statements: Jason.encode!(analysis_statements),
                  label: Map.get(party, "title", tab.label)
              }
            else
              # Initialize empty for new parties
              %{
                tab
                | content: "",
                  person_statements: "[]",
                  analysis_statements: "[]"
              }
            end

          _ ->
            tab
        end

      {:error, _} ->
        # Just return the tab with defaults already set
        tab
    end
  end

  # Helper function to ensure a tab has all required fields for backward compatibility
  defp ensure_backward_compatibility(tab, category) do
    # First add basic fields that should be present in all tabs
    tab =
      tab
      |> Map.put_new(:active_meta_info, %{})
      # Always ensure content exists for all tab types
      |> Map.put_new(:content, "")
      # Always default to writable mode
      |> Map.put_new(:read_only, false)

    # Add category-specific fields
    case category do
      "chapters" ->
        tab
        |> Map.put_new(:chapter_number, "")
        |> Map.put_new(:chapter_info, "")
        |> Map.put_new(:summary, "")
        |> Map.put_new(:formatted_content, nil)
        |> Map.put_new(:chapter_versions, [])
        |> Map.put_new(:current_version, 0)

      "parties" ->
        tab
        |> Map.put_new(:person_statements, "[]")
        |> Map.put_new(:analysis_statements, "[]")

      _ ->
        tab
    end
  end

  defp formatted_empty?(%{"content" => [%{"content" => [%{"text" => ""}]}]}), do: true
  defp formatted_empty?(_), do: false

  @doc """
  Retrieves and formats metadata from report.
  """
  def get_combined_metadata(report_id) do
    case Report.get_report(report_id) do
      {:ok, report} ->
        general_data = Map.get(report, "general", %{})
        basic_info = Map.get(general_data, "basic_info", [])
        device_info = Map.get(general_data, "device_info", [])

        (basic_info ++ device_info)
        |> Enum.reduce(%{}, fn item, acc ->
          case item do
            %{"key" => key, "value" => value} when key != "" ->
              Map.put(acc, key, value)

            _ ->
              acc
          end
        end)

      {:error, _} ->
        %{
          basic_info: %{},
          device_info: %{},
          parties:
            %{
              # Initialize with empty maps for parties
            }
        }
    end
  end

  def get_previous_contents(report_id, current_chapter_number, mode) do
    # IO.inspect(mode, label: "Mode in get_previous_contents")

    previous_contents_map =
      case mode do
        :summaries ->
          PreviousContent.get_previous_summaries(report_id, current_chapter_number)

        :full_chapters ->
          PreviousContent.get_previous_chapters(report_id, current_chapter_number)
      end

    previous_contents_map
  end

  @doc """
  Parse statements JSON into Elixir data structure with titles.
  Returns an empty list for empty or invalid input.
  """
  def parse_statements_with_titles(""), do: []
  def parse_statements_with_titles(nil), do: []

  def parse_statements_with_titles(content) do
    case Jason.decode(content) do
      {:ok, statements} when is_list(statements) ->
        Enum.with_index(statements)
        |> Enum.map(fn
          {%{"title" => title, "content" => content}, _} ->
            %{"title" => title, "content" => content}

          {content, index} when is_binary(content) ->
            %{"title" => "Aussage #{index + 1}", "content" => content}

          {other, index} ->
            Logger.warning("Unexpected statement format: #{inspect(other)}")
            %{"title" => "Aussage #{index + 1}", "content" => ""}
        end)

      _ ->
        []
    end
  end

  @doc """
  Parse person statements from JSON into Elixir data structure with ID.
  """
  def parse_person_statements(""), do: []
  def parse_person_statements(nil), do: []

  def parse_person_statements(content) do
    case Jason.decode(content) do
      {:ok, statements} when is_list(statements) ->
        Enum.map(statements, fn
          %{"id" => id, "content" => content} when is_integer(id) ->
            %{"id" => id, "content" => content}

          %{"title" => title, "content" => content} ->
            id = extract_id_from_title(title)
            %{"id" => id, "content" => content}

          content when is_binary(content) ->
            %{"id" => 1, "content" => content}

          other ->
            Logger.warning("Unexpected person statement format: #{inspect(other)}")
            %{"id" => 1, "content" => ""}
        end)

      _ ->
        []
    end
  end

  @doc """
  Parse analysis statements from JSON into Elixir data structure with ID and related_to.
  """
  def parse_analysis_statements(""), do: []
  def parse_analysis_statements(nil), do: []

  def parse_analysis_statements(content) do
    case Jason.decode(content) do
      {:ok, statements} when is_list(statements) ->
        Enum.with_index(statements)
        |> Enum.map(fn
          {%{"id" => id, "related_to" => related_to, "content" => content}, _}
          when is_integer(id) ->
            %{"id" => id, "related_to" => related_to, "content" => content}

          {%{"title" => title, "content" => content}, index} ->
            related_to = extract_id_from_title(title)
            %{"id" => index + 1, "related_to" => related_to, "content" => content}

          {content, index} when is_binary(content) ->
            %{"id" => index + 1, "related_to" => 1, "content" => content}

          {other, index} ->
            Logger.warning("Unexpected analysis statement format: #{inspect(other)}")
            %{"id" => index + 1, "related_to" => 1, "content" => ""}
        end)

      _ ->
        []
    end
  end

  @doc """
  Get person statements in a simple format for the UI.
  """
  def get_person_statements_for_ui(content) do
    parse_person_statements(content)
  end

  @doc """
  Get analysis statements in a simple format for the UI.
  """
  def get_analysis_statements_for_ui(content) do
    parse_analysis_statements(content)
  end

  defp extract_id_from_title(title) do
    case Regex.run(~r/(\d+)/, title) do
      [_, num] ->
        case Integer.parse(num) do
          {int_num, _} -> int_num
          :error -> 1
        end

      _ ->
        1
    end
  end

  @doc """
  Parse statements JSON into Elixir data structure.
  Returns an empty list for empty or invalid input.
  """
  def parse_statements(""), do: []
  def parse_statements(nil), do: []

  def parse_statements(content) do
    case Jason.decode(content) do
      {:ok, statements} when is_list(statements) ->
        Enum.map(statements, fn
          %{"title" => _title, "content" => content} -> content
          content when is_binary(content) -> content
          _ -> ""
        end)

      _ ->
        []
    end
  end

  @doc """
  Parse key-value pairs JSON into Elixir data structure.
  Returns an empty list for empty or invalid input.
  """
  def parse_key_value_pairs(""), do: []
  def parse_key_value_pairs(nil), do: []

  def parse_key_value_pairs(content) do
    case Jason.decode(content) do
      {:ok, pairs} when is_list(pairs) ->
        Enum.map(pairs, fn pair ->
          pair
          |> Map.put_new("key", "")
          |> Map.put_new("value", "")
        end)

      _ ->
        []
    end
  end

  @doc """
  Saves the metadata information (active_meta_info) for a tab to the database
  """
  def save_tab_meta_info_to_db(socket, tab) do
    report_id = socket.assigns.report_id
    section_id = tab.section_id
    category = tab.category

    if category == "chapters" do
      current_chapter = get_existing_chapter(report_id, section_id)
      active_meta_info = Map.get(tab, :active_meta_info, %{})

      Logger.info("Saving metadata for chapter #{section_id} in report #{report_id}")
      Logger.debug("Metadata content: #{inspect(active_meta_info)}")

      case Report.update_report_section(report_id, category, section_id, %{
             "active_meta_info" => active_meta_info
           }) do
        {:ok, _} ->
          Logger.info("Successfully saved metadata for chapter #{section_id}")
          :ok

        {:error, reason} ->
          Logger.error("Failed to save metadata: #{reason}")
          {:error, reason}
      end
    else
      Logger.info("Skipping metadata save for non-chapter tab")
      :ok
    end
  end

  def get_combined_metadata(report_id) do
    case Report.get_report(report_id) do
      {:ok, report} ->
        general_data = Map.get(report, "general", %{})
        basic_info = get_key_value_pairs_from_section(general_data, "basic_info")
        device_info = get_key_value_pairs_from_section(general_data, "device_info")
        parties = Map.get(report, "parties", [])
        party_data = extract_party_data_for_metadata(parties)

        %{
          basic_info: basic_info,
          device_info: device_info,
          parties: party_data
        }

      {:error, reason} ->
        Logger.error("Error fetching report metadata: #{reason}")
        %{basic_info: %{}, device_info: %{}, parties: %{}}
    end
  end

  defp get_key_value_pairs_from_section(data, section_name) do
    section_data = Map.get(data, section_name, [])

    section_data
    |> Enum.reduce(%{}, fn item, acc ->
      case item do
        %{"key" => key, "value" => value} when key != "" ->
          Map.put(acc, key, value)

        _ ->
          acc
      end
    end)
  end

  defp extract_party_data_for_metadata(parties) do
    parties
    |> Enum.reduce(%{}, fn party, acc ->
      title = Map.get(party, "title", "Unbekannt")

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

      if Enum.empty?(person_statements) and Enum.empty?(analysis_statements) do
        acc
      else
        Map.put(acc, title, %{
          person_statements: person_statements,
          analysis_statements: analysis_statements
        })
      end
    end)
  end

  defp is_button_active?(active_meta_info, section, key) do
    section_data =
      case active_meta_info do
        meta when is_map(meta) -> Map.get(meta, section, %{})
        _ -> %{}
      end

    Map.has_key?(section_data, key)
  end

  def estimate_token_length(content) do
    char_count = String.length(content)
    trunc(Float.ceil(char_count / 3.5, 1))
  end

  # Add this improved helper function to safely extract the text from formatted_content
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
        Logger.error("Error extracting text from formatted content: #{inspect(e)}")
        nil
    end
  end

  # Convert plain text to TipTap document format
  # Updated to use proper hardBreak nodes instead of relying on newlines in text
  def convert_text_to_tiptap(text) when is_binary(text) do
    # Split text into segments based on newlines
    segments = String.split(text, "\n", trim: false)

    # Process each segment, adding hardBreak nodes between them
    content_nodes =
      segments
      |> Enum.with_index()
      |> Enum.flat_map(fn {segment, idx} ->
        is_last = idx == length(segments) - 1

        # For each segment, create a text node followed by hardBreak node if not last
        text_node = %{"type" => "text", "text" => segment}

        if is_last do
          [text_node]
        else
          # Use proper hardBreak node
          [
            text_node,
            %{"type" => "hardBreak"}
          ]
        end
      end)

    # Create the complete document
    %{
      "type" => "doc",
      "content" => [
        %{
          "type" => "paragraph",
          "content" => content_nodes
        }
      ]
    }
  end

  @doc """
  Ensures selection lists in formatted content are properly structured.
  Handles both the old format (list with marks) and the new format (selectionList node).
  Returns the updated formatted content with normalized selection lists.
  """
  def sanitize_selection_lists(formatted_content) when is_map(formatted_content) do
    case formatted_content do
      %{"content" => content} when is_list(content) ->
        # Process each top-level node
        updated_content =
          Enum.map(content, fn node ->
            case node do
              # Handle the old format: list with coloredEntity marks
              %{"type" => "list", "marks" => marks} when is_list(marks) ->
                selection_mark =
                  Enum.find(marks, fn mark ->
                    mark["type"] == "coloredEntity" &&
                      get_in(mark, ["attrs", "entityType"]) == "selection_list"
                  end)

                if selection_mark do
                  # Convert to the new selectionList format
                  entity_list = get_in(selection_mark, ["attrs", "entityList"]) || []

                  %{
                    "type" => "selectionList",
                    "attrs" => %{
                      "entityList" => entity_list
                    }
                  }
                else
                  node
                end

              # Handle any other node type
              _ ->
                node
            end
          end)

        # Return the updated content
        Map.put(formatted_content, "content", updated_content)

      # If there's no content array, return as is
      _ ->
        formatted_content
    end
  end

  # Fallback for nil or non-map inputs
  def sanitize_selection_lists(nil), do: nil
  def sanitize_selection_lists(other), do: other

  @doc """
  Checks if a formatted content contains correction elements (selection lists, replacements, alternatives).
  Returns true if correction elements are found, false otherwise.
  """
  def has_correction_elements?(formatted_content) when is_map(formatted_content) do
    # Check for top-level selectionList
    has_selection_list = check_for_selection_list(formatted_content)

    # Check for replacement/alternative marks in content
    has_replacements = check_for_replacements_or_alternatives(formatted_content)

    # Return true if either condition is met
    has_selection_list || has_replacements
  end

  def has_correction_elements?(nil), do: false
  def has_correction_elements?(_), do: false

  # Helper to check for selectionList nodes
  defp check_for_selection_list(%{"content" => content}) when is_list(content) do
    Enum.any?(content, fn node ->
      case node do
        %{"type" => "selectionList"} -> true
        _ -> false
      end
    end)
  end

  defp check_for_selection_list(_), do: false

  # Helper to check for replacement or alternative marks - recursively searches content
  defp check_for_replacements_or_alternatives(%{"content" => content}) when is_list(content) do
    Enum.any?(content, fn node ->
      case node do
        # Check for marks at this level
        %{"marks" => marks} when is_list(marks) ->
          Enum.any?(marks, fn mark ->
            case mark do
              # Look for explicit replacement or alternative marks
              %{"type" => mark_type} when mark_type in ["replacement", "alternative"] ->
                true

              # Look for coloredEntity marks with entityType attribute
              %{"type" => "coloredEntity", "attrs" => attrs} when is_map(attrs) ->
                entity_type = Map.get(attrs, "entityType", "")
                entity_type in ["alternatives", "replacement"]

              # No match
              _ ->
                false
            end
          end)

        # Check for content at this level that might have marks
        %{"content" => node_content} when is_list(node_content) ->
          check_for_replacements_or_alternatives(%{"content" => node_content})

        # No matches at this level
        _ ->
          false
      end
    end)
  end

  defp check_for_replacements_or_alternatives(_), do: false

  @doc """
  Checks if the tab with the given ID has correction elements.
  Returns true if correction elements are found, false otherwise.
  """
  def check_correction_mode(socket, tab_id) do
    # Find the tab
    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab && Map.has_key?(tab, :formatted_content) && tab.formatted_content != nil do
      # Check if correction elements exist
      correction_mode = has_correction_elements?(tab.formatted_content)
      Logger.info("Checking correction mode for tab #{tab_id}: #{correction_mode}")
      correction_mode
    else
      # Default to false if no tab or formatted content
      false
    end
  end

  @doc """
  Extracts chapters suitable for summarization.
  Returns a map with chapter_id -> version -> plain_content structure,
  only including regular chapters without correction elements and with empty summaries.
  """
  def extract_chapters_for_summary_creation(socket) do
    report_id = socket.assigns.report_id

    # Get all chapters
    all_chapters = get_all_chapters(report_id)

    # Initialize an empty map to store the results
    chapters_for_summarization = %{}

    # Process each chapter
    Enum.reduce(all_chapters, chapters_for_summarization, fn chapter, acc ->
      chapter_id = Map.get(chapter, "id")

      # Get chapter versions
      chapter_versions = Map.get(chapter, "chapter_versions", [])

      # Filter for regular chapters without correction mode and with empty summaries
      eligible_versions =
        Enum.filter(chapter_versions, fn version ->
          # Check if it's a regular chapter
          chapter_type = Map.get(version, "type", "")
          is_regular = chapter_type == "regular_chapter"

          # Check if summary is empty
          summary = Map.get(version, "summary", "")
          is_summary_empty = summary == "" || summary == nil

          # Check if it doesn't have correction elements
          formatted_content = Map.get(version, "formatted_content", nil)

          # Include only if it's a regular chapter with empty summary and no correction elements
          is_regular && is_summary_empty &&
            (formatted_content && !has_correction_elements?(formatted_content))
        end)

      # Add eligible versions to the accumulator
      version_map =
        Enum.reduce(eligible_versions, %{}, fn version, version_acc ->
          version_number = Map.get(version, "version", 1)
          plain_content = Map.get(version, "plain_content", "")

          Map.put(version_acc, version_number, %{
            plain_content: plain_content,
            chapter_id: chapter_id
          })
        end)

      # Only add to results if we have eligible versions
      if map_size(version_map) > 0 do
        Map.put(acc, chapter_id, version_map)
      else
        acc
      end
    end)
  end

  @doc """
  Saves summaries back to their respective chapters and versions.
  Takes a map with the same structure as extract_chapters_for_summary_creation,
  but with an additional :summary field in each version's data.
  """
  def safe_summaries(socket, summary_map) do
    report_id = socket.assigns.report_id

    # Process each chapter in the summary map
    Enum.each(summary_map, fn {chapter_number, versions} ->
      # Process each version for this chapter
      Enum.each(versions, fn {version_number, version_data} ->
        # Extract needed data
        chapter_id = Map.get(version_data, :chapter_id)
        summary = Map.get(version_data, :summary, "")

        # Skip if we don't have a chapter_id or summary
        if chapter_id && summary && summary != "" do
          # Get the existing chapter
          existing_chapter = get_existing_chapter(report_id, chapter_id)

          # Get current version information
          chapter_versions = Map.get(existing_chapter, "chapter_versions", [])

          # Update the specific version with the summary
          updated_versions =
            Enum.map(chapter_versions, fn version ->
              if Map.get(version, "version") == version_number do
                # Update the summary in this version
                Map.put(version, "summary", summary)
              else
                version
              end
            end)

          # Update the chapter with new versions
          Report.update_report_section(
            report_id,
            "chapters",
            chapter_id,
            %{"chapter_versions" => updated_versions}
          )

          Logger.info("Saved summary for chapter #{chapter_number} version #{version_number}")
        end
      end)
    end)

    # Return success
    :ok
  end
end
