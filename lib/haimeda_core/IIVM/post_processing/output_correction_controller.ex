defmodule PostProcessing.OutputCorrectionController do
  alias PostProcessing.{
    VerificationStateManager
  }

  def correct_output do
    original_output_text = VerificationStateManager.get_current_response()
    input_entities = VerificationStateManager.get_input_entities_of_current_run()
    output_entities = VerificationStateManager.get_output_entities_of_current_run()

    {missing_entities, false_entities} =
      VerificationStateManager.get_current_run_missing_and_false_entities()

    # IO.inspect(missing_entities, label: "Missing Entities")
    # IO.inspect(false_entities, label: "False Entities")
    IO.inspect(original_output_text, label: "Original Output Text")

    # IO.inspect(missing_entities, label: "Missing Entities")

    filtered_input_entities =
      Enum.map(input_entities, fn entity ->
        %{entity: entity.entity, type: entity.type, representations: entity.representations}
      end)

    # IO.inspect(filtered_input_entities, label: "Input Entities (Filtered)")

    filtered_output_entities =
      Enum.map(output_entities, fn entity ->
        %{entity: entity.entity, type: entity.type, representations: entity.representations}
      end)

    # IO.inspect(filtered_output_entities, label: "Output Entities (Filtered)")

    # missing entities: are contained in the input but not in the output
    # false entities: are contained in the output but not in the input

    # IO.inspect(input_entities, label: "Input Entities")
    # IO.inspect(output_entities, label: "Output Entities")

    # Check if there are exactly one missing and false entities for definitive types (:date, :identifier, :number)
    to_replace = extract_entities_to_replace(input_entities, missing_entities, output_entities)

    false_definitive_entities =
      extract_false_definitive_entities(
        false_entities,
        to_replace,
        input_entities
      )

    missing_definitive_entities = extract_missing_definitive_entities(missing_entities)

    {false_inconclusive_entities, missing_inconclusive_entities} =
      process_inconclusive_entities(
        input_entities,
        output_entities,
        missing_entities,
        false_entities
      )

    # filter output entities for not already occurring in the lists of false_definitive_entities and to_replace
    filtered_output_definitive_entities =
      filter_output_definitive_entities(output_entities, false_definitive_entities, to_replace)

    # IO.inspect(
    #   filtered_output_definitive_entities,
    #   label: "Filtered Output Definitive Entities"
    # )

    output_definitive_entities_with_alternatives =
      generate_alternatives_for_output_entities(
        input_entities,
        filtered_output_definitive_entities,
        true,
        nil
      )

    # filter false_inconclusive_entities so that non of the output entity texts of to_replace or false_definitive_entities
    # are already contained somewhere in to_replace or false_definitive_entities, so that we get no overlapping
    filtered_false_inconclusive_entities =
      filter_false_inconclusive_entities(
        false_inconclusive_entities,
        false_definitive_entities,
        to_replace
      )

    output_inconclusive_entities_with_alternatives =
      generate_alternatives_for_output_entities(
        input_entities,
        filtered_false_inconclusive_entities,
        false,
        [:statement, :phrase]
      )

    # Store the original unmodified text before any replacements
    original_full_text = original_output_text

    # Create formatted content ensuring original text is preserved

    # drop down menu for entities in text,
    # when replaced display the original text and other entities of same type in the menu
    # by default, don't replace phrase or statement entities

    # colors:
    # violet: replaced entities
    # red: false, not replaced entities
    # green: correct, not replaced entities

    # For debugging - inspect the processed lists
    # IO.inspect(to_replace, label: "To Replace")
    # IO.inspect(false_definitive_entities, label: "False Definitive Entities")
    # IO.inspect(missing_definitive_entities, label: "Missing Definitive Entities")

    # IO.inspect(missing_inconclusive_entities, label: "Missing Inconclusive Entities")

    # IO.inspect(output_definitive_entities_with_alternatives,
    #   label: "Output Definitive Entities with Alternatives"
    # )

    # IO.inspect(false_inconclusive_entities, label: "False Inconclusive Entities")

    # IO.inspect(output_inconclusive_entities_with_alternatives,
    #   label: "Output Inconclusive Entities with Alternatives"
    # )

    # construct formatted output text with the replacements
    formatted_text =
      format_output_text(
        original_output_text,
        to_replace,
        false_definitive_entities,
        output_definitive_entities_with_alternatives,
        output_inconclusive_entities_with_alternatives,
        missing_definitive_entities,
        missing_inconclusive_entities
      )

    # IO.inspect(formatted_text, label: "Formatted Text")

    {:ok, formatted_text}
    # {:error, :output_correction_error}
  end

  defp extract_false_definitive_entities(false_entities, to_replace, input_entities) do
    # Group input entities by type for easier lookup
    input_by_type = Enum.group_by(input_entities, & &1.type)

    # Process each type in false_entities
    false_entities
    |> Enum.flat_map(fn {type, entities} ->
      # Get input entities of this type
      input_entities_of_type = Map.get(input_by_type, type, [])

      # Only proceed if there's at least one entity of this type in input_entities
      if length(input_entities_of_type) > 0 do
        # Extract all input entity values for this type
        input_entity_values = Enum.map(input_entities_of_type, & &1.entity)
        input_entity_set = MapSet.new(input_entity_values)

        # Process each entity of this type from false_entities
        Enum.flat_map(entities, fn entity ->
          # Check if this entity doesn't exist in input_entities
          entity_not_in_input = not MapSet.member?(input_entity_set, entity.entity)

          # Check if this entity isn't already in to_replace as an output_entity
          entity_not_in_to_replace =
            not Enum.any?(to_replace, &(&1.output_entity == entity.entity))

          # If conditions are met, create the extraction entry
          if entity_not_in_input and entity_not_in_to_replace do
            [
              %{
                # Keep type as an atom (don't convert to string)
                type: type,
                input_entities: input_entity_values,
                output_entity: entity.entity
              }
            ]
          else
            # Skip this entity if conditions aren't met
            []
          end
        end)
      else
        # Skip this type if no matching entities in input_entities
        []
      end
    end)
  end

  defp extract_missing_definitive_entities(missing_entities) do
    definitive_types = [:date, :identifier, :number]

    missing_definitive_entities =
      definitive_types
      |> Enum.flat_map(fn type ->
        # Get entities for this type, handling both atom and string keys
        entities =
          case Map.get(missing_entities, type) do
            nil -> Map.get(missing_entities, to_string(type), [])
            val -> val
          end

        # Transform to the desired format
        Enum.map(entities, fn entity ->
          %{type: type, input_entity: entity.entity}
        end)
      end)
  end

  defp extract_entities_to_replace(input_entities, missing_entities, output_entities) do
    # Filter out any entries that are not maps or don't have a type field
    filtered_input = Enum.filter(input_entities, &(is_map(&1) && Map.has_key?(&1, :type)))
    filtered_output = Enum.filter(output_entities, &(is_map(&1) && Map.has_key?(&1, :type)))

    # Group input and output entities by type
    input_by_type = Enum.group_by(filtered_input, & &1.type)
    output_by_type = Enum.group_by(filtered_output, & &1.type)

    # Get all unique types from both inputs and outputs
    input_types = Map.keys(input_by_type)
    output_types = Map.keys(output_by_type)
    # Handle atom keys in missing_entities
    missing_types = Map.keys(missing_entities) |> Enum.map(& &1)

    all_types = (input_types ++ output_types ++ missing_types) |> Enum.uniq()

    # Define definitive entity types
    definitive_types = [:date, :identifier, :number]

    # Process each type to find replacement candidates
    Enum.flat_map(all_types, fn type ->
      # Only proceed if this is a definitive type
      if type in definitive_types do
        # Get entities of this type from each collection
        input_entities_of_type = Map.get(input_by_type, type, [])
        output_entities_of_type = Map.get(output_by_type, type, [])

        # For missing_entities, we need to handle both atom and string keys
        missing_entities_of_type =
          case Map.get(missing_entities, type) do
            nil -> Map.get(missing_entities, to_string(type), [])
            val -> val
          end

        cond do
          # If there's exactly one input entity of this type (regardless of missing entities)
          length(input_entities_of_type) == 1 ->
            # Get the single input entity
            input_entity = List.first(input_entities_of_type)

            # For each output entity of the same type that doesn't match the input entity's value
            Enum.flat_map(output_entities_of_type, fn output_entity ->
              if output_entity.entity != input_entity.entity do
                [
                  %{
                    type: type,
                    input_entity: input_entity.entity,
                    output_entity: output_entity.entity
                  }
                ]
              else
                []
              end
            end)

          # Skip this type if we don't have exactly one input entity
          true ->
            []
        end
      else
        # Skip non-definitive types
        []
      end
    end)
  end

  # Filter output entities to only include definitive types not already in other lists
  defp filter_output_definitive_entities(output_entities, false_definitive_entities, to_replace) do
    # Define definitive entity types
    definitive_types = [:date, :identifier, :number]

    # Get the entity texts that should be excluded (already handled)
    # Get texts from false_definitive_entities
    # Get texts from to_replace
    exclude_texts =
      (Enum.map(false_definitive_entities, & &1.output_entity) ++
         Enum.map(to_replace, & &1.output_entity))
      |> MapSet.new()

    # Filter output entities
    output_entities
    |> Enum.filter(fn entity ->
      # Only include definitive types
      # Exclude entities that are already in other lists
      entity.type in definitive_types &&
        not MapSet.member?(exclude_texts, entity.entity)
    end)
  end

  # Filter inconclusive entities to exclude those containing texts from definitive entities
  defp filter_false_inconclusive_entities(
         false_inconclusive_entities,
         false_definitive_entities,
         to_replace
       ) do
    # Get all output entity texts from false_definitive_entities and to_replace
    definitive_entity_texts =
      ((false_definitive_entities |> Enum.map(& &1.output_entity)) ++
         (to_replace |> Enum.map(& &1.output_entity)))
      |> MapSet.new()

    # Filter false_inconclusive_entities
    false_inconclusive_entities
    |> Enum.filter(fn inconclusive ->
      # Check if the inconclusive entity output text contains any definitive entity text
      not Enum.any?(definitive_entity_texts, fn definitive_text ->
        String.contains?(inconclusive.output_entity, definitive_text)
      end)
    end)
  end

  def generate_alternatives_for_output_entities(
        input_entities,
        output_entities,
        exclude_single_matches,
        multiple_entity_types \\ nil
      ) do
    # IO.inspect(output_entities, label: "Output Entities")

    output_entities
    |> Enum.reduce([], fn output_entity, acc ->
      # Get matching input entities based on multiple_entity_types parameter
      inputs =
        if multiple_entity_types == nil do
          # Only match the specific type
          get_matching_input_entities(input_entities, output_entity.type)
        else
          # Match any type in the provided list
          input_entities
          |> Enum.filter(fn input_entity -> input_entity.type in multiple_entity_types end)
          |> Enum.map(fn input_entity -> input_entity.entity end)
        end

      # Skip this entity if:
      # 1. Input entities list is empty (no alternatives)
      # 2. We're excluding single matches and there's less than 2 alternatives
      cond do
        Enum.empty?(inputs) ->
          acc

        exclude_single_matches and length(inputs) < 2 and length(inputs) > 0 ->
          acc

        true ->
          [
            %{
              # Use the output entity text directly
              output_entity: output_entity.entity,
              input_entities: inputs,
              type: output_entity.type
            }
            | acc
          ]
      end
    end)
    |> Enum.reverse()
  end

  defp get_matching_input_entities(input_entities, entity_type) do
    input_entities
    |> Enum.filter(fn input_entity -> input_entity.type == entity_type end)
    |> Enum.map(fn input_entity -> input_entity.entity end)
  end

  # Process entities of inconclusive types (phrase, statement)
  defp process_inconclusive_entities(
         input_entities,
         output_entities,
         missing_entities,
         false_entities
       ) do
    # Define inconclusive entity types
    inconclusive_types = [:phrase, :statement]

    # Process inconclusive entity types using reduce
    Enum.reduce(inconclusive_types, {[], []}, fn type,
                                                 {false_inconclusive_entities,
                                                  missing_inconclusive_entities} ->
      # Handle false inconclusive entities
      false_of_type = Map.get(false_entities, type, [])

      # Process false entities of this type
      new_false_inconclusive_entities =
        if length(false_of_type) > 0 do
          # Get all input entities of the same type for reference
          input_entities_of_type =
            input_entities
            |> Enum.filter(fn entity -> entity.type == type end)
            |> Enum.map(fn entity -> entity.entity end)

          # Add a new false_entry for each false entity
          Enum.reduce(false_of_type, false_inconclusive_entities, fn false_entity, acc ->
            false_entry = %{
              output_entity: false_entity.entity,
              type: type,
              input_entities: input_entities_of_type
            }

            [false_entry | acc]
          end)
        else
          false_inconclusive_entities
        end

      # Handle missing inconclusive entities
      missing_of_type = Map.get(missing_entities, type, [])

      # Process missing entities of this type
      new_missing_inconclusive_entities =
        if length(missing_of_type) > 0 do
          Enum.reduce(missing_of_type, missing_inconclusive_entities, fn missing_entity, acc ->
            missing_entry = %{
              input_entity: missing_entity.entity,
              type: type
            }

            [missing_entry | acc]
          end)
        else
          missing_inconclusive_entities
        end

      {new_false_inconclusive_entities, new_missing_inconclusive_entities}
    end)
  end

  def format_output_text(
        original_output_text,
        to_replace,
        false_definitive_entities,
        output_definitive_entities_with_alternatives,
        filtered_false_inconclusive_entities,
        missing_definitive_entities,
        missing_inconclusive_entities
      ) do
    # if nothing to do, return as before
    if Enum.all?(
         [
           to_replace,
           false_definitive_entities,
           output_definitive_entities_with_alternatives,
           filtered_false_inconclusive_entities,
           missing_definitive_entities,
           missing_inconclusive_entities
         ],
         &Enum.empty?/1
       ) do
      # %{
      #   "type" => "doc",
      #   "content" => [
      #     %{
      #       "type" => "paragraph",
      #       "content" => [%{"type" => "text", "text" => original_output_text}]
      #     }
      #   ]
      # }
      build_doc_from_placeholder_text(original_output_text)
    else
      # 1) normalize each entity into a flat list with the attrs we need
      all_entities =
        Enum.flat_map(
          [
            {to_replace, "replacement", "#d8b5ff"},
            {false_definitive_entities, "alternatives", "#ff6b6b"},
            {output_definitive_entities_with_alternatives, "alternatives", "#90ee90"},
            {filtered_false_inconclusive_entities, "alternatives", "#ffa500"}
          ],
          fn {list, entity_type, color} ->
            Enum.map(list, fn e ->
              # Generate a unique ID for each entity
              entity_id = "entity_#{:erlang.monotonic_time()}_#{:rand.uniform(1_000_000)}"

              %{
                output_text: e.output_entity,
                display_text: Map.get(e, :input_entity, e.output_entity),
                entity_type: entity_type,
                entity_color: color,
                entity_category: to_string(e.type),
                replacements: Map.get(e, :input_entities, [e.output_entity]),
                entity_id: entity_id,
                deleted: false
              }
            end)
          end
        )

      # 2) inject JSON‐placeholders into the full text (preserves newlines)
      text_with_ph = replace_entities_with_placeholders(original_output_text, all_entities)

      # 3) one‐pass rebuild: split on placeholders, decode JSON, emit nodes
      doc = build_doc_from_placeholder_text(text_with_ph)

      # 4) append three line‐breaks
      breaks = for _ <- 1..3, do: %{"type" => "hardBreak"}

      # 5) build selection_list mark for missing entities
      selection_items =
        (missing_definitive_entities ++ missing_inconclusive_entities)
        |> Enum.map(fn %{input_entity: text, type: type} = e ->
          color = if type in [:date, :identifier, :number], do: "#ff6b6b", else: "#ffa500"
          # Generate a consistent entity ID for selection items
          formatted_text = text |> String.replace(" ", "-") |> String.downcase()
          entity_id = "sel_#{formatted_text}_#{:rand.uniform(1_000_000)}"

          # Check if this entity is in to_replace's input_entity field
          is_deleted =
            Enum.any?(to_replace, fn replace_entry ->
              replace_entry.input_entity == text
            end)

          %{
            "entityId" => entity_id,
            "originalText" => text,
            "entityColor" => color,
            "deleted" => is_deleted,
            "confirmed" => false,
            "entityCategory" => type
          }
        end)

      list_mark =
        %{
          "type" => "coloredEntity",
          "attrs" => %{
            "entityType" => "selection_list",
            "entityList" => selection_items
          }
        }

      list_node = %{"type" => "list", "marks" => [list_mark]}

      # combine content
      # IO.inspect(list_node, label: "List Node")

      %{"type" => "doc", "content" => doc["content"] ++ breaks ++ [list_node]}
    end
  end

  defp replace_entities_with_placeholders(text, entities) do
    # Sort entities by text length (longest first) to avoid nested replacements
    sorted_entities = Enum.sort_by(entities, fn e -> String.length(e.output_text) end, :desc)

    # Use markers instead of direct replacement to avoid nesting
    {marked_text, markers} =
      Enum.reduce(sorted_entities, {text, %{}}, fn ent, {current_text, markers} ->
        # Create a unique marker
        marker = "§ENTITY_#{:erlang.monotonic_time()}_#{:rand.uniform(1_000_000)}§"

        # Mark the position without embedding JSON yet
        replaced_text = String.replace(current_text, ent.output_text, marker)

        # Only store mapping if replacement happened
        if replaced_text != current_text do
          # Preserve original replacements while avoiding entries that would break placeholders
          safe_repls = Enum.reject(ent.replacements || [], &String.contains?(&1, "§"))

          # Ensure there's at least one replacement
          safe_repls =
            if Enum.empty?(safe_repls),
              do: [ent.output_text],
              else: safe_repls

          # Store entity info with the marker
          entity_info = %{
            "entityType" => ent.entity_type,
            "entityColor" => ent.entity_color,
            "entityCategory" => ent.entity_category,
            "originalText" => ent.output_text,
            "currentText" => ent.display_text,
            "displayText" => ent.display_text,
            "replacements" => safe_repls,
            "entityId" => ent.entity_id,
            "deleted" => ent.deleted
          }

          # Add to markers map
          updated_markers = Map.put(markers, marker, Jason.encode!(entity_info))
          {replaced_text, updated_markers}
        else
          {current_text, markers}
        end
      end)

    # Second pass: replace markers with actual JSON placeholders
    Enum.reduce(Map.to_list(markers), marked_text, fn {marker, json}, acc ->
      String.replace(acc, marker, "§" <> json <> "§")
    end)
  end

  defp build_doc_from_placeholder_text(text) do
    # First split text on placeholder markers
    parts = Regex.split(~r/(§.*?§)/s, text, include_captures: true)
    # IO.inspect(parts, label: "Initial Parts")

    # First pass: repair broken JSON fragments
    {fixed_parts, _} =
      Enum.reduce(parts, {[], false}, fn part, {acc, in_fragment} ->
        cond do
          # Start of a fragment
          String.starts_with?(part, "§{") and not String.ends_with?(part, "}§") ->
            # Start collecting in the accumulator
            {acc, part}

          # Continuation of a fragment
          is_binary(in_fragment) ->
            joined = in_fragment <> part

            if String.ends_with?(part, "}§") do
              # Fragment is complete, add to result
              {acc ++ [joined], false}
            else
              # Keep collecting
              {acc, joined}
            end

          # No fragment in progress, regular part
          true ->
            {acc ++ [part], false}
        end
      end)

    # IO.inspect(fixed_parts, label: "Fixed Parts")

    # Second pass: cleanup and create nodes
    nodes =
      Enum.flat_map(fixed_parts, fn part ->
        cond do
          # Valid placeholder
          String.starts_with?(part, "§") and String.ends_with?(part, "§") and
              String.contains?(part, "originalText") ->
            # Remove § markers and trailing quotes
            clean_json =
              part
              |> String.trim_leading("§")
              |> String.trim_trailing("§")
              # Fix trailing quotes
              |> String.replace(~r/""\s*$/, "\"")

            # IO.inspect(clean_json, label: "Clean JSON")

            case Jason.decode(clean_json) do
              {:ok, parsed} ->
                info =
                  Map.put(
                    parsed,
                    "entityId",
                    "entity_#{:erlang.monotonic_time()}_#{:rand.uniform(1_000_000)}"
                  )

                [
                  %{
                    "type" => "text",
                    "text" => info["displayText"],
                    "marks" => [%{"type" => "coloredEntity", "attrs" => info}]
                  }
                ]

              {:error, error} ->
                IO.inspect(error, label: "JSON Error")
                # Skip this placeholder
                []
            end

          # Skip standalone JSON or fragments
          String.starts_with?(part, "{\"") ->
            []

          # Regular text
          true ->
            # Handle newlines and produce text nodes
            segments = String.split(part, "\n", trim: false)

            segments
            |> Enum.with_index()
            |> Enum.flat_map(fn {segment, idx} ->
              is_last = idx == length(segments) - 1

              cond do
                segment == "" and not is_last ->
                  [%{"type" => "hardBreak"}]

                is_last ->
                  [%{"type" => "text", "text" => segment}]

                true ->
                  [
                    %{"type" => "text", "text" => segment},
                    %{"type" => "hardBreak"}
                  ]
              end
            end)
        end
      end)

    %{"type" => "doc", "content" => [%{"type" => "paragraph", "content" => nodes}]}
  end
end
