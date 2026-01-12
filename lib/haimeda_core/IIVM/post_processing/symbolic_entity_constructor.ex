defmodule PostProcessing.SymbolicEntityConstructor do
  alias PostProcessing.HelperFunctions, as: HF
  alias PostProcessing.VerificationStateManager

  def detect_all_patterns(data) do
    date_patterns = detect_pattern_entities(data, :date)
    number_patterns = detect_pattern_entities(data, :number)
    identifier_patterns = detect_pattern_entities(data, :identifier)
    phrase_patterns = detect_pattern_entities(data, :phrase)
    statements = detect_pattern_entities(data, :statement)

    # Combine all patterns into a single list
    all_patterns =
      date_patterns ++ number_patterns ++ identifier_patterns ++ phrase_patterns ++ statements

    # Filter all input and output patterns, and return them separated
    input_patterns = Enum.filter(all_patterns, fn pattern -> pattern.source == :input end)
    output_patterns = Enum.filter(all_patterns, fn pattern -> pattern.source == :output end)

    {input_patterns, output_patterns}
  end

  def detect_pattern_entities(data, type) do
    # Process all items and collect their date patterns
    combined_patterns =
      Enum.reduce(data, %{}, fn item, acc ->
        case item do
          {input_data, :input, location} ->
            # Process input data and extract date patterns
            date_patterns =
              case location do
                :meta_data ->
                  # Extract date patterns from metadata
                  # format: %{device_info/basic_info}
                  #         > {"key": "value"}
                  meta_data_patterns =
                    Enum.reduce(input_data, [], fn {key, value}, acc ->
                      # Ensure value is a string before cleaning it
                      clean_value =
                        cond do
                          is_binary(value) ->
                            Regex.replace(~r/[\n\r\t\s]+/, value, " ")

                          is_boolean(value) || is_nil(value) ->
                            to_string(value)

                          true ->
                            to_string(value)
                        end

                      patterns =
                        if type != :statement do
                          extract_patterns(clean_value, type)
                        else
                          []
                        end

                      if Enum.empty?(patterns) do
                        # No patterns found, return accumulator unchanged
                        acc
                      else
                        entities =
                          Enum.map(patterns, fn pattern ->
                            %{
                              # %{key => value},
                              entity: value,
                              id: VerificationStateManager.create_unique_id(),
                              type: type,
                              source: :input,
                              location: location,
                              status: :not_tested,
                              detected_in: nil,
                              representations: create_derivations(pattern, type)
                            }
                          end)

                        acc ++ entities
                      end
                    end)

                  meta_data_patterns

                :chapter_info ->
                  # Extract date patterns from chapter info
                  # format: text
                  clean_data =
                    cond do
                      is_binary(input_data) ->
                        Regex.replace(~r/[\n\r\t\s]+/, input_data, " ")

                      is_boolean(input_data) || is_nil(input_data) ->
                        to_string(input_data)

                      true ->
                        to_string(input_data)
                    end

                  patterns = extract_patterns(input_data, type)

                  if Enum.empty?(patterns) do
                    # No patterns found, return empty list
                    []
                  else
                    Enum.map(patterns, fn pattern ->
                      %{
                        entity: pattern,
                        id: VerificationStateManager.create_unique_id(),
                        type: type,
                        source: :input,
                        location: location,
                        status: :not_tested,
                        detected_in: nil,
                        representations: create_derivations(pattern, type)
                      }
                    end)
                  end

                :previous_content ->
                  # Extract date patterns from previous chapters
                  # format: %{chapter_num, summary}
                  previous_chapter_patterns =
                    Enum.reduce(input_data, [], fn
                      {chapter_num, summary}, acc when is_binary(summary) ->
                        # Handle case where summary is a string
                        clean_data = Regex.replace(~r/[\n\r\t\s]+/, summary, " ")
                        patterns = extract_patterns(summary, type)

                        if Enum.empty?(patterns) do
                          # No patterns found, return accumulator unchanged
                          acc
                        else
                          entities =
                            Enum.map(patterns, fn pattern ->
                              %{
                                entity: pattern,
                                id: VerificationStateManager.create_unique_id(),
                                type: type,
                                source: :input,
                                location: location,
                                status: :not_tested,
                                detected_in: nil,
                                representations: create_derivations(pattern, type)
                              }
                            end)

                          acc ++ entities
                        end

                      {_, data}, acc when is_map(data) ->
                        # Handle case where data is a map with summary field
                        summary = Map.get(data, "summary") || Map.get(data, :summary) || ""
                        clean_data = Regex.replace(~r/[\n\r\t\s]+/, summary, " ")
                        patterns = extract_patterns(summary, type)

                        if Enum.empty?(patterns) do
                          # No patterns found, return accumulator unchanged
                          acc
                        else
                          entities =
                            Enum.map(patterns, fn pattern ->
                              %{
                                entity: pattern,
                                id: VerificationStateManager.create_unique_id(),
                                type: type,
                                source: :input,
                                location: location,
                                status: :not_tested,
                                detected_in: nil,
                                representations: create_derivations(pattern, type)
                              }
                            end)

                          acc ++ entities
                        end

                      _, acc ->
                        # Handle any other unexpected format
                        acc
                    end)

                  previous_chapter_patterns

                :parties_statements ->
                  # Extract date patterns from parties statements
                  # format: %{party_name, %{"content": "text", ..}}
                  parties_patterns =
                    Enum.reduce(input_data, [], fn {_party_name, statement_data}, acc ->
                      # Handle different types of statement_data - it could be a map, a string, or true/false
                      content =
                        cond do
                          is_map(statement_data) ->
                            Map.get(statement_data, "content") ||
                              Map.get(statement_data, :content, "")

                          is_binary(statement_data) ->
                            statement_data

                          true ->
                            # Convert true/false/nil to empty string to avoid errors
                            to_string(statement_data)
                        end

                      if is_binary(content) && content != "" do
                        clean_data = Regex.replace(~r/[\n\r\t\s]+/, content, " ")
                        patterns = extract_patterns(content, type)

                        if Enum.empty?(patterns) do
                          # No patterns found, return accumulator unchanged
                          acc
                        else
                          entities =
                            Enum.map(patterns, fn pattern ->
                              %{
                                entity: pattern,
                                id: VerificationStateManager.create_unique_id(),
                                type: type,
                                source: :input,
                                location: location,
                                status: :not_tested,
                                detected_in: nil,
                                representations: create_derivations(pattern, type)
                              }
                            end)

                          acc ++ entities
                        end
                      else
                        # No valid content, return accumulator unchanged
                        acc
                      end
                    end)

                  parties_patterns

                _ ->
                  # Empty list for invalid location
                  []
              end

            # Merge the date patterns into the accumulator
            Map.put(acc, location, date_patterns)

          {output_data, :output, location} ->
            # Process output data and extract date patterns
            # format: text
            clean_data =
              cond do
                is_binary(output_data) ->
                  Regex.replace(~r/[\n\r\t\s]+/, output_data, " ")

                is_boolean(output_data) || is_nil(output_data) ->
                  to_string(output_data)

                true ->
                  to_string(output_data)
              end

            patterns = extract_patterns(output_data, type)

            if Enum.empty?(patterns) do
              # No patterns found, return accumulator unchanged
              acc
            else
              entities =
                Enum.map(patterns, fn pattern ->
                  %{
                    entity: pattern,
                    id: VerificationStateManager.create_unique_id(),
                    type: type,
                    source: :output,
                    location: location,
                    status: :not_tested,
                    detected_in: nil,
                    representations: create_derivations(pattern, type)
                  }
                end)

              # Merge the output patterns into the accumulator
              Map.put(acc, location, entities)
            end

          _ ->
            # Return accumulator unchanged for invalid data
            acc
        end
      end)

    # Convert the map of patterns to a flat list of patterns
    patterns_list = Map.values(combined_patterns) |> List.flatten()
  end

  def get_combined_content(data) do
    {combined_input, combined_output} =
      Enum.reduce(data, {[], []}, fn item, {input_list, output_list} ->
        case item do
          {input_data, :input, location} ->
            case location do
              :meta_data ->
                # Extract meta data content and combine as one string
                meta_data_content_case_sensitive =
                  input_data
                  |> Enum.map(fn {_key, value} ->
                    cond do
                      is_binary(value) -> value
                      true -> to_string(value)
                    end
                  end)
                  |> Enum.map(fn str -> Regex.replace(~r/[\n\r\t\s]+/, str, " ") end)

                meta_data_content_case_insensitive =
                  input_data
                  |> Enum.map(fn {_key, value} ->
                    cond do
                      is_binary(value) -> value
                      true -> to_string(value)
                    end
                  end)
                  |> Enum.map(&String.downcase/1)
                  |> Enum.map(fn str -> Regex.replace(~r/[\n\r\t\s]+/, str, " ") end)

                {input_list ++
                   meta_data_content_case_sensitive ++ meta_data_content_case_insensitive,
                 output_list}

              :chapter_info ->
                chapter_info_content_case_sensitive =
                  input_data
                  |> (fn value ->
                        cond do
                          is_binary(value) -> value
                          true -> to_string(value)
                        end
                      end).()
                  |> (fn str -> Regex.replace(~r/[\n\r\t\s]+/, str, " ") end).()

                chapter_info_content_case_insensitive =
                  input_data
                  |> (fn value ->
                        cond do
                          is_binary(value) -> value
                          true -> to_string(value)
                        end
                      end).()
                  |> String.downcase()
                  |> (fn str -> Regex.replace(~r/[\n\r\t\s]+/, str, " ") end).()

                {input_list ++
                   [chapter_info_content_case_sensitive] ++
                   [chapter_info_content_case_insensitive], output_list}

              :parties_statements ->
                # Extract parties statements content and combine as one string
                parties_statements_content_case_sensitive =
                  input_data
                  |> Enum.map(fn {_party_name, statement_data} ->
                    cond do
                      is_map(statement_data) ->
                        Map.get(statement_data, "content") ||
                          Map.get(statement_data, :content, "")

                      is_binary(statement_data) ->
                        statement_data

                      true ->
                        # Convert true/false/nil to empty string
                        to_string(statement_data)
                    end
                  end)
                  |> Enum.filter(&is_binary/1)
                  |> Enum.map(&to_string/1)
                  |> Enum.map(fn str -> Regex.replace(~r/[\n\r\t\s]+/, str, " ") end)

                parties_statements_content_case_insensitive =
                  input_data
                  |> Enum.map(fn {_party_name, statement_data} ->
                    cond do
                      is_map(statement_data) ->
                        Map.get(statement_data, "content") ||
                          Map.get(statement_data, :content, "")

                      is_binary(statement_data) ->
                        statement_data

                      true ->
                        # Convert true/false/nil to empty string
                        to_string(statement_data)
                    end
                  end)
                  |> Enum.filter(&is_binary/1)
                  |> Enum.map(&to_string/1)
                  |> Enum.map(&String.downcase/1)
                  |> Enum.map(fn str -> Regex.replace(~r/[\n\r\t\s]+/, str, " ") end)

                {input_list ++
                   parties_statements_content_case_sensitive ++
                   parties_statements_content_case_insensitive, output_list}

              :previous_content ->
                # Extract previous chapters content and combine as one string
                previous_chapters_content_case_sensitive =
                  input_data
                  |> Enum.map(fn {_chapter_num, chapter_map} ->
                    Map.get(chapter_map, "summary", "")
                  end)
                  |> Enum.map(&to_string/1)
                  |> Enum.map(fn str -> Regex.replace(~r/[\n\r\t\s]+/, str, " ") end)

                previous_chapters_content_case_insensitive =
                  input_data
                  |> Enum.map(fn {_chapter_num, chapter_map} ->
                    Map.get(chapter_map, "summary", "")
                  end)
                  |> Enum.map(&to_string/1)
                  |> Enum.map(&String.downcase/1)
                  |> Enum.map(fn str -> Regex.replace(~r/[\n\r\t\s]+/, str, " ") end)

                {input_list ++
                   previous_chapters_content_case_sensitive ++
                   previous_chapters_content_case_insensitive, output_list}
            end

          {output_data, :output, location} ->
            output_content_case_sensitive =
              output_data
              |> (fn value ->
                    cond do
                      is_binary(value) -> value
                      true -> to_string(value)
                    end
                  end).()
              |> (fn str -> Regex.replace(~r/[\n\r\t\s]+/, str, " ") end).()

            output_content_case_insensitive =
              output_data
              |> (fn value ->
                    cond do
                      is_binary(value) -> value
                      true -> to_string(value)
                    end
                  end).()
              |> String.downcase()
              |> (fn str -> Regex.replace(~r/[\n\r\t\s]+/, str, " ") end).()

            {input_list,
             output_list ++ [output_content_case_sensitive] ++ [output_content_case_insensitive]}
        end
      end)
  end

  def get_combined_statement_content(data) do
    {combined_input, combined_output} =
      Enum.reduce(data, {[], []}, fn item, {input_list, output_list} ->
        case item do
          {input_data, :input, location} ->
            case location do
              :meta_data ->
                # don't extract meta data content, just return the input list

                {input_list, output_list}

              :chapter_info ->
                chapter_info_content_case_sensitive =
                  input_data
                  |> to_string()
                  |> (fn str -> Regex.replace(~r/[\n\r\t\s]+/, str, " ") end).()

                {input_list ++
                   [chapter_info_content_case_sensitive], output_list}

              :parties_statements ->
                # Extract parties statements content and combine as one string
                parties_statements_content_case_sensitive =
                  input_data
                  |> Enum.map(fn {_party_name, statement_data} ->
                    cond do
                      is_map(statement_data) ->
                        Map.get(statement_data, "content") ||
                          Map.get(statement_data, :content, "")

                      is_binary(statement_data) ->
                        statement_data

                      true ->
                        # Convert true/false/nil to empty string
                        ""
                    end
                  end)
                  |> Enum.filter(&is_binary/1)
                  |> Enum.map(&to_string/1)
                  |> Enum.map(fn str -> Regex.replace(~r/[\n\r\t\s]+/, str, " ") end)

                {input_list ++
                   parties_statements_content_case_sensitive, output_list}

              :previous_content ->
                # Extract previous chapters content and combine as one string
                previous_chapters_content_case_sensitive =
                  input_data
                  |> Enum.map(fn {_chapter_num, chapter_map} ->
                    Map.get(chapter_map, "summary", "")
                  end)
                  |> Enum.map(&to_string/1)
                  |> Enum.map(fn str -> Regex.replace(~r/[\n\r\t\s]+/, str, " ") end)

                {input_list ++
                   previous_chapters_content_case_sensitive, output_list}
            end

          {output_data, :output, location} ->
            output_content_case_sensitive =
              output_data
              |> to_string()
              |> (fn str -> Regex.replace(~r/[\n\r\t\s]+/, str, " ") end).()

            {input_list, output_list ++ [output_content_case_sensitive]}
        end
      end)
  end

  def extract_patterns(data, type) do
    case type do
      :date ->
        HF.extract_date_patterns(data)

      :number ->
        HF.extract_number_patterns(data)

      :identifier ->
        HF.extract_identifier_patterns(data)

      :phrase ->
        HF.extract_phrase_patterns(data)

      :statement ->
        HF.extract_statements(data)

      _ ->
        []
    end
  end

  def create_derivations(pattern, type) do
    case type do
      :date ->
        HF.create_date_derivations(pattern)

      :number ->
        HF.create_number_derivations(pattern)

      :identifier ->
        HF.create_identifier_derivations(pattern)

      :phrase ->
        HF.create_phrase_derivations(pattern)

      :statement ->
        []

      _ ->
        []
    end
  end
end
