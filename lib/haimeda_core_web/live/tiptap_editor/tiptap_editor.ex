defmodule HaimedaCoreWeb.ReportsEditor.TipTapEditor do
  use HaimedaCoreWeb, :live_component

  require Logger

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       content: "",
       formatted_content: nil,
       read_only: false,
       editor_id: "tiptap-editor-#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    # Extract content and formatted content from the assigns
    content = Map.get(assigns, :content, "")
    formatted_content = Map.get(assigns, :formatted_content)
    read_only = Map.get(assigns, :read_only, false)

    # Compare with existing content to detect changes
    content_changed = content != socket.assigns[:content]
    formatted_changed = formatted_content != socket.assigns[:formatted_content]

    socket =
      socket
      |> assign(:content, content)
      |> assign(:formatted_content, formatted_content)
      |> assign(:read_only, read_only)

    # Explicitly push an update to the client if content changed significantly
    if (content_changed || formatted_changed) && connected?(socket) do
      # This will use the client hook's handleEvent("update_editor_content")
      encoded_formatted =
        case formatted_content do
          nil ->
            nil

          content when is_map(content) ->
            case Jason.encode(content) do
              {:ok, json} -> json
              _ -> nil
            end

          _ ->
            nil
        end

      push_event(socket, "update_editor_content", %{
        content: content,
        formatted_content: encoded_formatted
      })
    end

    {:ok, socket}
  end

  @doc """
  Transforms formatted content with entities to clean text content.
  Extracts displayText from entities, ignores selection lists,
  and maintains hardBreaks while cleaning up whitespace.
  """
  def transform_formatted_content_to_text(formatted_content) do
    case formatted_content do
      %{"type" => "doc", "content" => content} when is_list(content) ->
        # Process each top-level node
        clean_content = process_content_nodes(content)

        # Return a new document with clean content
        %{
          "type" => "doc",
          "content" => clean_content
        }

      # Return empty document if the input is invalid
      _ ->
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
    end
  end

  # Process a list of content nodes, skipping selection lists
  defp process_content_nodes(content) when is_list(content) do
    content
    |> Enum.filter(fn node ->
      # Filter out selection lists
      case node do
        %{"type" => "list", "marks" => marks} ->
          not selection_list?(marks)

        %{"type" => "selectionList"} ->
          false

        _ ->
          true
      end
    end)
    |> Enum.map(fn node ->
      case node do
        # Process paragraph nodes
        %{"type" => "paragraph", "content" => para_content} = para when is_list(para_content) ->
          clean_para_content = process_paragraph_content(para_content)
          Map.put(para, "content", clean_para_content)

        # Keep hardBreaks
        %{"type" => "hardBreak"} ->
          node

        # Pass other nodes through
        _ ->
          node
      end
    end)
  end

  # Process paragraph content to extract clean text
  defp process_paragraph_content(para_content) when is_list(para_content) do
    para_content
    |> Enum.map(fn node ->
      case node do
        # Process text nodes with marks (coloredEntities)
        %{"type" => "text", "marks" => marks} = text_node when is_list(marks) ->
          colored_entity = find_colored_entity(marks)

          if colored_entity do
            # Extract displayText from the entity
            entity_attrs = Map.get(colored_entity, "attrs", %{})
            display_text = Map.get(entity_attrs, "displayText", text_node["text"])

            # Return a plain text node with the displayText
            %{"type" => "text", "text" => display_text}
          else
            # Keep the original text node (but remove marks)
            %{"type" => "text", "text" => text_node["text"]}
          end

        # Keep hardBreaks
        %{"type" => "hardBreak"} ->
          node

        # Keep regular text nodes
        %{"type" => "text"} ->
          node

        # Default handling
        _ ->
          node
      end
    end)
    |> clean_whitespace_between_nodes()
  end

  # Find a coloredEntity mark in a list of marks
  defp find_colored_entity(marks) do
    Enum.find(marks, fn mark ->
      mark["type"] == "coloredEntity"
    end)
  end

  # Check if marks contain a selection_list entity
  defp selection_list?(marks) when is_list(marks) do
    Enum.any?(marks, fn mark ->
      mark["type"] == "coloredEntity" &&
        get_in(mark, ["attrs", "entityType"]) == "selection_list"
    end)
  end

  defp selection_list?(_), do: false

  # Clean up unnecessary whitespace between nodes
  defp clean_whitespace_between_nodes(nodes) do
    nodes
    |> Enum.chunk_by(fn node -> node["type"] == "hardBreak" end)
    |> Enum.flat_map(fn chunk ->
      # Keep hardBreaks as they are
      if length(chunk) > 0 && hd(chunk)["type"] == "hardBreak" do
        chunk
      else
        # Process text nodes to clean whitespace
        clean_text_chunk(chunk)
      end
    end)
  end

  # Clean whitespace in a chunk of text nodes
  defp clean_text_chunk(chunk) do
    all_text =
      chunk
      |> Enum.filter(fn node -> node["type"] == "text" end)
      |> Enum.map(fn node -> node["text"] end)
      |> Enum.join("")
      |> String.trim()

    if all_text == "" do
      # If the chunk is all whitespace, return a single space
      [%{"type" => "text", "text" => " "}]
    else
      # Otherwise, return a single text node with the cleaned text
      [%{"type" => "text", "text" => all_text}]
    end
  end

  # Helper to check if formatted content has any marks
  defp formatted_content_has_marks?(content) do
    try do
      has_marks = find_marks_in_content(content)
      has_marks
    rescue
      _ -> false
    end
  end

  # Recursively search for marks in content
  defp find_marks_in_content(%{"content" => content_list}) when is_list(content_list) do
    Enum.any?(content_list, fn
      %{"content" => inner_content} when is_list(inner_content) ->
        find_marks_in_content(%{"content" => inner_content})

      %{"marks" => marks} when is_list(marks) and length(marks) > 0 ->
        true

      _ ->
        false
    end)
  end

  defp find_marks_in_content(_), do: false

  @impl true
  def render(assigns) do
    # Prepare the formatted content for the template
    formatted_content_json =
      if assigns.formatted_content do
        # send the raw [doc](http://_vscodecontentref_/3) JSON so the JS hook can parse it as a proper doc
        Jason.encode!(assigns.formatted_content)
      else
        "null"
      end

    # IO.inspect(formatted_content_json, label: "Formatted Content JSON")

    assigns = assign(assigns, :formatted_content_json, formatted_content_json)

    ~H"""
    <div id={@editor_id} class="tiptap-editor"
         phx-hook="TipTapEditor"
         data-content={if @content, do: @content, else: ""}
         data-formatted-content={@formatted_content_json}
         data-read-only={if @read_only, do: "true", else: "false"}
         data-tab-id={@tab_id}
         phx-target={@myself}
         phx-update="ignore">
      <div class="tiptap-loading-overlay">
        <div class="tiptap-loading-spinner"></div>
        <div class="tiptap-loading-message">Editor wird geladen...</div>
      </div>
      <div class="tiptap-toolbar">
        <!-- TipTap toolbar will be inserted here by JS -->
      </div>
      <div class="tiptap-content">
        <!-- TipTap editor will be inserted here by JS -->
      </div>
    </div>
    """
  end

  @impl true
  def handle_event(
        "content-updated",
        %{"content" => content, "formatted_content" => formatted_content},
        socket
      ) do
    # JSON decode the formatted content
    formatted_content_parsed =
      case Jason.decode(formatted_content) do
        {:ok, decoded} -> decoded
        _ -> nil
      end

    # Send the updated content to the parent component
    send(
      self(),
      {:tiptap_content_updated, socket.assigns.tab_id, content, formatted_content_parsed}
    )

    # Update our local state to match what was just sent
    socket =
      socket
      |> assign(:content, content)
      |> assign(:formatted_content, formatted_content_parsed)

    {:noreply, socket}
  end

  @impl true
  def handle_event("entity-removed", %{"index" => index}, socket) do
    # Handle entity removal
    send(self(), {:tiptap_entity_removed, socket.assigns.tab_id, index})
    {:noreply, socket}
  end

  @impl true
  def handle_event("entity-replaced", %{"index" => index, "replacement" => replacement}, socket) do
    # Handle entity replacement
    send(self(), {:tiptap_entity_replaced, socket.assigns.tab_id, index, replacement})
    {:noreply, socket}
  end

  @impl true
  def handle_event("entity-marked-for-deletion", %{"index" => index}, socket) do
    # Handle entity being marked for deletion
    send(self(), {:tiptap_entity_marked_for_deletion, socket.assigns.tab_id, index})
    {:noreply, socket}
  end

  @impl true
  def handle_event(
        "entity-replaced",
        %{"index" => index, "replacement" => replacement, "switchedEntity" => switched},
        socket
      ) do
    # Handle entity replacement with additional switched flag
    send(self(), {:tiptap_entity_replaced, socket.assigns.tab_id, index, replacement, switched})
    {:noreply, socket}
  end

  @doc """
  Formats TipTap content for correction mode.
  Takes a TipTap formatted content map and ensures it's properly structured.
  """

  def format_tiptap_content(content) when is_map(content) do
    # Process the content to ensure entities render properly
    processed_content = ensure_entities_render(content)
    processed_content = ensure_selection_lists_render(processed_content)

    # IO.inspect(processed_content, label: "Processed Content")

    processed_content
  end

  # Helper to ensure entities at paragraph ends render properly
  defp ensure_entities_render(%{"type" => "doc", "content" => paragraphs} = doc) do
    # Pre-analyze the document structure to identify selection lists and paragraphs before them
    paragraph_info = analyze_document_structure(paragraphs)

    # Process each paragraph with knowledge of the document structure
    updated_paragraphs =
      Enum.with_index(paragraphs)
      |> Enum.map(fn {paragraph, idx} ->
        case paragraph do
          %{"type" => "paragraph", "content" => content} ->
            # Check if this paragraph is directly before a selectionList
            is_before_selection = Enum.member?(paragraph_info.before_selection_indices, idx)
            is_last_paragraph = idx == paragraph_info.last_paragraph_index

            # Process content with appropriate handling based on position
            updated_content =
              cond do
                is_last_paragraph ->
                  # Only for the last paragraph, add a period if needed
                  process_last_paragraph(content)

                is_before_selection ->
                  # Only process entities around selection lists
                  process_content_before_selection(content)

                true ->
                  # For regular paragraphs, only handle entity adjacency and hardbreaks
                  process_regular_paragraph(content)
              end

            Map.put(paragraph, "content", updated_content)

          # Handle headings similarly
          %{"type" => "heading", "content" => content} ->
            updated_content = process_regular_paragraph(content)
            Map.put(paragraph, "content", updated_content)

          _ ->
            paragraph
        end
      end)

    Map.put(doc, "content", updated_paragraphs)
  end

  # Process the last paragraph of the document - add period only if needed
  defp process_last_paragraph(content) when is_list(content) do
    # First, handle entity adjacency and hardbreaks for consistent rendering
    processed_content = process_regular_paragraph(content)

    # Get the last non-empty node and its index
    {last_non_empty_node, last_non_empty_index} = find_last_substantive_node(processed_content)

    # Check if we need to add a period
    if should_add_period?(last_non_empty_node, processed_content, last_non_empty_index) do
      # Add the period in the correct location
      add_period_at_proper_location(processed_content, last_non_empty_node, last_non_empty_index)
    else
      # No need to add a period
      processed_content
    end
  end

  # Check if we should add a period based on the last substantive node
  defp should_add_period?(last_node, content, index) do
    case last_node do
      # No substantive node found
      nil ->
        false

      # For text nodes, check if they already end with a period
      %{"type" => "text", "text" => text} ->
        trimmed = String.trim_trailing(text)
        not String.ends_with?(trimmed, ".")

      # For entity nodes (with marks), always add a period unless there's text with a period after it
      %{"marks" => _} ->
        # Check if there's only whitespace after this entity
        only_whitespace_after = only_whitespace_after_node?(content, index)
        # Only add period if there's only whitespace after this entity
        only_whitespace_after

      # For hardBreak nodes, don't add a period
      %{"type" => "hardBreak"} ->
        false

      # Default case - add a period for other node types
      _ ->
        true
    end
  end

  # Helper to check if there's only whitespace after an index
  defp only_whitespace_after_node?(content, index) do
    # Get all nodes after the index
    remaining_nodes = Enum.slice(content, (index + 1)..-1)

    # Check if all remaining nodes are empty or whitespace-only text nodes
    Enum.all?(remaining_nodes, fn node ->
      case node do
        %{"type" => "text", "text" => text} ->
          # The node is a text node with only whitespace
          String.trim(text) == ""

        _ ->
          false
      end
    end)
  end

  # Add a period in the proper location - after entity but before any whitespace
  defp add_period_at_proper_location(content, last_substantive_node, index) do
    # If the last substantive node is an entity, we want to add the period right after it
    if has_entity_mark?(last_substantive_node) do
      # If there are nodes after this entity, try to use the first whitespace node
      if index < length(content) - 1 do
        # This will handle inserting the period in the first text node after the entity
        insert_period_after_entity(content, index)
      else
        # If entity is the last node, just append a period
        content ++ [%{"type" => "text", "text" => "."}]
      end
    else
      # Regular case - just append a period at the end
      content ++ [%{"type" => "text", "text" => "."}]
    end
  end

  # Insert a period after an entity, using the first available text node if possible
  defp insert_period_after_entity(content, entity_index) do
    # Look for the first text node after the entity
    text_node_index = find_first_text_node_after(content, entity_index)

    if text_node_index do
      # We found a text node, modify it to have a period at the start
      content
      |> Enum.with_index()
      |> Enum.map(fn {node, idx} ->
        if idx == text_node_index do
          # Add period at the start of this text node
          %{node | "text" => "." <> node["text"]}
        else
          node
        end
      end)
    else
      # No text node found, append a new one with period
      content ++ [%{"type" => "text", "text" => "."}]
    end
  end

  # Find the first text node after a specific index
  defp find_first_text_node_after(content, start_index) do
    # Get all nodes after the start index - using proper range syntax for Elixir 1.16.2
    remaining = Enum.slice(content, (start_index + 1)..length(content)//1)

    # Find the first text node
    case Enum.find_index(remaining, fn node -> node["type"] == "text" end) do
      nil -> nil
      found_idx -> start_index + 1 + found_idx
    end
  end

  # Enhanced helper to find the last substantive node and its index
  defp find_last_substantive_node(content) when is_list(content) and length(content) > 0 do
    # Enumerate with index in reverse
    Enum.reverse(content)
    |> Enum.with_index()
    |> Enum.find_value({nil, nil}, fn {node, rev_idx} ->
      # Calculate the original index (since we're working with reversed list)
      original_idx = length(content) - 1 - rev_idx

      case node do
        # Skip empty text nodes
        %{"type" => "text", "text" => ""} ->
          false

        # Skip text nodes with only whitespace
        %{"type" => "text", "text" => text} ->
          if String.trim(text) == "", do: false, else: {node, original_idx}

        # All other nodes are considered substantive
        _ ->
          {node, original_idx}
      end
    end)
  end

  # Default when empty
  defp find_last_substantive_node(_), do: {nil, nil}

  # Process content before selection lists - don't add extra whitespace
  defp process_content_before_selection(content) when is_list(content) do
    # Process hardbreaks and handle entity adjacency
    processed_content = process_regular_paragraph(content)

    # No whitespace added at end - all commented out as requested
    processed_content
  end

  # Helper to ensure selection lists render properly
  defp ensure_selection_lists_render(%{"type" => "doc", "content" => content} = doc) do
    # Check for paragraphs that are followed by selection lists
    updated_content =
      Enum.with_index(content)
      |> Enum.map(fn {node, idx} ->
        next_is_selection_list =
          idx < length(content) - 1 &&
            Enum.at(content, idx + 1)["type"] == "selectionList"

        # For paragraphs before selection lists, ensure there's whitespace at the end
        if node["type"] == "paragraph" && next_is_selection_list &&
             node["content"] && is_list(node["content"]) do
          # Get the last text node
          last_text_node = find_last_text_node(node["content"])

          if last_text_node do
            # Add whitespace to the last text node if needed
            updated_content = ensure_whitespace_at_end(node["content"])
            Map.put(node, "content", updated_content)
          else
            node
          end
        else
          # Handle legacy format selection lists
          if node["type"] == "list" && is_list(node["marks"]) do
            selection_mark =
              Enum.find(node["marks"], fn mark ->
                mark["type"] == "coloredEntity" &&
                  get_in(mark, ["attrs", "entityType"]) == "selection_list"
              end)

            if selection_mark do
              # Convert list to a selectionList node with proper structure
              entity_list = get_in(selection_mark, ["attrs", "entityList"]) || []

              # Log the conversion for debugging
              Logger.debug("Converting list with selection_list marks to selectionList node")

              %{
                "type" => "selectionList",
                "attrs" => %{
                  "entityList" => entity_list
                }
              }
            else
              node
            end
          else
            node
          end
        end
      end)

    Map.put(doc, "content", updated_content)
  end

  defp analyze_document_structure(paragraphs) do
    # Find indices of selection lists and the paragraphs just before them
    {selection_indices, before_selection_indices} =
      paragraphs
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {node, idx}, {sel_indices, before_sel_indices} ->
        if node["type"] == "selectionList" do
          # Add this index to selection_indices
          sel_indices = [idx | sel_indices]
          # If not the first paragraph, add previous paragraph to before_selection_indices
          before_sel_indices =
            if idx > 0, do: [idx - 1 | before_sel_indices], else: before_sel_indices

          {sel_indices, before_sel_indices}
        else
          {sel_indices, before_sel_indices}
        end
      end)

    # Find the last paragraph (not a selectionList)
    last_paragraph_index =
      paragraphs
      |> Enum.with_index()
      |> Enum.filter(fn {node, _} -> node["type"] == "paragraph" end)
      |> Enum.map(fn {_, idx} -> idx end)
      |> Enum.max(fn -> -1 end)

    # Return document structure information
    %{
      selection_indices: selection_indices,
      before_selection_indices: before_selection_indices,
      last_paragraph_index: last_paragraph_index,
      has_selection_lists: length(selection_indices) > 0
    }
  end

  # Helper to find the last text node in a content array
  defp find_last_text_node(content) when is_list(content) do
    Enum.reverse(content)
    |> Enum.find(fn
      %{"type" => "text"} -> true
      _ -> false
    end)
  end

  # Process regular paragraphs - only handle entity adjacency and hardbreaks
  defp process_regular_paragraph(content) when is_list(content) do
    # Handle entities at the start of paragraphs with improved empty text node detection
    content_with_fixed_start =
      case content do
        [] ->
          content

        # Case 1: Entity is the first node - add space before it
        [%{"marks" => marks} = entity_node | rest]
        when is_list(marks) and length(marks) > 0 ->
          # Entity is first node in paragraph - add space BEFORE it to ensure rendering
          [%{"type" => "text", "text" => " "}, entity_node | rest]

        # Case 2: Empty text node followed by entity - add space to the empty text node
        [%{"type" => "text", "text" => ""} = empty_text, %{"marks" => marks} = entity_node | rest]
        when is_list(marks) and length(marks) > 0 ->
          # Replace empty text node with one containing a space
          [%{"type" => "text", "text" => " "}, entity_node | rest]

        # Case 3: Text node with only whitespace followed by entity - moved String.trim out of guard
        [
          %{"type" => "text", "text" => text} = text_node,
          %{"marks" => marks} = entity_node | rest
        ]
        when is_list(marks) and length(marks) > 0 ->
          # Check for whitespace-only text in function body instead of guard
          if String.trim(text) == "" do
            # Ensure text node has at least one space
            [%{"type" => "text", "text" => " "}, entity_node | rest]
          else
            # Keep original nodes if text contains non-whitespace characters
            [text_node, entity_node | rest]
          end

        # Default case - no change needed
        _ ->
          content
      end

    content_with_hardbreak_spaces = process_hardbreaks(content_with_fixed_start)

    # Process entities that are directly adjacent to each other
    insert_separators_between_adjacent_entities(content_with_hardbreak_spaces)
  end

  # Improved hardbreak processing - Properly handle whitespace BEFORE entities that follow hardBreaks
  defp process_hardbreaks(content) do
    # Track hardbreak positions to insert spaces properly
    {result, _i} =
      Enum.reduce(content, {[], 0}, fn node, {acc, index} ->
        cond do
          # If this is a hardBreak, add it to the result
          node["type"] == "hardBreak" ->
            # First add the hardBreak node
            new_acc = acc ++ [node]

            # Look ahead to see if an entity follows (possibly after empty text nodes)
            entity_follows = has_entity_after_hardbreak?(content, index)

            if entity_follows do
              # Add a whitespace text node AFTER the hardBreak
              {new_acc ++ [%{"type" => "text", "text" => " "}], index + 1}
            else
              {new_acc, index + 1}
            end

          # Skip empty text nodes that immediately follow hardBreaks if we already added a space
          node["type"] == "text" && node["text"] == "" &&
            index > 0 &&
              Enum.at(content, index - 1)["type"] == "hardBreak" ->
            # Skip this empty text node as we're handling spacing explicitly
            {acc, index + 1}

          # For all other nodes, add them normally
          true ->
            {acc ++ [node], index + 1}
        end
      end)

    result
  end

  # Helper to check if an entity follows a hardBreak (possibly after empty text nodes)
  defp has_entity_after_hardbreak?(content, hardbreak_index) do
    remaining = Enum.slice(content, hardbreak_index + 1, length(content))

    # Skip any empty text nodes
    entity_index =
      Enum.find_index(remaining, fn node ->
        # Stop at first non-empty text node or entity
        node["type"] != "text" || (node["type"] == "text" && node["text"] != "") ||
          has_entity_mark?(node)
      end)

    if entity_index do
      entity_node = Enum.at(remaining, entity_index)
      # Return true if it's an entity
      has_entity_mark?(entity_node)
    else
      false
    end
  end

  # Simplify the separator insertion to focus only on boundaries between entities
  defp insert_separators_between_adjacent_entities(nodes) do
    # First, identify all entity nodes with precise structure
    nodes_with_entity_info =
      Enum.with_index(nodes)
      |> Enum.map(fn {node, index} ->
        current_is_entity = has_entity_mark?(node)
        # Get previous node's entity status
        prev_was_entity =
          if index > 0 do
            has_entity_mark?(Enum.at(nodes, index - 1))
          else
            false
          end

        {node, current_is_entity, prev_was_entity}
      end)

    # Now process nodes, adding separators only between adjacent entities
    Enum.reduce(nodes_with_entity_info, [], fn
      # Current node is entity, previous was entity - add separator
      {node, true, true}, acc ->
        # Add space separator between entities
        acc ++ [node]

      # Entity after hardBreak - check condition in function body, not in guard
      {node, true, false}, acc ->
        # Check if the last element is a hardBreak - moved from guard to function body
        if length(acc) > 0 && is_hardbreak_node?(List.last(acc)) do
          # Add space before entity following hardBreak
          acc ++ [node]
        else
          # No special handling needed
          acc ++ [node]
        end

      # All other cases - just add the node without extra spacing
      {node, _, _}, acc ->
        acc ++ [node]
    end)
  end

  # Helper to check if a node is a hardBreak node - add this new function
  defp is_hardbreak_node?(%{"type" => "hardBreak"}), do: true
  defp is_hardbreak_node?(_), do: false

  # Helper to ensure whitespace at the end of content - don't add whitespace
  defp ensure_whitespace_at_end(content) when is_list(content) do
    # Simply return content without modification - no whitespace added
    content
  end

  # Helper to extract plain text from various formats
  defp extract_plain_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map(&extract_plain_text/1)
    |> Enum.join("\n")
  end

  defp extract_plain_text(%{"type" => "paragraph", "content" => content}) when is_list(content) do
    content
    |> Enum.map(&extract_plain_text/1)
    |> Enum.join("")
  end

  defp extract_plain_text(%{"type" => "text", "text" => text}) when is_binary(text) do
    text
  end

  defp extract_plain_text(%{"text" => text}) when is_binary(text) do
    text
  end

  defp extract_plain_text(content) when is_binary(content) do
    content
  end

  defp extract_plain_text(_) do
    ""
  end

  defp update_entity_in_node(%{"marks" => marks} = node, entity_id, attrs)
       when is_list(marks) do
    {updated_marks, found} =
      Enum.map_reduce(marks, false, fn mark, found ->
        if mark["type"] == "coloredEntity" &&
             get_in(mark, ["attrs", "entityId"]) == entity_id do
          # ...existing code to build updated_attrs with displayText/currentText/color...
          updated_attrs =
            mark["attrs"]
            |> maybe_update_attr("displayText", Map.get(attrs, :display_text))
            |> maybe_update_attr("currentText", Map.get(attrs, :replacement))
            |> maybe_update_attr("entityColor", Map.get(attrs, :color))

          existing_repls = Map.get(mark["attrs"], "replacements", [])

          if is_list(existing_repls) do
            old_text =
              Map.get(mark["attrs"], "currentText") ||
                Map.get(mark["attrs"], "displayText") ||
                Map.get(mark["attrs"], "originalText")

            new_text = Map.get(attrs, :replacement)

            merged =
              existing_repls
              |> Enum.reject(&(&1 == new_text))
              |> Kernel.++([old_text])
              |> Enum.uniq()

            updated_attrs = Map.put(updated_attrs, "replacements", merged)
          end

          {Map.put(mark, "attrs", updated_attrs), true}
        else
          {mark, found}
        end
      end)

    if found, do: Map.put(node, "marks", updated_marks), else: node
  end

  # Helper to update an attribute only if a non-nil value is provided
  defp maybe_update_attr(attrs, _key, nil), do: attrs
  defp maybe_update_attr(attrs, key, value), do: Map.put(attrs, key, value)

  # Helper to check if a node is a text node
  defp is_text_node?(%{"type" => "text"}), do: true
  defp is_text_node?(_), do: false

  # Helper to check if a node has entity marks
  defp has_entity_mark?(%{"marks" => marks}) when is_list(marks) do
    Enum.any?(marks, fn mark -> Map.get(mark, "type") == "coloredEntity" end)
  end

  defp has_entity_mark?(_), do: false
end
