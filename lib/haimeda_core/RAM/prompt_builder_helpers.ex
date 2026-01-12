defmodule RAM.PromptBuilderHelpers do
  @path_ram_prompts Path.expand(
                      Path.join([Path.dirname(__DIR__), "external", "ram_prompts.json"])
                    )

  def extract_prompt_element(prompt_key, element) do
    key = "#{prompt_key}_#{element}"

    case File.read(@path_ram_prompts) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, json_data} ->
            Map.get(json_data, key)

          {:error, _reason} ->
            ""
        end

      {:error, _reason} ->
        ""
    end
  end

  def format_context_reports(context_snippet_template, context) when is_list(context) do
    # Process each report in the context list

    # First, count the total number of content items across all reports
    total_items =
      context
      |> Enum.map(fn report ->
        content_items = Map.get(report, :content, [])
        length(content_items)
      end)
      |> Enum.sum()

    # Use an agent to keep track of the current item number across function calls
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    result =
      context
      |> Enum.map(fn report ->
        # Get the report ID and format it nicely
        report_id = Map.get(report, :report_id, "unbekannt")
        formatted_report_id = reformate_report_id(report_id)

        # Get content items from the report
        content_items = Map.get(report, :content, [])

        # Format each content item into a snippet
        content_items
        |> Enum.map(fn item ->
          # Increment the counter for each item
          current_num = Agent.get_and_update(counter, fn count -> {count + 1, count + 1} end)

          # Extract chapter name and text
          chapter_name = Map.get(item, "chapter_name", "unbekannt")
          # Add item number to context info
          context_info =
            "#{current_num}/#{total_items} aus GUTACHTEN: #{formatted_report_id}, KAPITEL: #{chapter_name}"

          context_snippet_text = Map.get(item, "text", "")
          formatted_chapter_text = format_chapter_text(context_snippet_text)

          # Use the template to format this snippet
          EEx.eval_string(context_snippet_template,
            assigns: %{
              context_info: context_info,
              context_snippet: formatted_chapter_text
            }
          )
        end)
        # Join without additional newlines
        |> Enum.join("")
      end)
      # Join all reports without additional newlines
      |> Enum.join("")

    # Stop the agent when done
    Agent.stop(counter)

    result
  end

  # Handle empty or nil context
  def format_context_reports(_context_snippet_template, nil), do: ""
  def format_context_reports(_context_snippet_template, []), do: ""

  def format_context_mdb(context_snippet_template, context) when is_map(context) do
    # Flatten the map of tables into a list of {table_name, record} tuples
    flattened_records =
      Enum.flat_map(context, fn {table_name, records} ->
        Enum.map(records, fn record -> {table_name, record} end)
      end)

    # Count total items for numbering
    total_items = length(flattened_records)

    # Use an agent to keep track of the current item number
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    result =
      flattened_records
      |> Enum.map(fn {table_name, item_map} ->
        # Increment counter for each item
        current_num = Agent.get_and_update(counter, fn count -> {count + 1, count + 1} end)

        # Format the map content nicely with one key/value per line
        formatted_mdb_text =
          item_map
          |> Enum.map(fn {key, value} -> "#{key}: #{value}" end)
          |> Enum.join("\n")

        # Check if Gutachten-Nr exists and format it
        context_info =
          case Map.get(item_map, "Gutachten-Nr") do
            nil ->
              "#{current_num}/#{total_items} aus TABELLE #{table_name}"

            gutachten_nr ->
              formatted_id = reformate_report_id(gutachten_nr)

              "#{current_num}/#{total_items} aus TABELLE #{table_name}, GUTACHTEN: #{formatted_id}"
          end

        # Apply the template
        EEx.eval_string(context_snippet_template,
          assigns: %{
            context_info: context_info,
            context_snippet: formatted_mdb_text
          }
        )
      end)
      # Join without additional newlines
      |> Enum.join("")

    # Stop the agent
    Agent.stop(counter)

    result
  end

  def format_context_mdb(_context_snippet_template, nil), do: ""
  def format_context_mdb(_context_snippet_template, []), do: ""

  def format_context_combined(
        context_snippet_template_report,
        context_snippet_template_mdb,
        vector_results,
        mdb_results
      ) do
    # Check for nil or empty inputs
    vector_formatted =
      if vector_results && vector_results != [] do
        format_context_reports(context_snippet_template_report, vector_results)
      else
        ""
      end

    mdb_formatted =
      if mdb_results && map_size(mdb_results) > 0 do
        format_context_mdb(context_snippet_template_mdb, mdb_results)
      else
        ""
      end

    # Combine both formatted contexts
    mdb_formatted <> vector_formatted
  end

  def format_questions(user_request) do
    cond do
      # If there are no questions in the request, return the whole text as one question with "A. " prefix
      !String.contains?(user_request, "?") ->
        "A. #{user_request}?"

      # Otherwise, split by question mark, format each question, and join with newlines
      true ->
        user_request
        |> String.split("?")
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&(&1 != ""))
        |> Enum.map(fn q -> "#{q}?" end)
        |> Enum.with_index()
        # 65 is ASCII for 'A'
        |> Enum.map(fn {q, i} -> "#{<<65 + i::utf8>>}. #{q}" end)
        |> Enum.join("\n")
    end
  end

  def format_chapter_text(chapter_text) do
    chapter_text
    |> remove_title_and_leading_newlines()
    |> remove_special_symbols()
    |> remove_footnote_tags()
    |> remove_image_lines()
    |> normalize_newlines()
    |> String.trim()
  end

  def reformate_report_id(report_id) when is_binary(report_id) do
    # Check if the input starts with "GA"
    if String.starts_with?(report_id, "GA") do
      # Extract parts using regex
      case Regex.run(~r/GA(\d{2})_(\d{2})_(\d{2})/, report_id) do
        [_, first_part, second_part, suffix] ->
          # Format the base ID with second_part as a 3-digit number
          base_id = "GA#{first_part}/0#{second_part}"

          # Add suffix if it's "_02"
          if suffix == "02" do
            "#{base_id} (Nr. 2)"
          else
            base_id
          end

        _ ->
          # Return original if format doesn't match
          report_id
      end
    else
      # Check if it's exactly a 5-digit number
      if Regex.match?(~r/^\d{5}$/, report_id) do
        {first_two, last_three} = String.split_at(report_id, 2)
        "GA#{first_two}/#{last_three}"
      else
        # Return original for any other format
        report_id
      end
    end
  end

  # Handle nil or non-binary inputs
  def reformate_report_id(nil), do: nil
  def reformate_report_id(other), do: other

  def normalize_prompt_newlines(input_string) do
    # Replace sequences of 2 or more newlines with a single newline
    String.replace(input_string, ~r/\n{3,}/, "\n")
  end

  def is_direct_child(chapter_num, parent_num) do
    chapter_str = to_string(chapter_num)
    parent_str = to_string(parent_num)

    chapter_parts = String.split(chapter_str, ".")
    parent_parts = String.split(parent_str, ".")

    String.starts_with?(chapter_str, "#{parent_str}.") &&
      length(chapter_parts) == length(parent_parts) + 1
  end

  def is_descendant(chapter_num, ancestor_num) do
    chapter_str = to_string(chapter_num)
    ancestor_str = to_string(ancestor_num)

    String.starts_with?(chapter_str, "#{ancestor_str}.")
  end

  def get_parent_chapter_num(chapter_num) do
    chapter_str = to_string(chapter_num)
    parts = String.split(chapter_str, ".")

    if length(parts) > 1 do
      parts
      |> Enum.take(length(parts) - 1)
      |> Enum.join(".")
    else
      nil
    end
  end

  def get_direct_children(chapters, parent_num) do
    chapters
    |> Enum.filter(fn {_idx, chapter} ->
      is_direct_child(chapter.chapter_num, parent_num)
    end)
    |> Enum.sort_by(fn {_idx, chapter} -> chapter.chapter_num end)
  end

  def build_chapter_hierarchy(chapters, root_chapter_num) do
    chapters
    |> Enum.reduce(%{}, fn {idx, chapter}, acc ->
      parent_num = get_parent_chapter_num(chapter.chapter_num)

      children = Map.get(acc, parent_num, [])
      Map.put(acc, parent_num, children ++ [{idx, chapter}])
    end)
  end

  def get_subchapters(chapters, parent_num) do
    chapters
    |> Enum.filter(fn {_idx, chapter} ->
      is_descendant(chapter.chapter_num, parent_num) &&
        !is_direct_child(chapter.chapter_num, parent_num)
    end)
  end

  def format_chapter_num(raw_chapter_num) do
    raw_chapter_num
    |> to_string()
    |> String.trim_trailing(".")
  end

  def format_meta_data(template, meta_data) do
    cond do
      is_nil(meta_data) ->
        ""

      map_size(meta_data) > 0 ->
        meta_data_text =
          meta_data
          |> Enum.map(fn {key, value} -> "#{key}: #{value}" end)
          |> Enum.join("\n")

        EEx.eval_string(template,
          assigns: %{meta_data_objects: meta_data_text}
        )

      true ->
        ""
    end
  end

  def format_previous_content(previous_content, category, prompt_key) do
    case category do
      :only_chapters ->
        if map_size(previous_content) > 0 do
          filtered_content =
            previous_content
            |> Enum.map(fn {idx, chapter} ->
              chapter_level =
                case chapter.level do
                  "main_chapter_no_closing" -> "main_chapter_no_closing"
                  "main_chapter_no_closing_no_content" -> "main_chapter_no_closing_no_content"
                  "main_chapter_no_closing" -> "main_chapter_no_closing"
                  other -> other
                end

              updated_content =
                chapter.content
                |> remove_special_tags()
                |> remove_chapter_header(chapter.chapter_num, chapter.sanitized_filename)

              {idx,
               chapter |> Map.put(:level, chapter_level) |> Map.put(:content, updated_content)}
            end)
            |> Map.new()

          formatted_content =
            process_previous_chapters(filtered_content, prompt_key, true, category)

          previous_content_template =
            extract_prompt_element(prompt_key, "previous_content_chapters")

          EEx.eval_string(previous_content_template,
            assigns: %{previous_content: formatted_content}
          )
        else
          ""
        end

      :only_summaries ->
        if map_size(previous_content) > 0 do
          modified_content = override_summary_types(previous_content)
          formatted_summaries = process_previous_summaries(modified_content, prompt_key)

          previous_content_template =
            extract_prompt_element(prompt_key, "previous_content_summaries")

          EEx.eval_string(previous_content_template,
            assigns: %{previous_content: formatted_summaries}
          )
        else
          ""
        end

      _ ->
        ""
    end
  end

  def override_summary_types(previous_content) do
    previous_content
    |> Enum.map(fn {idx, item} ->
      {idx, Map.put(item, :level, "sub_chapter")}
    end)
    |> Map.new()
  end

  def cleanup_string(text) do
    text
    |> String.replace("\\\"", "\"")
    |> String.replace("\\r", "\r")
    |> String.replace("\\n", "\n")
    |> String.replace("\\\\", "\\")
    |> String.replace(~r/\r\n|\r/, "\n")
    |> String.replace(~r/\n\s+\n/, "\n\n")
    |> String.replace(~r/^\s+/, "")
    |> String.replace(~r/\s+$/, "")
  end

  def process_previous_summaries(previous_content, prompt_key) do
    sorted_summaries =
      previous_content
      |> Enum.sort_by(fn {idx, _} -> idx end)

    {result, _} =
      Enum.reduce(sorted_summaries, {"", nil}, fn {idx, summary}, {acc, _} ->
        next_item = Enum.find(sorted_summaries, fn {next_idx, _} -> next_idx > idx end)
        has_following = next_item != nil

        formatted_summary =
          format_summary_by_type(
            summary.level,
            summary.chapter_num,
            summary.sanitized_filename,
            summary.content,
            has_following,
            prompt_key
          )

        {acc <> formatted_summary, summary}
      end)

    result
  end

  def format_summary_by_type(
        level,
        chapter_num,
        chapter_name,
        content,
        has_following,
        prompt_key
      ) do
    normalized_content =
      if contains_restricted_tags?(content) do
        ""
      else
        content
        |> remove_footnote_tags()
        |> remove_image_lines()
        |> remove_special_tags()
        |> remove_chapter_header(chapter_num, chapter_name)
        |> normalize_newlines()
      end

    case level do
      "subchapter_closing" <> _ ->
        sub_summary_closing_template =
          extract_prompt_element(prompt_key, "previous_sub_summary_closing")

        EEx.eval_string(
          sub_summary_closing_template,
          assigns: %{
            chapter_num: chapter_num,
            chapter_name: chapter_name,
            previous_summary_content: normalized_content
          }
        )

      _ ->
        following_content = if has_following, do: "", else: "\n\n"

        previous_main_summary_template =
          extract_prompt_element(prompt_key, "previous_main_summary")

        EEx.eval_string(
          previous_main_summary_template,
          assigns: %{
            chapter_num: chapter_num,
            chapter_name: chapter_name,
            previous_summary_content: normalized_content,
            previous_summary_following: following_content
          }
        )
    end
  end

  def process_previous_chapters(previous_content, prompt_key, cleanup \\ true, category \\ nil) do
    sorted_chapters =
      previous_content
      |> Enum.sort_by(fn {idx, _} -> idx end)

    {result, _state} =
      process_chapters_recursive(
        sorted_chapters,
        0,
        %{open_chapters: [], processed_chapters: []},
        cleanup,
        category,
        prompt_key
      )

    result
  end

  def process_chapters_recursive([], _current_idx, _state, _cleanup, _category, _prompt_key),
    do: {"", %{open_chapters: [], processed_chapters: []}}

  def process_chapters_recursive(
        [{idx, chapter} | rest],
        current_idx,
        state,
        cleanup,
        category,
        prompt_key
      ) do
    chapter_level = chapter.level
    chapter_num = chapter.chapter_num
    chapter_name = chapter.sanitized_filename

    if chapter_num in state.processed_chapters do
      process_chapters_recursive(rest, current_idx + 1, state, cleanup, category, prompt_key)
    else
      chapter_content =
        if cleanup do
          cleanup_chapter_content(chapter.content)
        else
          normalize_newlines(chapter.content)
        end

      next_item = if length(rest) > 0, do: hd(rest), else: nil
      has_following = next_item != nil

      {formatted_chapter, new_state} =
        format_chapter_by_type(
          chapter_level,
          chapter_num,
          chapter_name,
          chapter_content,
          has_following,
          rest,
          state,
          prompt_key
        )

      updated_state = %{
        new_state
        | processed_chapters: [chapter_num | new_state.processed_chapters]
      }

      {following_content, final_state} =
        process_chapters_recursive(rest, idx + 1, updated_state, cleanup, category, prompt_key)

      {formatted_chapter <> following_content, final_state}
    end
  end

  def format_chapter_by_type(
        chapter_level,
        chapter_num,
        chapter_name,
        chapter_content,
        has_following,
        rest,
        state,
        prompt_key
      ) do
    cleaned_content = cleanup_chapter_content(chapter_content)

    case chapter_level do
      "main_chapter_no_content" ->
        {sub_chapters, remaining_chapters, new_state} =
          extract_sub_chapters(rest, chapter_num, state, prompt_key)

        following_content = if has_following, do: "", else: "\n\n"

        previous_main_chapter_no_content_template =
          extract_prompt_element(prompt_key, "previous_main_chapter_no_content")

        if is_binary(previous_main_chapter_no_content_template) do
          formatted =
            EEx.eval_string(
              previous_main_chapter_no_content_template,
              assigns: %{
                chapter_num: chapter_num,
                chapter_name: chapter_name,
                previous_sub_chapters: sub_chapters || "",
                previous_chapter_following: following_content
              }
            )

          updated_state = %{new_state | open_chapters: [chapter_num | new_state.open_chapters]}
          {formatted, updated_state}
        else
          {"", new_state}
        end

      "main_chapter_no_closing" ->
        {sub_chapters, remaining_chapters, new_state} =
          extract_sub_chapters(rest, chapter_num, state, prompt_key)

        following_content = if has_following, do: "", else: "\n\n"

        previous_main_chapter_no_closing_template =
          extract_prompt_element(prompt_key, "previous_main_chapter_no_closing")

        if is_binary(previous_main_chapter_no_closing_template) do
          formatted =
            EEx.eval_string(
              previous_main_chapter_no_closing_template,
              assigns: %{
                chapter_num: chapter_num,
                chapter_name: chapter_name,
                chapter_content: cleaned_content,
                previous_sub_chapters: sub_chapters || "",
                previous_chapter_following: following_content
              }
            )

          updated_state = %{new_state | open_chapters: [chapter_num | new_state.open_chapters]}
          {formatted, updated_state}
        else
          {"", new_state}
        end

      "main_chapter_opening" <> _ ->
        {sub_chapters, remaining_chapters, new_state} =
          extract_sub_chapters(rest, chapter_num, state, prompt_key)

        following_content = if has_following, do: "", else: "\n\n"

        previous_main_chapter_with_content_template =
          extract_prompt_element(prompt_key, "previous_main_chapter_with_content")

        if is_binary(previous_main_chapter_with_content_template) do
          formatted =
            EEx.eval_string(
              previous_main_chapter_with_content_template,
              assigns: %{
                chapter_num: chapter_num,
                chapter_name: chapter_name,
                chapter_content: cleaned_content,
                previous_sub_chapters: sub_chapters || "",
                previous_chapter_following: following_content
              }
            )

          updated_state = %{new_state | open_chapters: [chapter_num | new_state.open_chapters]}
          {formatted, updated_state}
        else
          {"", new_state}
        end

      "main_chapter" ->
        following_content = if has_following, do: "", else: "\n\n"

        previous_main_chapter_with_content_template =
          extract_prompt_element(prompt_key, "previous_main_chapter_with_content")

        if is_binary(previous_main_chapter_with_content_template) do
          formatted =
            EEx.eval_string(
              previous_main_chapter_with_content_template,
              assigns: %{
                chapter_num: chapter_num,
                chapter_name: chapter_name,
                chapter_content: cleaned_content,
                previous_sub_chapters: "",
                previous_chapter_following: following_content
              }
            )

          {formatted, state}
        else
          {"", state}
        end

      "main_chapter_no_closing" ->
        {sub_chapters, remaining_chapters, new_state} =
          extract_sub_chapters(rest, chapter_num, state, prompt_key)

        previous_main_chapter_no_closing_template =
          extract_prompt_element(prompt_key, "previous_main_chapter_no_closing")

        if is_binary(previous_main_chapter_no_closing_template) do
          formatted =
            EEx.eval_string(
              previous_main_chapter_no_closing_template,
              assigns: %{
                chapter_num: chapter_num,
                chapter_name: chapter_name,
                chapter_content: cleaned_content,
                previous_sub_chapters: sub_chapters || ""
              }
            )

          updated_state = %{new_state | open_chapters: [chapter_num | new_state.open_chapters]}
          {formatted, updated_state}
        else
          {"", new_state}
        end

      "main_chapter_no_closing_no_content" ->
        {sub_chapters, remaining_chapters, new_state} =
          extract_sub_chapters(rest, chapter_num, state, prompt_key)

        previous_main_chapter_no_closing_no_content_template =
          extract_prompt_element(prompt_key, "previous_main_chapter_no_closing_no_content")

        if is_binary(previous_main_chapter_no_closing_no_content_template) do
          formatted =
            EEx.eval_string(
              previous_main_chapter_no_closing_no_content_template,
              assigns: %{
                chapter_num: chapter_num,
                chapter_name: chapter_name,
                previous_sub_chapters: sub_chapters || ""
              }
            )

          updated_state = %{new_state | open_chapters: [chapter_num | new_state.open_chapters]}
          {formatted, updated_state}
        else
          {"", new_state}
        end

      "subchapter_closing" <> _ ->
        previous_sub_chapter_closing_template =
          extract_prompt_element(prompt_key, "previous_sub_chapter_closing")

        if is_binary(previous_sub_chapter_closing_template) do
          formatted =
            EEx.eval_string(
              previous_sub_chapter_closing_template,
              assigns: %{
                chapter_num: chapter_num,
                chapter_name: chapter_name,
                chapter_content: cleaned_content
              }
            )

          updated_state =
            if length(state.open_chapters) > 0 do
              %{state | open_chapters: tl(state.open_chapters)}
            else
              state
            end

          {formatted, updated_state}
        else
          {"", state}
        end

      "sub_chapter" ->
        following_content = if has_following, do: "", else: "\n\n"

        previous_sub_chapter_template =
          extract_prompt_element(prompt_key, "previous_sub_chapter")

        if is_binary(previous_sub_chapter_template) do
          formatted =
            EEx.eval_string(
              previous_sub_chapter_template,
              assigns: %{
                chapter_num: chapter_num,
                chapter_name: chapter_name,
                chapter_content: cleaned_content,
                previous_chapter_following: following_content
              }
            )

          {formatted, state}
        else
          {"", state}
        end

      _ ->
        {"", state}
    end
  end

  def extract_sub_chapters(chapters, main_chapter_num, state, prompt_key) do
    direct_children =
      chapters
      |> Enum.filter(fn {_idx, chapter} ->
        is_direct_child(chapter.chapter_num, main_chapter_num) &&
          !(chapter.chapter_num in state.processed_chapters)
      end)
      |> Enum.sort_by(fn {_idx, chapter} -> chapter.chapter_num end)

    {sub_content, remaining_chapters, new_state} =
      Enum.reduce(direct_children, {"", [], state}, fn {idx, chapter},
                                                       {content_acc, remaining_acc, state_acc} ->
        updated_state = %{
          state_acc
          | processed_chapters: [chapter.chapter_num | state_acc.processed_chapters]
        }

        {sub_content, newer_state} =
          process_chapter_with_children(chapter, idx, chapters, updated_state, prompt_key)

        {content_acc <> sub_content, remaining_acc, newer_state}
      end)

    remaining =
      chapters
      |> Enum.reject(fn {_idx, chapter} ->
        is_descendant(chapter.chapter_num, main_chapter_num) ||
          chapter.chapter_num in new_state.processed_chapters
      end)

    {sub_content, remaining, new_state}
  end

  def process_chapter_with_children(chapter, idx, all_chapters, state, prompt_key) do
    chapter_level = chapter.level
    chapter_num = chapter.chapter_num
    chapter_name = chapter.sanitized_filename
    chapter_content = cleanup_chapter_content(chapter.content)

    children_chapters =
      all_chapters
      |> Enum.filter(fn {_idx, ch} ->
        is_direct_child(ch.chapter_num, chapter_num) &&
          !(ch.chapter_num in state.processed_chapters)
      end)
      |> Enum.sort_by(fn {_idx, ch} -> ch.chapter_num end)

    case chapter_level do
      "main_chapter_opening" <> _ ->
        {sub_content, sub_state} =
          process_children_recursive(
            children_chapters,
            all_chapters,
            %{
              state
              | processed_chapters: [chapter_num | state.processed_chapters]
            },
            prompt_key
          )

        previous_main_chapter_with_content_template =
          extract_prompt_element(prompt_key, "previous_main_chapter_with_content")

        formatted =
          EEx.eval_string(
            previous_main_chapter_with_content_template,
            assigns: %{
              chapter_num: chapter_num,
              chapter_name: chapter_name,
              chapter_content: chapter_content,
              previous_sub_chapters: sub_content,
              previous_chapter_following: ""
            }
          )

        updated_state = %{sub_state | open_chapters: [chapter_num | sub_state.open_chapters]}
        {formatted, updated_state}

      "main_chapter_no_content" ->
        {sub_content, sub_state} =
          process_children_recursive(
            children_chapters,
            all_chapters,
            %{
              state
              | processed_chapters: [chapter_num | state.processed_chapters]
            },
            prompt_key
          )

        previous_main_chapter_no_content_template =
          extract_prompt_element(prompt_key, "previous_main_chapter_no_content")

        formatted =
          EEx.eval_string(
            previous_main_chapter_no_content_template,
            assigns: %{
              chapter_num: chapter_num,
              chapter_name: chapter_name,
              previous_sub_chapters: sub_content,
              previous_chapter_following: ""
            }
          )

        updated_state = %{sub_state | open_chapters: [chapter_num | sub_state.open_chapters]}
        {formatted, updated_state}

      "main_chapter_no_closing" ->
        {sub_content, sub_state} =
          process_children_recursive(
            children_chapters,
            all_chapters,
            %{
              state
              | processed_chapters: [chapter_num | state.processed_chapters]
            },
            prompt_key
          )

        previous_main_chapter_no_closing_template =
          extract_prompt_element(prompt_key, "previous_main_chapter_no_closing")

        formatted =
          EEx.eval_string(
            previous_main_chapter_no_closing_template,
            assigns: %{
              chapter_num: chapter_num,
              chapter_name: chapter_name,
              chapter_content: chapter_content,
              previous_sub_chapters: sub_content,
              previous_chapter_following: ""
            }
          )

        updated_state = %{sub_state | open_chapters: [chapter_num | sub_state.open_chapters]}
        {formatted, updated_state}

      "main_chapter_no_closing" ->
        {sub_content, sub_state} =
          process_children_recursive(
            children_chapters,
            all_chapters,
            %{
              state
              | processed_chapters: [chapter_num | state.processed_chapters]
            },
            prompt_key
          )

        previous_main_chapter_no_closing_template =
          extract_prompt_element(prompt_key, "previous_main_chapter_no_closing")

        formatted =
          EEx.eval_string(
            previous_main_chapter_no_closing_template,
            assigns: %{
              chapter_num: chapter_num,
              chapter_name: chapter_name,
              chapter_content: chapter_content,
              previous_sub_chapters: sub_content
            }
          )

        updated_state = %{sub_state | open_chapters: [chapter_num | sub_state.open_chapters]}
        {formatted, updated_state}

      "main_chapter_no_closing_no_content" ->
        {sub_content, sub_state} =
          process_children_recursive(
            children_chapters,
            all_chapters,
            %{
              state
              | processed_chapters: [chapter_num | state.processed_chapters]
            },
            prompt_key
          )

        previous_main_chapter_no_closing_no_content_template =
          extract_prompt_element(prompt_key, "previous_main_chapter_no_closing_no_content")

        formatted =
          EEx.eval_string(
            previous_main_chapter_no_closing_no_content_template,
            assigns: %{
              chapter_num: chapter_num,
              chapter_name: chapter_name,
              previous_sub_chapters: sub_content
            }
          )

        updated_state = %{sub_state | open_chapters: [chapter_num | sub_state.open_chapters]}
        {formatted, updated_state}

      "sub_chapter" ->
        previous_sub_chapter_template =
          extract_prompt_element(prompt_key, "previous_sub_chapter")

        formatted =
          EEx.eval_string(
            previous_sub_chapter_template,
            assigns: %{
              chapter_num: chapter_num,
              chapter_name: chapter_name,
              chapter_content: chapter_content,
              previous_chapter_following: ""
            }
          )

        {sub_content, sub_state} =
          process_children_recursive(
            children_chapters,
            all_chapters,
            %{
              state
              | processed_chapters: [chapter_num | state.processed_chapters]
            },
            prompt_key
          )

        {formatted <> sub_content, sub_state}

      "subchapter_closing" <> _ ->
        previous_sub_chapter_closing_template =
          extract_prompt_element(prompt_key, "previous_sub_chapter_closing")

        formatted =
          EEx.eval_string(
            previous_sub_chapter_closing_template,
            assigns: %{
              chapter_num: chapter_num,
              chapter_name: chapter_name,
              chapter_content: chapter_content
            }
          )

        updated_state =
          if length(state.open_chapters) > 0 do
            %{
              state
              | open_chapters: tl(state.open_chapters),
                processed_chapters: [chapter_num | state.processed_chapters]
            }
          else
            %{state | processed_chapters: [chapter_num | state.processed_chapters]}
          end

        {formatted, updated_state}

      _ ->
        {formatted, state} =
          {"", %{state | processed_chapters: [chapter_num | state.processed_chapters]}}

        {sub_content, sub_state} =
          process_children_recursive(children_chapters, all_chapters, state, prompt_key)

        {formatted <> sub_content, sub_state}
    end
  end

  def process_children_recursive([], _all_chapters, state, _prompt_key), do: {"", state}

  def process_children_recursive(children_chapters, all_chapters, state, prompt_key) do
    Enum.reduce(children_chapters, {"", state}, fn {idx, chapter}, {acc_content, acc_state} ->
      if chapter.chapter_num in acc_state.processed_chapters do
        {acc_content, acc_state}
      else
        {sub_content, new_state} =
          process_chapter_with_children(chapter, idx, all_chapters, acc_state, prompt_key)

        {acc_content <> sub_content, new_state}
      end
    end)
  end

  def cleanup_chapter_content(nil), do: ""
  def cleanup_chapter_content(""), do: ""

  def cleanup_chapter_content(content) when is_binary(content) do
    content
    |> String.replace(~r/\r\n|\r/, "\n")
    |> String.replace(~r/\n\s+\n/, "\n\n")
    |> String.replace(~r/^\s+/, "")
    |> String.replace(~r/\s+$/, "")
  end

  def remove_footnote_tags(content) when is_binary(content) do
    # This pattern will match both standalone footnotes and embedded footnotes
    Regex.replace(~r/\[\^(\d+)\]/, content, "")
  end

  def remove_footnote_tags(nil), do: ""

  def remove_image_lines(content) when is_binary(content) do
    content
    |> String.split("\n")
    |> Enum.reject(fn line -> String.starts_with?(String.trim(line), "![") end)
    |> Enum.join("\n")
  end

  def remove_image_lines(nil), do: ""

  def remove_special_tags(content) when is_binary(content) do
    tag_regex =
      ~r/(?i)###\s*(FALL ENDE|FALL BEGINN|ZUSAMMENFASSUNG|TEXT|FALL ZUSAMMENFASSUNG|FALL|KERNAUSSAGEN?|STICHWORTE?|SCHLUSSFOLGERUNGE?N?|EMPFEHLUNGE?N?)\s*\n*/

    Regex.replace(tag_regex, content, "")
  end

  def remove_special_tags(nil), do: ""

  def remove_chapter_header(content, chapter_num, chapter_name) when is_binary(content) do
    chapter_with_dot =
      if String.contains?(to_string(chapter_num), ".") do
        "#{chapter_num} #{chapter_name}"
      else
        "#{chapter_num}. #{chapter_name}"
      end

    case_insensitive_regex = Regex.compile!("(?i)" <> Regex.escape(chapter_with_dot))
    Regex.replace(case_insensitive_regex, content, "")
  end

  def remove_chapter_header(nil, _chapter_num, _chapter_name), do: ""

  def contains_restricted_tags?(content) when is_binary(content) do
    String.contains?(content, "### BEISPIEL") ||
      String.contains?(content, "### ANWEISUNG")
  end

  def contains_restricted_tags?(nil), do: false

  def remove_title_and_leading_newlines(content) when is_binary(content) do
    case String.split(content, "\n", parts: 2) do
      [_title, rest] ->
        String.replace_prefix(rest, "\n", "") |> String.trim_leading()

      [only_line] ->
        ""

      [] ->
        ""
    end
  end

  def remove_title_and_leading_newlines(nil), do: ""

  def normalize_newlines(content) when is_binary(content) do
    content
    |> String.replace(~r/\n\s*\n/, "\n")
    |> String.replace(~r/\r\n/, "\n")
    |> String.replace(~r/\r/, "\n")
    |> String.replace(~r/\n\s+\n/, "\n\n")
    |> String.replace(~r/^\s+/, "")
    |> String.replace(~r/\s+$/, "")
  end

  def normalize_newlines(nil), do: ""

  @doc """
  Counts words and estimates tokens in a message or text.
  """
  def count_words_and_tokens(text) when is_binary(text) do
    # Split by whitespace to count words
    words = text |> String.split(~r/\s+/, trim: true)
    word_count = length(words)

    # Count characters that likely become separate tokens
    special_chars =
      text
      |> String.graphemes()
      |> Enum.count(&(&1 =~ ~r/[.,;:!?()[\]{}""„"—–\-\/@#$%^&*=+]|[0-9]/))

    # Estimate tokens from words (using an average factor for German)
    base_token_estimate =
      words
      |> Enum.map(fn word ->
        cond do
          String.length(word) <= 1 -> 1
          String.length(word) <= 4 -> 1
          String.length(word) <= 8 -> 1.3
          String.length(word) > 8 -> String.length(word) / 5.0
        end
      end)
      |> Enum.sum()
      |> round()

    # Add special character tokens to the base estimate
    estimated_tokens = base_token_estimate + special_chars

    %{
      word_count: word_count,
      estimated_tokens: estimated_tokens
    }
  end

  # Handle Message structs list
  def count_words_and_tokens(messages) when is_list(messages) do
    # Extract content from each message and concatenate
    combined_text =
      messages
      |> Enum.map(fn
        %{content: content} when is_binary(content) -> content
        _ -> ""
      end)
      |> Enum.join(" ")

    # Process the combined text
    count_words_and_tokens(combined_text)
  end

  # Handle non-binary input
  def count_words_and_tokens(nil), do: %{word_count: 0, estimated_tokens: 0}
  def count_words_and_tokens(_), do: %{word_count: 0, estimated_tokens: 0}

  def extract_single_meta_data(nil), do: {nil, %{}}

  def extract_single_meta_data(meta_data) do
    # Extract basic_info and device_info
    basic_info = Map.get(meta_data, "basic_info") || %{}
    device_info = Map.get(meta_data, "device_info") || %{}

    # Extract parties information
    parties = Map.get(meta_data, "parties") || %{}

    # Format parties content in ordered pairs (person statement followed by related analyses)
    formatted_parties =
      if map_size(parties) > 0 do
        # Extract person statements
        person_statements =
          parties
          |> Enum.filter(fn {key, _} -> is_binary(key) && String.contains?(key, ":person:") end)
          |> Enum.map(fn {key, value} ->
            # Handle both complex and simple string value formats
            parts =
              if is_binary(key) do
                String.split(key, ":", trim: true)
              else
                []
              end

            # Extract party_name and person_id safely
            party_name =
              if length(parts) >= 1 do
                Enum.at(parts, 0) |> String.trim()
              else
                "Unknown"
              end

            person_id =
              if length(parts) >= 3 do
                case Integer.parse(Enum.at(parts, 2)) do
                  {id, _} -> id
                  # Default ID if parsing fails
                  :error -> 1
                end
              else
                # Default ID
                1
              end

            # Handle both object values and string values
            statement_content =
              cond do
                is_map(value) && Map.has_key?(value, "content") ->
                  value["content"]

                is_binary(value) ->
                  value

                true ->
                  ""
              end

            {person_id, {key, party_name, %{"content" => statement_content}}}
          end)
          |> Enum.sort_by(fn {id, _} -> id end)

        # Build result map
        {result, _} =
          Enum.reduce(person_statements, {%{}, 1}, fn {person_id,
                                                       {person_key, party_name, person_value}},
                                                      {acc, counter} ->
            # Add person statement
            acc =
              Map.put(
                acc,
                counter,
                "Aussage #{person_id} (#{party_name}): #{person_value["content"]}"
              )

            counter = counter + 1

            # Find and add related analysis statements
            related_analyses =
              parties
              |> Enum.filter(fn {key, value} ->
                # For string values, include if key pattern matches
                String.contains?(key, ":analysis:") &&
                  String.contains?(key, ":#{person_id}:") &&
                  ((is_map(value) && Map.get(value, "related_to") == person_id) ||
                     (!is_map(value) && true))
              end)
              |> Enum.sort_by(fn {key, _} ->
                parts = String.split(key, ":", trim: true)

                analysis_id =
                  if length(parts) >= 4 do
                    case Integer.parse(Enum.at(parts, 3)) do
                      {id, _} -> id
                      :error -> 0
                    end
                  else
                    0
                  end

                analysis_id
              end)

            {new_acc, new_counter} =
              Enum.reduce(related_analyses, {acc, counter}, fn {key, value},
                                                               {inner_acc, inner_counter} ->
                # Handle both object values and string values
                analysis_content =
                  cond do
                    is_map(value) && Map.has_key?(value, "content") ->
                      value["content"]

                    is_binary(value) ->
                      value

                    true ->
                      ""
                  end

                inner_acc =
                  Map.put(
                    inner_acc,
                    inner_counter,
                    "Analyse zur Aussage #{person_id} (#{party_name}): #{analysis_content}"
                  )

                {inner_acc, inner_counter + 1}
              end)

            {new_acc, new_counter}
          end)

        result
      else
        %{}
      end

    # Combine basic_info and device_info
    combined_info = Map.merge(basic_info, device_info)

    # Return combined_info as nil if it's empty
    combined_info = if combined_info == %{}, do: nil, else: combined_info

    {combined_info, formatted_parties}
  end

  def remove_special_symbols(string) do
    string
    # Remove caret symbol
    |> String.replace("\^", "")
  end
end
