defmodule HaimedaCoreWeb.ReportsEditor.PreviousContent do
  alias HaimedaCore.Report
  alias HaimedaCore.MainController

  @doc """
  Retrieves previous chapter content.
  """
  def get_previous_summaries(report_id, current_chapter_number) do
    case Report.get_report(report_id) do
      {:ok, report} ->
        chapters = Map.get(report, "chapters", [])
        formatted_chapter_number = format_chapter_number(current_chapter_number)

        IO.inspect(formatted_chapter_number, label: "Formatted Chapter Number")

        if formatted_chapter_number && formatted_chapter_number != "" do
          # Find current chapter to get its position
          current_chapter = find_chapter_by_number(chapters, formatted_chapter_number)
          current_position = Map.get(current_chapter, "position", 1)

          # If position is 1 or not found, just return empty map as there are no previous chapters
          if current_position <= 1 do
            %{}
          else
            # Get all previous chapters based on position
            previous_chapters =
              chapters
              |> Enum.filter(fn chapter ->
                chapter_position = Map.get(chapter, "position", 0)
                chapter_position < current_position
              end)

            # Check if any regular chapter has an empty summary and create summaries if needed
            chapters_with_summaries =
              Enum.map(previous_chapters, fn chapter ->
                # Get current version's summary and type
                current_version_idx = Map.get(chapter, "current_version", 1)
                chapter_versions = Map.get(chapter, "chapter_versions", [])
                current_version = find_version_by_number(chapter_versions, current_version_idx)

                # Get chapter type from current version only
                chapter_type =
                  if current_version do
                    Map.get(current_version, "type", "regular_chapter")
                  else
                    # Default to regular_chapter if no version exists
                    "regular_chapter"
                  end

                # Check if summary exists in current version
                version_summary =
                  if current_version, do: Map.get(current_version, "summary"), else: nil

                if chapter_type == "regular_chapter" &&
                     (version_summary == nil || version_summary == "") do
                  # Generate summary for chapter with empty summary
                  # Get the content to summarize
                  content_to_summarize =
                    if current_version do
                      Map.get(current_version, "plain_content", "")
                    else
                      # Default to empty string if no version exists
                      ""
                    end

                  # Only generate summary if there's actual content
                  if content_to_summarize != "" do
                    # Generate summary using MainController
                    summary = MainController.create_summary(self(), content_to_summarize)

                    # Save the generated summary to MongoDB
                    if current_version do
                      updated_version = Map.put(current_version, "summary", summary)

                      updated_versions =
                        chapter_versions
                        |> Enum.map(fn version ->
                          if Map.get(version, "version") == current_version_idx,
                            do: updated_version,
                            else: version
                        end)

                      # Update the chapter in MongoDB
                      Report.update_report_section(
                        report_id,
                        "chapters",
                        Map.get(chapter, "id"),
                        %{"chapter_versions" => updated_versions}
                      )

                      # Return updated chapter with new summary
                      Map.put(chapter, "chapter_versions", updated_versions)
                    else
                      # If no version exists, create one with the summary
                      new_version = %{
                        "version" => 1,
                        "plain_content" => content_to_summarize,
                        "summary" => summary,
                        "type" => "heading_only",
                        "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
                      }

                      new_versions = [new_version]

                      # Update the chapter in MongoDB
                      Report.update_report_section(
                        report_id,
                        "chapters",
                        Map.get(chapter, "id"),
                        %{
                          "chapter_versions" => new_versions,
                          "current_version" => 1
                        }
                      )

                      # Return updated chapter
                      chapter
                      |> Map.put("chapter_versions", new_versions)
                      |> Map.put("current_version", 1)
                    end
                  else
                    chapter
                  end
                else
                  chapter
                end
              end)

            # Build content map based on chapter types, but exclude heading_only chapters
            chapters_with_summaries
            |> Enum.sort_by(fn chapter -> Map.get(chapter, "position", 0) end)
            |> Enum.with_index(1)
            |> Enum.map(fn {chapter, idx} ->
              # Get the current version index and all versions
              current_version_idx = Map.get(chapter, "current_version", 1)
              chapter_versions = Map.get(chapter, "chapter_versions", [])

              # Find the current version data
              current_version = find_version_by_number(chapter_versions, current_version_idx)

              # Get chapter type exclusively from current version
              chapter_type =
                if current_version do
                  Map.get(current_version, "type", "regular_chapter")
                else
                  # Default to heading_only if no version exists
                  "heading_only"
                end

              chapter_number = Map.get(chapter, "chapter_number", "")
              title = Map.get(chapter, "title", "")

              content =
                case chapter_type do
                  # For regular chapters, use summary if available
                  "regular_chapter" ->
                    if current_version && Map.get(current_version, "summary") &&
                         Map.get(current_version, "summary") != "" do
                      Map.get(current_version, "summary")
                    else
                      # If no summary, use plain_content
                      if current_version do
                        Map.get(current_version, "plain_content", "")
                      else
                        ""
                      end
                    end

                  # For technical chapters, always use full chapter text
                  "technical" ->
                    if current_version do
                      Map.get(current_version, "plain_content", "")
                    else
                      ""
                    end

                  # For heading-only chapters, use empty string
                  "heading_only" ->
                    ""

                  # Default fallback - use summary if available, otherwise plain_content
                  _ ->
                    if current_version && Map.get(current_version, "summary") &&
                         Map.get(current_version, "summary") != "" do
                      Map.get(current_version, "summary")
                    else
                      # If no summary, use plain_content
                      if current_version do
                        Map.get(current_version, "plain_content", "")
                      else
                        ""
                      end
                    end
                end

              {idx,
               %{
                 chapter_num: chapter_number,
                 sanitized_filename: title,
                 type: chapter_type,
                 level: "sub_chapter",
                 content: content
               }}
            end)
            # Filter out heading_only chapters
            |> Enum.reject(fn {_, entry} -> entry.type == "heading_only" end)
            # Renumber the indices to ensure they remain consecutive
            |> Enum.sort_by(fn {idx, _} -> idx end)
            |> Enum.with_index(1)
            |> Enum.map(fn {{_, content}, new_idx} -> {new_idx, content} end)
            |> Enum.into(%{})
          end
        else
          %{}
        end

      {:error, _} ->
        %{}
    end
  end

  # Helper function to find a chapter by its chapter number
  defp find_chapter_by_number(chapters, chapter_number) do
    Enum.find(chapters, %{}, fn chapter ->
      Map.get(chapter, "chapter_number", "") == chapter_number
    end)
  end

  # Helper function to find a version by its version number
  defp find_version_by_number(versions, version_number) do
    Enum.find(versions, nil, fn version ->
      Map.get(version, "version") == version_number
    end)
  end

  # Update in the get_previous_chapters function to read chapter type from versions
  def get_previous_chapters(report_id, current_chapter_number) do
    case Report.get_report(report_id) do
      {:ok, report} ->
        chapters = Map.get(report, "chapters", [])
        formatted_chapter_number = format_chapter_number(current_chapter_number)

        if formatted_chapter_number && formatted_chapter_number != "" do
          # Find current chapter to get its position
          current_chapter = find_chapter_by_number(chapters, formatted_chapter_number)
          current_position = Map.get(current_chapter, "position", 1)

          # If position is 1, return empty map
          if current_position <= 1 do
            %{}
          else
            # Get all previous chapters based on position
            previous_content_list =
              chapters
              |> Enum.filter(fn chapter ->
                chapter_position = Map.get(chapter, "position", 0)
                chapter_position < current_position
              end)
              |> Enum.sort_by(fn chapter -> Map.get(chapter, "position", 0) end)
              |> Enum.map(fn chapter ->
                # Get the current version index and all versions
                current_version_idx = Map.get(chapter, "current_version", 1)
                chapter_versions = Map.get(chapter, "chapter_versions", [])

                # Find the current version data
                current_version = find_version_by_number(chapter_versions, current_version_idx)

                # Get chapter type exclusively from current version
                chapter_type =
                  if current_version do
                    Map.get(current_version, "type", "regular_chapter")
                  else
                    # Default to regular_chapter if no version exists
                    "regular_chapter"
                  end

                chapter_number = Map.get(chapter, "chapter_number", "")
                title = Map.get(chapter, "title", "")

                # Get content based on chapter type (full text for all except heading_only)
                content =
                  case chapter_type do
                    "heading_only" ->
                      ""

                    _ ->
                      if current_version do
                        # Use plain_content from current version
                        Map.get(current_version, "plain_content", "")
                      else
                        # Default to empty string if no version exists
                        ""
                      end
                  end

                %{
                  position: Map.get(chapter, "position", 0),
                  sanitized_chapter_num: chapter_number,
                  sanitized_filename: title,
                  chapter_type: chapter_type,
                  content: content,
                  chapter_num: chapter_number
                }
              end)

            # Pass to get_level_of_chapter to determine hierarchy
            get_level_of_chapter(previous_content_list, formatted_chapter_number)
          end
        else
          %{}
        end

      {:error, _} ->
        %{}
    end
  end

  def get_level_of_chapter(previous_content_list, current_chapter_num) do
    # Determine chapter types (main_chapter or sub_chapter) based on chapter number relationships
    previous_content = determine_chapter_types(previous_content_list)

    # If category is "only_summaries", set all types in previous_content to "sub_chapter"
    previous_content =
      update_parent_chapters_types(previous_content, current_chapter_num)

    # Filter out heading-only chapters that have type sub_chapter or main_chapter_no_content
    filtered_content =
      previous_content
      |> Enum.reject(fn {_, content} ->
        # Get chapter type from original list to check if it's heading_only
        original_entry =
          Enum.find(previous_content_list, fn entry ->
            entry.chapter_num == content.chapter_num
          end)

        is_heading_only = original_entry && original_entry.chapter_type == "heading_only"

        # Remove if it's heading_only AND has a type we want to filter
        is_heading_only &&
          (content.level == "sub_chapter" ||
             content.level == "main_chapter_no_content")
      end)

    # Renumber the indices to ensure they remain consecutive
    filtered_content
    |> Enum.sort_by(fn {idx, _} -> idx end)
    |> Enum.with_index(1)
    |> Enum.map(fn {{_, content}, new_idx} -> {new_idx, content} end)
    |> Map.new()
  end

  # Helper function to identify parent-child relationships and update parent chapter types
  defp update_parent_chapters_types(previous_content, current_chapter_num, debug \\ false) do
    # Get all chapter numbers and their indices - create map with chapter_num as key and idx as value
    chapter_nums_with_indices =
      previous_content
      |> Enum.map(fn {idx, content} -> {content.chapter_num, idx} end)
      |> Enum.into(%{})

    # Create a map to track which chapters have children
    chapters_with_children =
      previous_content
      |> Enum.reduce(%{}, fn {_, content}, acc ->
        chapter_num = content.chapter_num

        # If this is a multi-level chapter (contains a dot)
        if String.contains?(chapter_num, ".") do
          # Find its parent by taking everything before the last dot
          parent_num = chapter_num |> String.split(".") |> Enum.drop(-1) |> Enum.join(".")

          # Add this parent to the map of chapters with children
          Map.put(acc, parent_num, true)
        else
          acc
        end
      end)

    # First pass: Process all single-level chapters to identify direct parents of current chapter
    updated_content =
      Enum.reduce(previous_content, previous_content, fn {idx, content}, acc ->
        chapter_num = content.chapter_num
        current_type = Map.get(content, :level, "unknown")
        chapter_type = Map.get(content, :chapter_type, "unknown")

        # Determine if this chapter is a direct parent of the current chapter
        is_direct_parent = is_direct_parent?(chapter_num, current_chapter_num)

        if debug do
          IO.puts(
            "\nExamining previous chapter #{chapter_num} (current type: #{current_type}, chapter_type: #{chapter_type})"
          )

          IO.puts(
            "  Is direct parent of current chapter #{current_chapter_num}? #{is_direct_parent}"
          )
        end

        # Check if this is a single-level chapter that is a direct parent of current chapter
        if !String.contains?(chapter_num, ".") && is_direct_parent do
          if debug do
            IO.puts(
              "  Found direct parent: #{chapter_num} for current chapter: #{current_chapter_num}"
            )
          end

          # Determine the appropriate type based on the chapter type and current type
          new_type =
            cond do
              # For only_heading or heading_only chapters
              chapter_type == "only_heading" || chapter_type == "heading_only" ||
                current_type == "main_chapter_no_content" ||
                  current_type == "heading_only" ->
                "main_chapter_no_closing_no_content"

              # For other direct parents
              true ->
                "main_chapter_no_closing"
            end

          if debug do
            IO.puts("  Setting direct parent chapter #{chapter_num} to #{new_type}")
          end

          Map.put(acc, idx, Map.put(content, :level, new_type))
        else
          acc
        end
      end)

    # Second pass: Process multi-level chapters as before
    # Process each previous content entry
    Enum.reduce(previous_content, updated_content, fn {idx, content}, acc ->
      # Skip if this chapter was already processed in the first pass
      if Map.get(acc, idx) != content do
        # This chapter was already updated in first pass
        acc
      else
        chapter_num = content.chapter_num
        current_type = Map.get(content, :level, "unknown")
        chapter_type = Map.get(content, :chapter_type, "unknown")

        # For multi-level chapters (e.g., "3.1"), find and process their parent chapters
        new_acc =
          if String.contains?(chapter_num, ".") do
            # Process parent-child relationships for multi-level chapters
            parent_chapters = identify_parent_chapters(chapter_num, chapter_nums_with_indices)

            if length(parent_chapters) > 0 do
              if debug do
                IO.puts("  Found #{length(parent_chapters)} parent chapters for #{chapter_num}")
              end

              # Update parent chapter types
              Enum.reduce(parent_chapters, acc, fn {parent_idx, parent_num}, inner_acc ->
                parent_content = Map.get(inner_acc, parent_idx)

                if parent_content do
                  parent_current_type = Map.get(parent_content, :level, "unknown")
                  parent_chapter_type = Map.get(parent_content, :chapter_type, "unknown")
                  parent_is_direct_parent = is_direct_parent?(parent_num, current_chapter_num)
                  has_children = Map.has_key?(chapters_with_children, parent_num)

                  if debug do
                    IO.puts(
                      "    Parent #{parent_num} (type: #{parent_chapter_type}, current_type: #{parent_current_type})"
                    )

                    IO.puts("    Is direct parent of current chapter? #{parent_is_direct_parent}")
                    IO.puts("    Has children? #{has_children}")
                  end

                  # Determine type based on parent's type and relationship with current chapter
                  new_type =
                    cond do
                      # If parent already has no_content suffix, preserve it
                      String.contains?(parent_current_type, "no_content") ->
                        if parent_is_direct_parent do
                          "main_chapter_no_closing_no_content"
                        else
                          parent_current_type
                        end

                      # Only_heading type or heading_only
                      parent_content[:chapter_type] == "only_heading" ||
                        parent_content[:chapter_type] == "heading_only" ||
                          parent_current_type == "heading_only" ->
                        if parent_is_direct_parent do
                          "main_chapter_no_closing_no_content"
                        else
                          "main_chapter_no_content"
                        end

                      # Previously marked no_content types
                      parent_current_type == "main_chapter_no_content" ->
                        if parent_is_direct_parent do
                          "main_chapter_no_closing_no_content"
                        else
                          "main_chapter_no_content"
                        end

                      # Direct parent-child relationship
                      parent_is_direct_parent ->
                        "main_chapter_no_closing"

                      # Has children chapters - should be main_chapter_opening
                      has_children ->
                        "main_chapter_opening"

                      # Other cases - regular main chapter
                      true ->
                        "main_chapter"
                    end

                  if debug do
                    IO.puts("    Setting type to: #{new_type}")
                  end

                  Map.put(inner_acc, parent_idx, Map.put(parent_content, :level, new_type))
                else
                  inner_acc
                end
              end)
            else
              acc
            end
          else
            acc
          end

        # For single-level chapters (like "3"), determine type based on relationship with current chapter
        if !String.contains?(chapter_num, ".") &&
             (chapter_type == "only_heading" || chapter_type == "heading_only") do
          content_from_acc = Map.get(new_acc, idx)
          current_assigned_type = Map.get(content_from_acc, :level, "unknown")

          # Don't change types if they've already been set to no_closing variants in the first pass
          if String.contains?(current_assigned_type, "no_closing") do
            new_acc
          else
            # If not already processed as a main chapter but has only_heading type
            if !String.starts_with?(current_assigned_type, "main_chapter") do
              if debug do
                IO.puts(
                  "  Setting single-level chapter #{chapter_num} to main_chapter_no_content"
                )
              end

              Map.put(new_acc, idx, Map.put(content_from_acc, :level, "main_chapter_no_content"))
            else
              new_acc
            end
          end
        else
          # Check if this chapter has children
          has_children = Map.has_key?(chapters_with_children, chapter_num)
          content_from_acc = Map.get(new_acc, idx)
          current_assigned_type = Map.get(content_from_acc, :level, "unknown")

          # If it has children and is a main chapter but not opening/closing variant, update to opening
          if has_children && current_assigned_type == "main_chapter" do
            if debug do
              IO.puts("  Setting chapter with children #{chapter_num} to main_chapter_opening")
            end

            Map.put(new_acc, idx, Map.put(content_from_acc, :level, "main_chapter_opening"))
          else
            new_acc
          end
        end
      end
    end)
  end

  # Helper function to parse chapter number into a comparable numeric value
  defp parse_chapter_num(chapter_num) do
    chapter_num
    |> String.split(".")
    |> Enum.map(fn part ->
      case Integer.parse(part) do
        {num, _} -> num
        :error -> 0
      end
    end)
  end

  # Helper function to determine if a chapter is a direct parent of another
  # e.g., "4" is direct parent of "4.1" but not of "5.1"
  defp is_direct_parent?(parent_num, child_num) do
    String.starts_with?(child_num, "#{parent_num}.")
  end

  # Identify parent chapters of a given chapter number
  defp identify_parent_chapters(chapter_num, chapter_nums_with_indices) do
    parts = String.split(chapter_num, ".")

    if length(parts) <= 1 do
      # No parent chapters for top-level chapters
      []
    else
      # Generate all possible parent chapter numbers
      1..(length(parts) - 1)
      |> Enum.map(fn i ->
        # Create parent chapter number by taking i parts
        parent_num = Enum.take(parts, i) |> Enum.join(".")

        # Find index of this parent chapter if it exists (using direct map lookup)
        parent_idx = Map.get(chapter_nums_with_indices, parent_num)

        if parent_idx, do: {parent_idx, parent_num}, else: nil
      end)
      |> Enum.reject(&is_nil/1)
    end
  end

  # Determine if each chapter is a main_chapter or sub_chapter based on its relationship to the next chapter
  defp determine_chapter_types(chapter_list) do
    # Process items with next item context
    chapter_list
    |> Enum.with_index()
    |> Enum.map(fn {current_item, index} ->
      # Determine if this is the last item
      next_item =
        if index < length(chapter_list) - 1, do: Enum.at(chapter_list, index + 1), else: nil

      # Determine if this is a main chapter or sub-chapter
      chapter_type = determine_single_chapter_type(current_item, next_item)

      # Return chapter with its type
      Map.put(current_item, :chapter_hierarchy_type, chapter_type)
    end)
    |> Enum.with_index(1)
    |> Enum.map(fn {chapter, idx} ->
      {idx,
       %{
         content: chapter.content,
         level: chapter.chapter_hierarchy_type,
         chapter_num: format_chapter_number(chapter.sanitized_chapter_num),
         sanitized_filename: chapter.sanitized_filename
       }}
    end)
    |> Map.new()
  end

  # Determine if a chapter is a main_chapter or sub_chapter based on its relationship with the next chapter
  defp determine_single_chapter_type(current_item, next_item) do
    # Check if the current item is a heading-only chapter
    if current_item.chapter_type == "heading_only" do
      "main_chapter_no_content"
    else
      # If there's no next item, default to sub_chapter
      if next_item == nil do
        "sub_chapter"
      else
        current_num = current_item.chapter_num
        next_num = next_item.chapter_num

        # Compare chapter numbers to determine relationship
        compare_chapter_numbers(current_num, next_num)
      end
    end
  end

  # Compare chapter numbers to determine their relationship and proper chapter type
  defp compare_chapter_numbers(current_num, next_num) do
    # If either number is empty, they can't be related
    if current_num == "" || next_num == "" do
      "sub_chapter"
    else
      # Split chapter numbers into parts
      current_parts = String.split(current_num, ".")
      next_parts = String.split(next_num, ".")

      # Calculate level difference
      level_difference = calculate_level_difference(current_parts, next_parts)

      cond do
        # Main chapter that opens multiple subchapter levels
        level_difference < -1 ->
          # Determine how many levels are opened
          opening_levels = abs(level_difference)
          "main_chapter_opening" <> String.duplicate("_opening", opening_levels - 1)

        # Main chapter that opens one subchapter level
        level_difference == -1 ->
          "main_chapter_opening"

        # Subchapter that closes multiple levels up
        level_difference > 1 ->
          # Determine how many levels are closed
          closing_levels = level_difference
          "subchapter_closing" <> String.duplicate("_closing", closing_levels - 1)

        # Subchapter that closes one level up
        level_difference == 1 ->
          "subchapter_closing"

        # Same level but not sequential - changing from main_chapter to sub_chapter
        level_difference == 0 && !is_next_sequential_chapter(current_num, next_num) ->
          "sub_chapter"

        # Default - sequential chapters at same level
        true ->
          "sub_chapter"
      end
    end
  end

  # Calculate level difference between chapter numbers (positive: next is higher level, negative: next is lower level)
  defp calculate_level_difference(current_parts, next_parts) do
    # Calculate basic level difference based on number of parts
    basic_level_diff = length(current_parts) - length(next_parts)

    # Check if prefix match to refine the determination
    if basic_level_diff == 0 do
      # If same level, check if they share the same prefix except the last part
      prefix_current = Enum.drop(current_parts, -1)
      prefix_next = Enum.drop(next_parts, -1)

      if prefix_current == prefix_next do
        # Same branch, sequential chapters
        0
      else
        # Same level but different branch - determine if it's closing one branch and opening another
        common_prefix_length = find_common_prefix_length(current_parts, next_parts)

        # Calculate implicit level changes
        length(current_parts) - common_prefix_length - (length(next_parts) - common_prefix_length)
      end
    else
      # Different levels - check if they're related
      common_prefix_length = find_common_prefix_length(current_parts, next_parts)

      if common_prefix_length > 0 do
        # Related chapters, normal level difference applies
        basic_level_diff
      else
        # Completely different branches - treat as significant level change
        # If current has more parts, it's closing multiple levels
        # If next has more parts, it's opening multiple levels
        basic_level_diff
      end
    end
  end

  # Find length of common prefix between two chapter numbers
  defp find_common_prefix_length(parts1, parts2) do
    parts1
    |> Enum.zip(parts2)
    |> Enum.reduce_while(0, fn {a, b}, count ->
      if a == b, do: {:cont, count + 1}, else: {:halt, count}
    end)
  end

  # Check if next_num is the next sequential chapter after current_num (e.g., "2" -> "3" or "5.1" -> "5.2")
  defp is_next_sequential_chapter(current_num, next_num) do
    # Split both numbers by dots to get their parts
    current_parts = String.split(current_num, ".")
    next_parts = String.split(next_num, ".")

    # If they have different number of parts, they're not sequential at the same level
    if length(current_parts) != length(next_parts) do
      false
    else
      # Check if all parts except the last are identical
      {last_current, last_next} =
        if length(current_parts) > 1 do
          init_current = Enum.drop(current_parts, -1)
          init_next = Enum.drop(next_parts, -1)

          if init_current == init_next do
            {List.last(current_parts), List.last(next_parts)}
          else
            {nil, nil}
          end
        else
          {List.first(current_parts), List.first(next_parts)}
        end

      # If we could extract comparable parts
      if last_current != nil && last_next != nil do
        # Try to convert them to integers and check if they're sequential
        case {Integer.parse(last_current), Integer.parse(last_next)} do
          {{current_int, ""}, {next_int, ""}} ->
            next_int == current_int + 1

          _ ->
            false
        end
      else
        false
      end
    end
  end

  # Helper functions

  def compare_chapter_numbers_strings(num1, num2) do
    parts1 =
      num1
      |> String.trim()
      |> String.split(".")
      |> Enum.filter(&(&1 != ""))
      |> Enum.map(fn part ->
        case Integer.parse(part) do
          {num, _} -> num
          :error -> 0
        end
      end)

    parts2 =
      num2
      |> String.trim()
      |> String.split(".")
      |> Enum.filter(&(&1 != ""))
      |> Enum.map(fn part ->
        case Integer.parse(part) do
          {num, _} -> num
          :error -> 0
        end
      end)

    compare_parts(parts1, parts2)
  end

  # Add a public function version that returns boolean for simpler usage
  def chapter_number_less_than?(num1, num2) do
    compare_chapter_numbers_strings(num1, num2) == :lt
  end

  # Add a format_chapter_number_string function that handles string inputs
  def format_chapter_number_string(raw_chapter_num) when is_binary(raw_chapter_num) do
    raw_chapter_num
    |> to_string()
    |> String.trim_trailing(".")
  end

  def format_chapter_number_string(nil), do: ""

  # Ensure the current format_chapter_number function still works
  def format_chapter_number(num) when is_binary(num), do: format_chapter_number_string(num)

  defp compare_parts([], []), do: :eq
  defp compare_parts([], [_ | _]), do: :lt
  defp compare_parts([_ | _], []), do: :gt

  defp compare_parts([h1 | t1], [h2 | t2]) do
    cond do
      h1 < h2 -> :lt
      h1 > h2 -> :gt
      true -> compare_parts(t1, t2)
    end
  end

  # Format chapter number from float to proper string format (e.g., 5.21 -> 5.2.1)
  def format_chapter_number(num) when is_float(num) do
    # Convert float to string
    str_num = Float.to_string(num)

    # Check if it has decimal part that needs formatting
    if String.contains?(str_num, ".") do
      [whole, decimal] = String.split(str_num, ".")

      # If decimal part has multiple digits, insert dots
      formatted_decimal =
        if String.length(decimal) > 1 do
          decimal
          |> String.graphemes()
          |> Enum.join(".")
        else
          decimal
        end

      "#{whole}.#{formatted_decimal}"
    else
      str_num
    end
  end

  def format_chapter_number(num) when is_integer(num) do
    Integer.to_string(num)
  end

  def format_chapter_number(num) do
    "#{num}"
  end
end
