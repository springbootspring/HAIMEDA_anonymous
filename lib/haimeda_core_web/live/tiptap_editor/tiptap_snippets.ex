defmodule HaimedaCoreWeb.ReportsEditor.TipTapSnippets do
  use HaimedaCoreWeb, :html
  require Logger

  @doc """
  Formats an entity for TipTap with replacements.
  Takes the input entity, its replacements, color, and category.
  Returns a map representing the entity with proper TipTap marks.
  """
  def format_entity_for_tiptap(
        input_text,
        replacements,
        color \\ "#d8b5ff",
        category \\ "entity",
        entity_id \\ nil
      ) do
    # Ensure replacements is properly formatted as a list
    replacements_list = format_replacements(replacements)
    entity_id = entity_id || "entity_#{:erlang.monotonic_time()}_#{:rand.uniform(1000)}"

    # Create the entity with appropriate marks
    %{
      "type" => "text",
      "text" => input_text,
      "marks" => [
        %{
          "type" => "coloredEntity",
          "attrs" => %{
            "entityId" => entity_id,
            "entityType" => "replacement",
            "entityColor" => color,
            "entityCategory" => category,
            "originalText" => input_text,
            "currentText" => input_text,
            "replacements" => replacements_list
          }
        }
      ]
    }
  end

  # Helper to ensure replacements are properly formatted
  defp format_replacements(replacements) do
    case replacements do
      list when is_list(list) -> list
      bin when is_binary(bin) -> String.split(bin, ",") |> Enum.map(&String.trim/1)
      _ -> []
    end
  end

  @doc """
  Creates a TipTap document with an entity.
  Takes a text, position to insert entity, entity text, and replacements.
  Returns a complete TipTap document with the entity integrated.
  """
  def create_tiptap_document_with_entity(text, position, entity_text, replacements) do
    {before_text, after_text} = String.split_at(text, position)

    paragraph_content =
      cond do
        before_text == "" ->
          [
            format_entity_for_tiptap(entity_text, replacements),
            %{"type" => "text", "text" => after_text}
          ]

        after_text == "" ->
          [
            %{"type" => "text", "text" => before_text},
            format_entity_for_tiptap(entity_text, replacements)
          ]

        true ->
          [
            %{"type" => "text", "text" => before_text},
            format_entity_for_tiptap(entity_text, replacements),
            %{"type" => "text", "text" => after_text}
          ]
      end

    %{
      "type" => "doc",
      "content" => [
        %{
          "type" => "paragraph",
          "content" => paragraph_content
        }
      ]
    }
  end

  # Helper function to split text into paragraph text nodes
  def split_text_into_paragraphs(text) do
    text
    |> String.split("\n")
    |> Enum.map(&%{"type" => "text", "text" => &1})
  end

  @doc """
  Gets all entities from TipTap formatted content.
  Returns a list of entity maps with their positions and attributes.
  """
  def get_entities_from_formatted_content(formatted_content) when is_map(formatted_content) do
    try do
      extract_entities(formatted_content)
    rescue
      e ->
        Logger.error("Error extracting entities: #{inspect(e)}")
        []
    end
  end

  def get_entities_from_formatted_content(_), do: []

  # Helper to extract entities from content
  defp extract_entities(%{"content" => content}) when is_list(content) do
    content
    |> Enum.with_index()
    |> Enum.flat_map(fn {block, block_idx} ->
      case block do
        %{"content" => block_content} when is_list(block_content) ->
          extract_entities_from_block(block_content, block_idx)

        _ ->
          []
      end
    end)
  end

  defp extract_entities(%{}), do: []

  # Extract entities from a content block
  defp extract_entities_from_block(content, block_idx) do
    content
    |> Enum.with_index()
    |> Enum.flat_map(fn {node, node_idx} ->
      case node do
        %{"marks" => marks, "text" => text} when is_list(marks) ->
          entity_mark = Enum.find(marks, &(&1["type"] == "coloredEntity"))

          if entity_mark do
            attrs = Map.get(entity_mark, "attrs", %{})

            [
              %{
                position: {block_idx, node_idx},
                text: text,
                attrs: attrs
              }
            ]
          else
            []
          end

        _ ->
          []
      end
    end)
  end
end
