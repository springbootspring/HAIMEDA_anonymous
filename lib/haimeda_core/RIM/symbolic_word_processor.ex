defmodule RIM.SymbolicWordProcessor do
  @moduledoc """
  This module provides functions to extract keyword from a given user question or request.
  """
  alias RIM.ResourceAgent

  @path_resources Path.join(__DIR__, "resources")
  @files [
    "Auftraggeber",
    "Geräteart",
    "Gerätetyp",
    "Hersteller",
    "Makler",
    "Schaden",
    "Versicherungsnehmer"
  ]

  @number_patterns [
    # Simple bare numbers - strict pattern with explicit question mark handling
    ~r/(?<=^|[^a-zA-Z0-9])(\d+(?:[.,]\d+)*)(?=$|[^a-zA-Z0-9])/,
    # Leading currency
    ~r/(?<=^|[^\w])[$€£¥](\d+(?:[.,]\d+)*)(?=$|[^\w])/,
    # Trailing currency/percent
    ~r/(\d+(?:[.,]\d+)*)[$€£¥%](?=$|[^\w])/
  ]

  @date_patterns [
    ~r/\b(\d{4})-(\d{1,2})-(\d{1,2})\b/,
    ~r/\b(\d{1,2})\/(\d{1,2})\/(\d{4})\b/,
    ~r/\b(\d{1,2})\/(\d{1,2})\/(\d{2})\b/,
    ~r/\b(\d{1,2})\s+(January|February|March|April|May|June|July|August|September|October|November|December)\s+(\d{4})\b/i,
    ~r/\b(\d{1,2})\s+(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d{4})\b/i,
    ~r/\b(January|February|March|April|May|June|July|August|September|October|November|December)\s+(\d{4})\b/i,
    ~r/\b(Jan|Feb|Mar|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d{4})\b/i,
    ~r/\b(\d{1,2})\.(\d{1,2})\.(\d{4})\b/,
    ~r/\b(\d{1,2})\.(\d{1,2})\.(\d{2})\b/,
    ~r/\b(\d{1,2})\.\s+(Januar|Februar|März|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember)\s+(\d{4})\b/i,
    ~r/\b(\d{1,2})\.\s+(Jan|Feb|Mär|Apr|Mai|Jun|Jul|Aug|Sep|Okt|Nov|Dez)\s+(\d{4})\b/i,
    ~r/\b(\d{1,2})\.\s+(Januar|Februar|März|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember)\b/i,
    ~r/\b(\d{1,2})\.\s+(Jan|Feb|Mär|Apr|Mai|Jun|Jul|Aug|Sep|Okt|Nov|Dez)\b/i,
    ~r/\b(Januar|Februar|März|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember)\s+(\d{4})\b/i,
    ~r/\b(Jan|Feb|Mär|Apr|Mai|Jun|Jul|Aug|Sep|Okt|Nov|Dez)\s+(\d{4})\b/i
  ]

  @identifier_patterns [
    ~r/\b(?:[0-9]*[A-Z]+[0-9A-Z]*|[A-Z]+[0-9A-Z]*)\b/,
    ~r/\b[A-Za-z]{2,}\d{2,}\b/,
    ~r/\b(?:[A-Z0-9]*\d[A-Z0-9]*|[A-Z]+)[-\/](?:[A-Z0-9]*\d[A-Z0-9]*|[A-Z]+)(?:[-\/](?:[A-Z0-9]*\d[A-Z0-9]*|[A-Z]+))*\b/,
    ~r/\b[A-Z]{2,4}[-\/]\d{3,}\b/,
    ~r/\b[0-9a-f]{8}[-\/][0-9a-f]{4}[-\/][0-9a-f]{4}[-\/][0-9a-f]{4}[-\/][0-9a-f]{12}\b/i,
    ~r/\b(?:INV|REF|PO|ID)[-\/]?\d{4,}\b/i,
    ~r/\b[A-Z]{2}\d{4,6}\b/,
    ~r/\bISO \d{4,}(?:[-:\/]\d{4})?\b/i,
    ~r/\b[A-HJ-NPR-Z0-9]{17}\b/i,
    ~r/\b(?:\d{4}[- \/]){3}\d{4}\b/,
    ~r/\b\d{4}[- \/]?\*{4}[- \/]?\*{4}[- \/]?\d{4}\b/,
    ~r/\b(?:[A-Z0-9]{4,5}[-\/]){2,4}[A-Z0-9]{4,5}\b/i,
    ~r/\b[A-Z0-9]{8,}\.[A-Z0-9]{3,4}\b/i,
    ~r/\b[A-Z]{2}\d{2}[A-Z0-9]{4,30}\b/,
    ~r/\b[A-Z]{2}\d{2}(?:[- \/][A-Z0-9]{4})+\b/,
    ~r/\b[A-Z]{4}[A-Z]{2}[A-Z0-9]{2}(?:[A-Z0-9]{3})?\b/,
    ~r/\bISBN(?:-10)?:?\s*\d{1,5}[-\s\/]\d{1,7}[-\s\/]\d{1,6}[-\s\/][\dX]\b/i,
    ~r/\bISBN(?:-13)?:?\s*(?:978|979)[-\s\/]\d{1,5}[-\s\/]\d{1,7}[-\s\/]\d{1,7}[-\s\/]\d\b/i,
    ~r/\b\d{3}[-\/]\d{2}[-\/]\d{4}\b/,
    ~r/\b\d{11}\b/,
    ~r/\b[A-Z]{2}[0-9A-Z]{6,12}\b/,
    ~r/\b[A-Z]{1,2}\d{6,9}\b/,
    ~r/\b(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\b/,
    ~r/\b(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}\b/,
    ~r/\b(?:[0-9A-Fa-f]{2}[:\/\-]){5}[0-9A-Fa-f]{2}\b/i,
    ~r/\b[A-Z]\d{2}[-\/]\d{2}[-\/]\d{4}\b/i,
    ~r/\b[A-Z]{1,2}\d{3,7}[A-Z]{0,2}\b/,
    ~r/\b§\s*\d+(?:[a-z])*(?:\s+(?:Abs\.|Absatz)\s+\d+(?:[a-z])*)?(?:\s+(?:S\.|Satz)\s+\d+)?(?:\s+(?:[A-Z]{2,5}|[A-Za-zäöüÄÖÜß]+gesetz))?/,
    ~r/\b§§\s*\d+(?:[a-z])*\s*(?:-|–|\/|bis)\s*\d+(?:[a-z])*(?:\s+(?:[A-Z]{2,5}|[A-Za-zäöüÄÖÜß]+gesetz))?/,
    ~r/\b(?:Section|Sec\.|Article|Art\.|Paragraph|Para\.|Chapter|Chap\.|Title)\s+\d+(?:[a-z])*(?:\s+of\s+(?:the\s+)?[A-Z][A-Za-z\s]+)?/i,
    ~r/\b§\s*\d+(?:[a-z])*(?:\s+of\s+(?:the\s+)?[A-Z][A-Za-z\s]+)?/
  ]

  def extract_report_indicators(user_request) do
    ruleset_path = Path.join(@path_resources, "ruleset.json")
    user_request_lower = String.downcase(user_request)

    case File.read(ruleset_path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, ruleset} ->
            report_indicators =
              get_in(ruleset, ["special_indicators", "report_indicators"]) || %{}

            # Create indicators with direct value list and representation field
            Enum.flat_map(report_indicators, fn {report_type, indicators} ->
              matching_terms =
                Enum.flat_map(indicators, fn indicator ->
                  if String.contains?(user_request_lower, indicator) do
                    extract_full_terms(user_request, indicator)
                  else
                    []
                  end
                end)
                |> Enum.uniq()

              if matching_terms != [] do
                [
                  %{
                    type: :indicator,
                    value: matching_terms,
                    representation: report_type,
                    category: :report
                  }
                ]
              else
                []
              end
            end)

          {:error, _} ->
            []
        end

      {:error, _} ->
        []
    end
  end

  def extract_table_indicators(user_request) do
    ruleset_path = Path.join(@path_resources, "ruleset.json")
    user_request_lower = String.downcase(user_request)

    case File.read(ruleset_path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, ruleset} ->
            table_indicators = get_in(ruleset, ["special_indicators", "table_indicators"]) || %{}

            # Create separate indicator for each table with matching values
            Enum.flat_map(table_indicators, fn {table, indicators} ->
              matching_terms =
                Enum.flat_map(indicators, fn indicator ->
                  if String.contains?(user_request_lower, indicator) do
                    extract_full_terms(user_request, indicator)
                  else
                    []
                  end
                end)
                |> Enum.uniq()

              if matching_terms != [] do
                [%{type: :indicator, value: matching_terms, location: table, category: :table}]
              else
                []
              end
            end)

          {:error, _} ->
            []
        end

      {:error, _} ->
        []
    end
  end

  def extract_question_indicators(user_request) do
    ruleset_path = Path.join(@path_resources, "ruleset.json")
    user_request_lower = String.downcase(user_request)

    case File.read(ruleset_path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, ruleset} ->
            question_indicators =
              get_in(ruleset, ["special_indicators", "question_indicators"]) || %{}

            # Create indicators with value list and representation field
            Enum.flat_map(question_indicators, fn {question_type, indicators} ->
              matching_terms =
                Enum.flat_map(indicators, fn indicator ->
                  if String.contains?(user_request_lower, indicator) do
                    extract_full_terms(user_request, indicator)
                  else
                    []
                  end
                end)
                |> Enum.uniq()

              if matching_terms != [] do
                [
                  %{
                    type: :indicator,
                    value: matching_terms,
                    representation: question_type,
                    category: :question
                  }
                ]
              else
                []
              end
            end)

          {:error, _} ->
            []
        end

      {:error, _} ->
        []
    end
  end

  # Extract full words/terms that contain the indicator
  defp extract_full_terms(text, indicator) do
    text_lower = String.downcase(text)
    indicator_lower = String.downcase(indicator)

    # Split text into words and analyze each
    text
    |> String.split(~r/[\s,.!?;:()\[\]{}'"]+/, trim: true)
    |> Enum.filter(fn word ->
      String.contains?(String.downcase(word), indicator_lower)
    end)
  end

  defp find_full_terms(text, indicators) do
    # Process each indicator to handle regex patterns differently from regular text
    Enum.flat_map(indicators, fn indicator ->
      # Check if indicator contains a backslash (indicating a regex pattern)
      if String.contains?(indicator, "\\") do
        # Handle regex indicator
        try do
          # Compile the regex pattern as is
          regex = Regex.compile!(indicator)

          # Find all matches in the full text
          Regex.scan(regex, text)
          |> Enum.map(fn
            # Return first capture group if available
            [_full_match, capture | _] -> {capture, indicator}
            # Or full match if no capture group
            [match] -> {match, indicator}
            _ -> nil
          end)
          |> Enum.reject(&is_nil/1)
        rescue
          e ->
            IO.inspect(e, label: "Regex error with indicator: #{indicator}")
            # Return empty list if regex fails
            []
        end
      else
        # For non-regex indicators, use the original word-based method
        words = String.split(text, ~r/\s+|[,.!?;:()\[\]{}'"]+/, trim: true)

        Enum.flat_map(words, fn word ->
          if String.length(word) > 0 do
            if String.contains?(String.downcase(word), String.downcase(indicator)) do
              [{word, indicator}]
            else
              []
            end
          else
            []
          end
        end)
      end
    end)
    |> Enum.uniq_by(fn {term, _} -> term end)
  end

  def extract_amount_indicators(user_request) do
    ruleset_path = Path.join(@path_resources, "ruleset.json")
    user_request_lower = String.downcase(user_request)

    case File.read(ruleset_path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, ruleset} ->
            amount_indicators =
              get_in(ruleset, ["special_indicators", "amount_indicators"]) || %{}

            # Create separate indicator for each matching term with its symbol as representation
            Enum.flat_map(amount_indicators, fn {indicator, symbol} ->
              # Find instances where the indicator is within the request
              if String.contains?(user_request_lower, indicator) do
                # Extract the full words containing this indicator
                matching_terms = extract_full_terms(user_request, indicator)

                # Create an indicator map for each matching term
                Enum.map(matching_terms, fn term ->
                  %{type: :indicator, value: term, representation: symbol, category: :amount}
                end)
              else
                []
              end
            end)

          {:error, _} ->
            []
        end

      {:error, _} ->
        []
    end
  end

  def filter_fragments(processor_results_map) do
    # Extract parameters from the map
    rest_question_fragments = processor_results_map.rest_question_fragments
    report_indicators = processor_results_map[:report_indicators] || []
    table_column_indicators = processor_results_map[:table_column_indicators] || []
    query_entities = processor_results_map[:query_entities] || []
    table_indicators = processor_results_map[:table_indicators] || []
    question_indicators = processor_results_map[:question_indicators] || []
    amount_indicators = processor_results_map[:amount_indicators] || []
    party_indicators = processor_results_map[:party_indicators] || []
    location_indicators = processor_results_map[:location_indicators] || []

    words_lower = Enum.map(rest_question_fragments, &String.downcase/1)

    # Collect all terms to filter (single words and multi-word phrases)
    single_words = MapSet.new()
    multi_word_phrases = []

    # Helper function to categorize terms
    add_term = fn term, {singles, multis} ->
      term_lower = String.downcase(term)

      if String.contains?(term_lower, " ") do
        # Split into tokens and add to multi-word phrases
        tokens = String.split(term_lower, ~r/\s+/, trim: true)

        # Also add each individual word from multi-word phrases to singles
        new_singles =
          Enum.reduce(tokens, singles, fn token, acc ->
            MapSet.put(acc, token)
          end)

        {new_singles, [tokens | multis]}
      else
        {MapSet.put(singles, term_lower), multis}
      end
    end

    # From table_column_indicators
    {single_words, multi_word_phrases} =
      Enum.reduce(table_column_indicators, {single_words, multi_word_phrases}, fn indicator,
                                                                                  acc ->
        case indicator do
          %{type: :indicator, value: values, category: :table_column} when is_list(values) ->
            Enum.reduce(values, acc, fn value, value_acc ->
              add_term.(value, value_acc)
            end)

          _ ->
            acc
        end
      end)

    # From query_entities
    {single_words, multi_word_phrases} =
      Enum.reduce(query_entities, {single_words, multi_word_phrases}, fn entity, acc ->
        add_term.(entity.value, acc)
      end)

    # From report_indicators
    {single_words, multi_word_phrases} =
      Enum.reduce(report_indicators, {single_words, multi_word_phrases}, fn indicator, acc ->
        case indicator do
          %{type: :indicator, value: values, category: :report} when is_list(values) ->
            Enum.reduce(values, acc, fn value, value_acc ->
              add_term.(value, value_acc)
            end)

          _ ->
            acc
        end
      end)

    # From table_indicators
    {single_words, multi_word_phrases} =
      Enum.reduce(table_indicators, {single_words, multi_word_phrases}, fn indicator, acc ->
        case indicator do
          %{type: :indicator, value: values, category: :table} when is_list(values) ->
            Enum.reduce(values, acc, fn value, value_acc ->
              add_term.(value, value_acc)
            end)

          _ ->
            acc
        end
      end)

    # From question_indicators
    {single_words, multi_word_phrases} =
      Enum.reduce(question_indicators, {single_words, multi_word_phrases}, fn indicator, acc ->
        case indicator do
          %{type: :indicator, value: values, category: :question} when is_list(values) ->
            Enum.reduce(values, acc, fn value, value_acc ->
              add_term.(value, value_acc)
            end)

          _ ->
            acc
        end
      end)

    # From amount_indicators (single value)
    {single_words, multi_word_phrases} =
      Enum.reduce(amount_indicators, {single_words, multi_word_phrases}, fn indicator, acc ->
        case indicator do
          %{type: :indicator, value: value, category: :amount} when is_binary(value) ->
            add_term.(value, acc)

          _ ->
            acc
        end
      end)

    # From party_indicators (single value)
    {single_words, multi_word_phrases} =
      Enum.reduce(party_indicators, {single_words, multi_word_phrases}, fn indicator, acc ->
        case indicator do
          %{type: :indicator, value: value, category: :party} when is_binary(value) ->
            add_term.(value, acc)

          _ ->
            acc
        end
      end)

    # From location_indicators (single value)
    {single_words, multi_word_phrases} =
      Enum.reduce(location_indicators, {single_words, multi_word_phrases}, fn indicator, acc ->
        case indicator do
          %{type: :indicator, value: value, category: :location} when is_binary(value) ->
            add_term.(value, acc)

          _ ->
            acc
        end
      end)

    # Sort multi-word phrases by length (longest first) for more specific matching
    sorted_phrases = Enum.sort_by(multi_word_phrases, &length/1, :desc)

    # Track which words should be removed (using indices)
    indices_to_remove = MapSet.new()

    # Process multi-word phrases first
    indices_to_remove =
      Enum.reduce(sorted_phrases, indices_to_remove, fn phrase_tokens, acc ->
        phrase_length = length(phrase_tokens)

        # Skip empty phrases
        if phrase_length == 0 do
          acc
        else
          # Check each possible position in the request
          Enum.reduce(0..(length(words_lower) - phrase_length), acc, fn start_idx, pos_acc ->
            # Get the window of words at this position
            window = Enum.slice(words_lower, start_idx, phrase_length)

            # If window matches the phrase, mark all its indices for removal
            if window == phrase_tokens do
              Enum.reduce(start_idx..(start_idx + phrase_length - 1), pos_acc, fn idx, idx_acc ->
                MapSet.put(idx_acc, idx)
              end)
            else
              pos_acc
            end
          end)
        end
      end)

    # Also mark single words for removal
    indices_to_remove =
      Enum.reduce(Enum.with_index(words_lower), indices_to_remove, fn {word, idx}, acc ->
        if MapSet.member?(single_words, word) do
          MapSet.put(acc, idx)
        else
          acc
        end
      end)

    # Filter out marked words
    filtered_words =
      Enum.with_index(rest_question_fragments)
      |> Enum.filter(fn {_word, idx} -> not MapSet.member?(indices_to_remove, idx) end)
      |> Enum.map(fn {word, _idx} -> word end)

    # Load exclude words list
    exclude_words_path = Path.join(@path_resources, "exclude_words_list.json")

    exclude_words =
      case File.read(exclude_words_path) do
        {:ok, contents} ->
          case Jason.decode(contents) do
            {:ok, json} ->
              Map.get(json, "exclude_words", []) |> Enum.map(&String.downcase/1) |> MapSet.new()

            _ ->
              MapSet.new()
          end

        _ ->
          MapSet.new()
      end

    # Apply additional filtering:
    # 1. Remove words in exclude_words list
    # 2. Remove words with less than 4 characters
    filtered_words
    |> Enum.filter(fn word ->
      word_lower = String.downcase(word)
      String.length(word) >= 4 and not MapSet.member?(exclude_words, word_lower)
    end)
  end

  def extract_question_fragments(user_request) do
    user_request
    |> String.split(~r/[\s,.!?;:()\[\]{}'"]+/)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(fn word ->
      word != "" and String.length(word) > 1
    end)
  end

  def determine_request_type(user_request) do
    ruleset_path = Path.join(@path_resources, "ruleset.json")

    case File.read(ruleset_path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, ruleset} ->
            report_indicators =
              get_in(ruleset, ["special_indicators", "report_indicators", "report"]) || []

            user_request_lower = String.downcase(user_request)

            is_report =
              Enum.any?(report_indicators, fn indicator ->
                String.contains?(user_request_lower, String.downcase(indicator))
              end)

            if is_report, do: :report, else: :meta_info

          {:error, _} ->
            :meta_info
        end

      {:error, _} ->
        :meta_info
    end
  end

  def filter_question_fragments(question_fragments, table_column_names) do
    exclude_words_path = Path.join(@path_resources, "exclude_words_list.json")

    exclude_words =
      case File.read(exclude_words_path) do
        {:ok, contents} ->
          case Jason.decode(contents) do
            {:ok, json} -> Map.get(json, "exclude_words", [])
            _ -> []
          end

        _ ->
          []
      end

    column_keys = Map.keys(table_column_names)

    Enum.filter(question_fragments, fn fragment ->
      not Enum.member?(column_keys, fragment) and
        String.length(fragment) >= 5 and
        not Enum.member?(exclude_words, String.downcase(fragment))
    end)
  end

  @doc """
  Extracts value of the column with specific name from a table.
  """
  def extract_columns_value_from_json(table_column, position) do
    case Map.to_list(table_column) do
      [{table_name, column_name} | _] ->
        # Get column info from ResourceAgent
        case ResourceAgent.get_file_data(table_name) do
          nil ->
            # Default fallback if file data not found
            "exact"

          file_data ->
            columns = Map.get(file_data, "columns", [])

            # Find the column and extract the requested position
            Enum.find_value(columns, "exact", fn column ->
              case column do
                %{^column_name => values} when is_list(values) and length(values) >= position ->
                  Enum.at(values, position - 1)

                _ ->
                  nil
              end
            end)
        end

      _ ->
        # Default fallback if table_column format is invalid
        "exact"
    end
  end

  def extract_table_column_indicators(user_request) do
    # Store original request for preserving case in results
    original_request = user_request
    user_request_lower = String.downcase(user_request)

    # First collect all matching columns in the original nested map format
    matches_by_table =
      @files
      |> Enum.reduce(%{}, fn table, acc ->
        case ResourceAgent.get_records(table) do
          records when is_list(records) ->
            matching_columns =
              Enum.reduce(records, %{}, fn record, record_acc ->
                Enum.reduce(record, record_acc, fn {column, value}, column_acc ->
                  matches = find_column_matches(column, original_request, user_request_lower)

                  if matches != [] do
                    Map.put(column_acc, column, matches)
                  else
                    column_acc
                  end
                end)
              end)

            # Only include tables with actual matches
            if map_size(matching_columns) > 0 do
              Map.put(acc, table, matching_columns)
            else
              acc
            end

          _ ->
            acc
        end
      end)

    # Transform the nested structure into a list of indicator maps
    Enum.flat_map(matches_by_table, fn {table, columns} ->
      Enum.flat_map(columns, fn {column, matches} ->
        # Create an indicator entry for each table-column match
        [
          %{
            type: :indicator,
            value: matches,
            category: :table_column,
            location: %{table => column}
          }
        ]
      end)
    end)
  end

  defp find_column_matches(column, original_request, user_request_lower) do
    column_lower = String.downcase(column)
    matches = []

    # Case 1: Full column name match
    matches =
      if String.contains?(user_request_lower, column_lower) do
        # Find the full word containing the column name
        found_match = locate_and_extract_match(original_request, column_lower)
        if found_match, do: [found_match | matches], else: matches
      else
        matches
      end

    # Case 2: Column with number at the end
    matches =
      case Regex.run(~r/^(.+)\s+\d+$/, column_lower, capture: :all_but_first) do
        [base_name] ->
          if String.contains?(user_request_lower, base_name) do
            # Find the full word containing the base name
            found_match = locate_and_extract_match(original_request, base_name)
            if found_match, do: [found_match | matches], else: matches
          else
            matches
          end

        _ ->
          matches
      end

    # Case 3: Column with hyphen
    matches =
      if String.contains?(column_lower, "-") do
        no_hyphen = String.replace(column_lower, "-", "")
        with_space = String.replace(column_lower, "-", " ")

        new_matches = []

        new_matches =
          if String.contains?(user_request_lower, no_hyphen) do
            # Find the full word containing the no_hyphen variant
            found_match = locate_and_extract_match(original_request, no_hyphen)
            if found_match, do: [found_match | new_matches], else: new_matches
          else
            new_matches
          end

        new_matches =
          if String.contains?(user_request_lower, with_space) do
            # Find the full word containing the with_space variant
            found_match = locate_and_extract_match(original_request, with_space)
            if found_match, do: [found_match | new_matches], else: new_matches
          else
            new_matches
          end

        new_matches ++ matches
      else
        matches
      end

    # Case 4: More than 50% of column words match (as a fallback)
    matches =
      if matches == [] do
        if partial_match =
             find_partial_column_matches(column, original_request, user_request_lower) do
          [partial_match | matches]
        else
          matches
        end
      else
        matches
      end

    Enum.uniq(matches)
  end

  # Helper function to find partial column matches (>50% of words)
  defp find_partial_column_matches(column, original_request, user_request_lower) do
    # Split column into individual words
    column_words =
      column
      |> String.downcase()
      |> String.split(~r/\s+/, trim: true)

    # Only process if we have multiple words
    if length(column_words) > 1 do
      # Find which words appear in the user request
      matching_words =
        Enum.filter(column_words, fn word ->
          # Only match on alphabetic words (no numbers)
          is_alphabetic_word = Regex.match?(~r/^[[:alpha:]]+$/, word)
          is_alphabetic_word && String.contains?(user_request_lower, word)
        end)

      # Check if more than 50% of words match
      if length(matching_words) > 0 && length(matching_words) / length(column_words) >= 0.5 do
        # Use our existing locate_and_extract_match function for each matching word
        matches =
          Enum.map(matching_words, fn word ->
            locate_and_extract_match(original_request, word)
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" ")

        matches
      else
        nil
      end
    else
      nil
    end
  end

  # Function to extract the best matching phrase from the request
  defp extract_best_matching_phrase(
         original_request,
         user_request_lower,
         matching_words,
         column_words
       ) do
    # Get all positions of each matching word in the user request
    word_positions =
      Enum.flat_map(matching_words, fn word ->
        # Find all occurrences of this word in the user request
        :binary.matches(user_request_lower, word)
        |> Enum.map(fn {pos, len} ->
          %{word: word, position: pos, length: len, end_pos: pos + len}
        end)
      end)
      |> Enum.sort_by(fn %{position: pos} -> pos end)

    # Identify clusters of words that appear close to each other
    clusters = find_word_clusters(word_positions)

    # Find the cluster that has the most matching words from our column
    best_cluster =
      Enum.max_by(
        clusters,
        fn cluster ->
          # Count unique words in this cluster that are part of our column words
          cluster
          |> Enum.map(fn %{word: word} -> word end)
          |> Enum.uniq()
          |> Enum.count(fn word -> word in matching_words end)
        end,
        fn -> [] end
      )

    if best_cluster != [] do
      # Extract the text span covering this cluster
      first_word = List.first(best_cluster)
      last_word = List.last(best_cluster)

      # Find word boundaries
      start_pos = find_word_start(user_request_lower, first_word.position)

      end_pos =
        find_word_end(user_request_lower, last_word.end_pos, String.length(original_request))

      # Extract and trim the section from the original request
      String.trim(String.slice(original_request, start_pos, end_pos - start_pos))
    else
      nil
    end
  end

  # Find clusters of words that appear near each other
  defp find_word_clusters(word_positions) do
    # Group words that are within a reasonable distance of each other (e.g., 20 characters)
    max_gap = 20

    Enum.reduce(word_positions, [], fn position, clusters ->
      # Try to add this position to an existing cluster
      {added, new_clusters} =
        Enum.reduce_while(clusters, {false, clusters}, fn cluster, {_, acc} ->
          last_word = List.last(cluster)

          # If this word is close to the last word in the cluster, add it
          if position.position - last_word.end_pos <= max_gap do
            {added_to_cluster, updated_acc} =
              {true,
               List.replace_at(acc, Enum.find_index(acc, &(&1 == cluster)), cluster ++ [position])}

            {:halt, {added_to_cluster, updated_acc}}
          else
            {:cont, {false, acc}}
          end
        end)

      # If we couldn't add it to any existing cluster, start a new one
      if added do
        new_clusters
      else
        clusters ++ [[position]]
      end
    end)
  end

  # Find the start of a word (looking backwards for whitespace/punctuation)
  defp find_word_start(text, position) do
    text_before = String.slice(text, 0, position)

    # Find the last space or punctuation before this position
    case :binary.matches(text_before, ~r/[\s,.!?;:()\[\]{}'"]/, [:global]) |> List.last() do
      {pos, len} -> pos + len
      # If no boundary found, start from the beginning
      nil -> 0
    end
  end

  # Find the end of a word (looking forward for whitespace/punctuation)
  defp find_word_end(text, position, max_length) do
    if position >= max_length do
      max_length
    else
      text_after = String.slice(text, position, max_length - position)

      # Find the first space or punctuation after this position
      case :binary.match(text_after, ~r/[\s,.!?;:()\[\]{}'"]/) do
        {pos, _} -> position + pos
        # If no boundary found, go to the end
        :nomatch -> max_length
      end
    end
  end

  # Helper functions for string index operations
  defp last_index_of(string, pattern) do
    case :binary.matches(string, pattern) do
      [] ->
        nil

      matches ->
        {pos, _} = List.last(matches)
        pos
    end
  end

  defp first_index_of(string, pattern) do
    case :binary.match(string, pattern) do
      {pos, _} -> pos
      :nomatch -> nil
    end
  end

  # Helper function to locate and extract the full word match
  defp locate_and_extract_match(text, pattern) do
    text_lower = String.downcase(text)

    # Safely split text into chunks
    chars = String.graphemes(text_lower)
    length = length(chars)

    # Find the position of the pattern
    case find_pattern_position(chars, String.graphemes(pattern), 0) do
      nil ->
        nil

      start_pos ->
        # Extract the complete word containing the pattern
        # First, find the word boundaries
        left_boundary = find_word_boundary_left(chars, start_pos)
        pattern_length = String.length(pattern)
        right_boundary = find_word_boundary_right(chars, start_pos + pattern_length, length)

        # Extract the word from the original text (preserving case)
        String.slice(text, left_boundary, right_boundary - left_boundary)
    end
  end

  # Find the position of a pattern in a list of characters
  defp find_pattern_position(chars, pattern, start_index) do
    pattern_length = length(pattern)
    chars_length = length(chars)

    if start_index + pattern_length > chars_length do
      nil
    else
      # Check if the pattern matches at the current position
      match = Enum.slice(chars, start_index, pattern_length) == pattern

      if match do
        start_index
      else
        find_pattern_position(chars, pattern, start_index + 1)
      end
    end
  end

  # Find the left boundary of a word
  defp find_word_boundary_left(chars, pos) do
    find_word_boundary_left(chars, pos, 0)
  end

  defp find_word_boundary_left(_chars, 0, boundary), do: boundary

  defp find_word_boundary_left(chars, pos, _boundary) do
    prev_char = Enum.at(chars, pos - 1)

    if Regex.match?(~r/\s|[,.!?;:()\[\]{}'"]+/, prev_char) do
      pos
    else
      find_word_boundary_left(chars, pos - 1, pos - 1)
    end
  end

  # Find the right boundary of a word
  defp find_word_boundary_right(chars, pos, length) do
    if pos >= length do
      length
    else
      curr_char = Enum.at(chars, pos)

      if Regex.match?(~r/\s|[,.!?;:()\[\]{}'"]+/, curr_char) do
        pos
      else
        find_word_boundary_right(chars, pos + 1, length)
      end
    end
  end

  @doc """
  Finds suitable column names for fragments in the database.
  """
  def find_fitting_column_names_for_fragments(question_fragments) do
    # First build the map, collecting all matches using ResourceAgent instead of load_json_file
    fragment_matches =
      @files
      |> Enum.reduce(%{}, fn table, acc ->
        # Get records from ResourceAgent instead of loading JSON file
        case ResourceAgent.get_records(table) do
          records when is_list(records) ->
            Enum.reduce(records, acc, fn record, record_acc ->
              Enum.reduce(record, record_acc, fn {column, value}, column_acc ->
                if value && value != "" do
                  value_str = to_string(value)

                  Enum.reduce(question_fragments, column_acc, fn fragment, fragment_acc ->
                    if is_fragment_match?(fragment, value_str) do
                      entry = {table, column}
                      existing = Map.get(fragment_acc, fragment, [])

                      if entry in existing do
                        fragment_acc
                      else
                        Map.put(fragment_acc, fragment, [entry | existing])
                      end
                    else
                      fragment_acc
                    end
                  end)
                else
                  column_acc
                end
              end)
            end)

          _ ->
            # If no records found for this table, return accumulator unchanged
            acc
        end
      end)

    # Transform the map into the requested list of maps format
    Enum.map(fragment_matches, fn {fragment, entries} ->
      # Group entries by table/file
      location =
        Enum.reduce(entries, %{}, fn {table, column}, table_acc ->
          # Get existing columns for this table or initialize empty list
          columns = Map.get(table_acc, table, [])
          # Add the column if not already present
          updated_columns = if column in columns, do: columns, else: [column | columns]
          # Update the map
          Map.put(table_acc, table, updated_columns)
        end)

      # Create the map with the requested structure
      %{
        type: :match,
        value: fragment,
        location: location
      }
    end)
  end

  def construct_table_column_mappings(question_fragments) do
    table_column_mappings =
      @files
      |> Enum.reduce(%{}, fn table, acc ->
        case ResourceAgent.get_records(table) do
          records when is_list(records) ->
            file_matches =
              Enum.reduce(records, %{}, fn record, file_acc ->
                Enum.reduce(record, file_acc, fn {column, value}, column_acc ->
                  matching_fragments = find_matching_fragments(question_fragments, value)

                  if matching_fragments != [] do
                    Map.put(column_acc, column, true)
                  else
                    column_acc
                  end
                end)
              end)

            if map_size(file_matches) > 0 do
              Map.put(acc, table, Map.keys(file_matches))
            else
              acc
            end

          _ ->
            acc
        end
      end)

    table_column_fragment_mapping =
      @files
      |> Enum.reduce(%{}, fn table, acc ->
        case ResourceAgent.get_records(table) do
          records when is_list(records) ->
            Enum.reduce(records, acc, fn record, record_acc ->
              Enum.reduce(record, record_acc, fn {column, value}, column_acc ->
                matching_fragments = find_matching_fragments(question_fragments, value)

                Enum.reduce(matching_fragments, column_acc, fn fragment, fragment_acc ->
                  entries = Map.get(fragment_acc, fragment, [])
                  pair = {table, column}

                  if pair in entries do
                    fragment_acc
                  else
                    Map.put(fragment_acc, fragment, [pair | entries])
                  end
                end)
              end)
            end)

          _ ->
            acc
        end
      end)

    {table_column_mappings, table_column_fragment_mapping}
  end

  def extract_query_entities_from_request(user_request) do
    ruleset = load_ruleset()

    {date_indicators, request_after_dates} = extract_date_indicators(user_request, ruleset)

    {id_indicators, request_after_ids} = extract_id_indicators(request_after_dates, ruleset)

    {quantity_number_indicators, final_request} =
      extract_quantity_number_indicators(request_after_ids, ruleset)

    all_indicators = date_indicators ++ id_indicators ++ quantity_number_indicators

    cleaned_request = final_request

    rest_question_fragments = extract_question_fragments(cleaned_request)

    {all_indicators, rest_question_fragments}
  end

  defp extract_date_indicators(request, ruleset) do
    # Find regex pattern matches for dates
    date_matches = find_regex_matches(request, @date_patterns, :date)
    IO.inspect(date_matches, label: "Date Matches")

    # Create helper_value indicators from regex matches
    helper_indicators =
      Enum.map(date_matches, fn match ->
        %{type: :helper_value, category: :date, value: match}
      end)

    # Find indicator word matches
    date_indicator_words = get_in(ruleset, ["rules", "date", "indicators"]) || []
    found_terms = find_full_terms(request, date_indicator_words)

    # Create desired_value indicators from indicator words
    desired_indicators =
      Enum.map(found_terms, fn {term, _indicator} ->
        %{type: :desired_value, category: :date, value: term}
      end)

    # Collect terms to remove from the request
    terms_to_remove = date_matches ++ Enum.map(found_terms, fn {term, _} -> term end)

    # Remove all matches from the request
    modified_request = remove_matches(request, terms_to_remove)

    # Return combined indicators and modified request
    {helper_indicators ++ desired_indicators, modified_request}
  end

  defp extract_id_indicators(request, ruleset) do
    # Find regex pattern matches for IDs
    id_matches = find_regex_matches(request, @identifier_patterns, :id)

    IO.inspect(id_matches, label: "ID Matches")
    # Create helper_value indicators from regex matches
    helper_indicators =
      Enum.map(id_matches, fn match ->
        %{type: :helper_value, category: :id, value: match}
      end)

    # Find indicator word matches
    id_indicator_words = get_in(ruleset, ["rules", "ID", "indicators"]) || []
    found_terms = find_full_terms(request, id_indicator_words)
    # IO.inspect(found_terms, label: "Found ID Terms")

    # Create desired_value indicators from indicator words
    desired_indicators =
      Enum.map(found_terms, fn {term, _indicator} ->
        %{type: :desired_value, category: :id, value: term}
      end)

    # Collect terms to remove from the request
    terms_to_remove = id_matches ++ Enum.map(found_terms, fn {term, _} -> term end)

    # Remove all matches from the request
    modified_request = remove_matches(request, terms_to_remove)

    # Return combined indicators and modified request
    {helper_indicators ++ desired_indicators, modified_request}
  end

  defp extract_quantity_number_indicators(request, ruleset) do
    # Find number pattern matches
    number_matches = find_regex_matches(request, @number_patterns, :number)

    # Find indicator word matches
    quantity_indicator_words = get_in(ruleset, ["rules", "quantity", "indicators"]) || []
    number_indicator_words = get_in(ruleset, ["rules", "number", "indicators"]) || []

    found_quantity_terms = find_full_terms(request, quantity_indicator_words)
    found_number_terms = find_full_terms(request, number_indicator_words)

    IO.inspect(found_quantity_terms, label: "Found Quantity Terms")
    IO.inspect(found_number_terms, label: "Found Number Terms")

    # Create all indicators
    number_helper_indicators =
      Enum.map(number_matches, fn match ->
        %{type: :helper_value, category: :number, value: match}
      end)

    quantity_helper_indicators =
      if length(found_quantity_terms) > 0 do
        # If quantity terms are found, number matches become quantity indicators
        Enum.map(number_matches, fn match ->
          %{type: :helper_value, category: :quantity, value: match}
        end)
      else
        []
      end

    quantity_desired_indicators =
      Enum.map(found_quantity_terms, fn {term, _} ->
        %{type: :desired_value, category: :quantity, value: term}
      end)

    number_desired_indicators =
      Enum.map(found_number_terms, fn {term, _} ->
        %{type: :desired_value, category: :number, value: term}
      end)

    # Combine all indicators
    all_indicators =
      number_helper_indicators ++
        quantity_helper_indicators ++
        quantity_desired_indicators ++
        number_desired_indicators

    # Remove unique indicators to avoid duplicates (prefer quantity over number if both exist)
    unique_indicators = Enum.uniq_by(all_indicators, fn %{value: value} -> value end)

    # Collect terms to remove from the request
    terms_to_remove =
      number_matches ++
        Enum.map(found_quantity_terms, fn {term, _} -> term end) ++
        Enum.map(found_number_terms, fn {term, _} -> term end)

    # Remove all matches from the request
    modified_request = remove_matches(request, terms_to_remove)

    # Return combined indicators and modified request
    {unique_indicators, modified_request}
  end

  defp find_regex_matches(text, patterns, type) do
    matches =
      Enum.flat_map(patterns, fn pattern ->
        Regex.scan(pattern, text)
        |> Enum.map(fn match ->
          case match do
            [full_match, capture | _] ->
              # Apply different validation based on type
              cond do
                type == :number ->
                  # Only allow digits and decimal separators for numbers
                  if capture && Regex.match?(~r/^[0-9.,]+$/, capture), do: capture, else: nil

                type == :id ->
                  # For IDs, just ensure it's not empty
                  if capture && String.trim(capture) != "", do: capture, else: nil

                type == :date ->
                  # For dates, accept as is
                  full_match

                true ->
                  # Default case - accept the capture
                  capture
              end

            [match] ->
              # Same logic for full matches without capture groups
              cond do
                type == :number ->
                  if match && Regex.match?(~r/^[0-9.,]+$/, match), do: match, else: nil

                type == :id ->
                  if match && String.trim(match) != "", do: match, else: nil

                type == :date ->
                  match

                true ->
                  match
              end
          end
        end)
        |> Enum.reject(&is_nil/1)
      end)
      |> Enum.uniq()

    IO.inspect(matches, label: "Matches for type #{type}")

    # Apply filtering based on type
    if type == :number do
      matches
    else
      filter_contained_matches(matches)
    end
  end

  defp filter_contained_matches(matches) do
    Enum.filter(matches, fn match ->
      not Enum.any?(matches, fn other_match ->
        match != other_match and
          String.contains?(other_match, match)
      end)
    end)
  end

  defp remove_matches(text, matches) do
    Enum.reduce(matches, text, fn match, current_text ->
      String.replace(current_text, match, " ")
    end)
  end

  defp load_ruleset do
    ruleset_path = Path.join(@path_resources, "ruleset.json")

    case File.read(ruleset_path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, ruleset} -> ruleset
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  # Helper function to determine if a fragment matches a value with enhanced criteria
  defp is_fragment_match?(fragment, value) do
    # Skip empty strings
    if String.length(fragment) == 0 || String.length(value) == 0 do
      false
    else
      # 1. Try exact case-sensitive match
      # Only consider case-sensitive match if fragment has at least one uppercase letter
      has_uppercase = String.match?(fragment, ~r/[A-Z]/)
      case_sensitive_match = fragment == value && has_uppercase

      # 2. Check if fragment is fully contained in value (case-sensitive)
      # fragment_contained = String.contains?(value, fragment)

      # 3. Try case-insensitive containment
      fragment_lower = String.downcase(fragment)
      value_lower = String.downcase(value)

      # Get fragment and value lengths for ratio calculations
      fragment_length = String.length(fragment_lower)
      value_length = String.length(value_lower)

      # 4. For more complex partial matches, apply stricter rules
      cond do
        # Exact match or case-sensitive containment is highest priority
        case_sensitive_match ->
          true

        # Next priority: case-insensitive containment with position-based rules
        String.contains?(value_lower, fragment_lower) ->
          # Check fragment to value ratio - fragment must be at least 40% of value length
          fragment_to_value_ratio = fragment_length / value_length

          if fragment_to_value_ratio < 0.45 do
            false
          else
            # Get the position where the fragment appears in the value
            {start_pos, _} = :binary.match(value_lower, fragment_lower)
            end_pos = start_pos + String.length(fragment_lower)

            # Check if the match is at the beginning, in the middle, or at the end
            is_prefix = start_pos == 0
            is_suffix = end_pos == String.length(value_lower)

            # Calculate prefix and suffix lengths
            prefix_length = start_pos
            suffix_length = String.length(value_lower) - end_pos

            # Apply different rules based on position and length
            cond do
              # Strict with suffixes (max 2 extra chars)
              is_suffix && suffix_length <= 2 ->
                true

              # More lenient with prefixes (max 3 extra chars)
              is_prefix && prefix_length <= 3 ->
                true

              # For internal matches, scale allowed differences with fragment length
              !is_suffix && !is_prefix ->
                # Allow more differences for longer fragments
                max_allowed_diff = max(3, round(fragment_length * 0.2))
                prefix_length + suffix_length <= max_allowed_diff

              true ->
                false
            end
          end

        # Lowest priority: similar but not contained strings (very strict criteria)
        true ->
          # Calculate length ratio (smaller / larger)
          length_ratio =
            if fragment_length > value_length,
              do: value_length / fragment_length,
              else: fragment_length / value_length

          # Only consider strings with very similar lengths (at least 90% similar)
          length_within_tolerance = length_ratio >= 0.9

          # Calculate Jaro distance for character similarity
          jaro_score = String.jaro_distance(fragment_lower, value_lower)

          # Very high similarity threshold for non-contained matches
          length_within_tolerance && jaro_score >= 0.9
      end
    end
  end

  def construct_column_value_mapping(column_names, question_fragments) do
    column_value_candidates =
      Enum.map(column_names, fn column ->
        candidate_values =
          Enum.filter(question_fragments, fn fragment ->
            not Enum.any?(column_names, fn col ->
              String.downcase(col) == String.downcase(fragment) or
                String.jaro_distance(String.downcase(col), String.downcase(fragment)) > 0.8
            end)
          end)

        {column, candidate_values}
      end)
      |> Enum.into(%{})

    Enum.reduce(column_names, %{}, fn column, acc ->
      candidates = Map.get(column_value_candidates, column, [])

      best_candidate = select_best_candidate(column, candidates)

      if best_candidate do
        Map.put(acc, column, best_candidate)
      else
        acc
      end
    end)
  end

  # Helper to find fragments that match a value
  defp find_matching_fragments(fragments, value) do
    if value && value != "" do
      value_str = to_string(value)

      Enum.filter(fragments, fn fragment ->
        fragment_str = to_string(fragment)
        fragment_length = String.length(fragment_str)
        value_length = String.length(value_str)

        # Only match if value has at least as many characters as the fragment
        value_length >= fragment_length &&
          (String.downcase(value_str) == String.downcase(fragment_str) ||
             String.contains?(String.downcase(value_str), String.downcase(fragment_str)) ||
             String.contains?(String.downcase(fragment_str), String.downcase(value_str)) ||
             String.jaro_distance(String.downcase(value_str), String.downcase(fragment_str)) > 0.8)
      end)
    else
      []
    end
  end

  def find_fitting_records(column_value_mapping) do
    if map_size(column_value_mapping) == 0 do
      []
    else
      @files
      |> Enum.flat_map(fn table ->
        case ResourceAgent.get_records(table) do
          records when is_list(records) ->
            file_columns =
              Enum.flat_map(records, fn record ->
                Map.keys(record)
              end)
              |> Enum.uniq()

            relevant_mapping =
              Map.filter(column_value_mapping, fn {column, _} ->
                column in file_columns
              end)

            if map_size(relevant_mapping) > 0 do
              Enum.filter(records, fn record ->
                record_matches?(record, relevant_mapping)
              end)
              |> Enum.map(fn record ->
                %{file: table, table: table, record: record}
              end)
            else
              []
            end

          _ ->
            []
        end
      end)
    end
  end

  defp select_best_candidate(column, candidates) do
    if candidates == [] do
      nil
    else
      List.first(candidates)
    end
  end

  defp record_matches?(record, mapping) do
    Enum.all?(mapping, fn {column, value} ->
      case record[column] do
        nil ->
          false

        record_value ->
          record_value_str = to_string(record_value)

          String.downcase(record_value_str) == String.downcase(value) or
            String.contains?(String.downcase(record_value_str), String.downcase(value)) or
            String.jaro_distance(String.downcase(record_value_str), String.downcase(value)) > 0.8
      end
    end)
  end

  def extract_party_indicators(user_request) do
    ruleset_path = Path.join(@path_resources, "ruleset.json")
    user_request_lower = String.downcase(user_request)

    case File.read(ruleset_path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, ruleset} ->
            party_indicators = get_in(ruleset, ["rules", "party", "indicators"]) || []

            # Find matching words for each indicator
            matching_terms =
              Enum.flat_map(party_indicators, fn indicator ->
                if String.contains?(user_request_lower, indicator) do
                  extract_full_terms(user_request, indicator)
                else
                  []
                end
              end)
              |> Enum.uniq()

            # Create indicator objects for each match
            Enum.map(matching_terms, fn term ->
              %{type: :indicator, value: term, category: :party}
            end)

          {:error, _} ->
            []
        end

      {:error, _} ->
        []
    end
  end

  def extract_location_indicators(user_request) do
    ruleset_path = Path.join(@path_resources, "ruleset.json")
    user_request_lower = String.downcase(user_request)

    case File.read(ruleset_path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, ruleset} ->
            location_indicators = get_in(ruleset, ["rules", "location", "indicators"]) || []

            # Find matching words for each indicator
            matching_terms =
              Enum.flat_map(location_indicators, fn indicator ->
                if String.contains?(user_request_lower, indicator) do
                  extract_full_terms(user_request, indicator)
                else
                  []
                end
              end)
              |> Enum.uniq()

            # Create indicator objects for each match
            Enum.map(matching_terms, fn term ->
              %{type: :indicator, value: term, category: :location}
            end)

          {:error, _} ->
            []
        end

      {:error, _} ->
        []
    end
  end

  def extract_location_for_type(type) do
    ruleset = load_ruleset()

    # Get the columns map from the ruleset for the given type
    columns_map =
      case type do
        "report_id" ->
          %{"Schaden" => ["Gutachten-Nr"]}

        _ ->
          get_in(ruleset, ["rules", type, "columns"]) || %{}
      end

    # Return the columns map which is already in the format of
    # %{"Table" => ["Column1", "Column2"], ...}
    columns_map
  end

  def add_indicators_from_direct_value_matches(table_column_indicators, direct_value_matches) do
    # Extract existing table-column pairs from table_column_indicators
    existing_pairs =
      MapSet.new(
        Enum.flat_map(table_column_indicators, fn indicator ->
          case indicator do
            %{location: location} ->
              # Extract all table-column pairs from the location map
              Enum.flat_map(location, fn {table, columns} ->
                columns_list = if is_list(columns), do: columns, else: [columns]
                Enum.map(columns_list, fn column -> {table, column} end)
              end)

            _ ->
              []
          end
        end)
      )

    # Process each direct value match to create new indicators
    new_indicators =
      Enum.flat_map(direct_value_matches, fn match ->
        # Get the location map (e.g., %{"Gerätetyp" => ["Hersteller", "Other"], ...})
        match_location = match.location

        # Create a new indicator for each table-column pair
        Enum.flat_map(match_location, fn {table, columns} ->
          columns_list = if is_list(columns), do: columns, else: [columns]

          # For each column, create a separate indicator if not already existing
          Enum.flat_map(columns_list, fn column ->
            # Check if this specific table-column pair already exists
            if MapSet.member?(existing_pairs, {table, column}) do
              # Skip if already exists
              []
            else
              # Create a new indicator with a single column in the location
              [
                %{
                  type: :indicator,
                  value: [column],
                  # Single column, not a list
                  location: %{table => column},
                  category: :table_column
                }
              ]
            end
          end)
        end)
      end)

    # Combine existing indicators with new ones
    table_column_indicators ++ new_indicators
  end

  # Helper functions

  # Helper function to normalize dates to DD.MM.YYYY format
  defp normalize_date_value(date_str) do
    date_str = String.trim(date_str)

    # Try each pattern in order
    cond do
      # YYYY-MM-DD
      capture = Regex.run(~r/\b(\d{4})-(\d{1,2})-(\d{1,2})\b/, date_str) ->
        [_, year, month, day] = capture
        format_date(day, month, year)

      # DD/MM/YYYY
      capture = Regex.run(~r/\b(\d{1,2})\/(\d{1,2})\/(\d{4})\b/, date_str) ->
        [_, day, month, year] = capture
        format_date(day, month, year)

      # DD/MM/YY
      capture = Regex.run(~r/\b(\d{1,2})\/(\d{1,2})\/(\d{2})\b/, date_str) ->
        [_, day, month, year] = capture
        format_date(day, month, expand_year(year))

      # DD. Month YYYY (English)
      capture =
          Regex.run(
            ~r/\b(\d{1,2})\s+(January|February|March|April|May|June|July|August|September|October|November|December)\s+(\d{4})\b/i,
            date_str
          ) ->
        [_, day, month_name, year] = capture
        month = convert_month_name_to_number(month_name)
        format_date(day, month, year)

      # DD. Mon YYYY (English abbreviated)
      capture =
          Regex.run(
            ~r/\b(\d{1,2})\s+(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d{4})\b/i,
            date_str
          ) ->
        [_, day, month_abbr, year] = capture
        month = convert_month_abbr_to_number(month_abbr)
        format_date(day, month, year)

      # Month YYYY (English)
      capture =
          Regex.run(
            ~r/\b(January|February|March|April|May|June|July|August|September|October|November|December)\s+(\d{4})\b/i,
            date_str
          ) ->
        [_, month_name, year] = capture
        month = convert_month_name_to_number(month_name)
        format_date("1", month, year)

      # Mon YYYY (English abbreviated)
      capture =
          Regex.run(~r/\b(Jan|Feb|Mar|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d{4})\b/i, date_str) ->
        [_, month_abbr, year] = capture
        month = convert_month_abbr_to_number(month_abbr)
        format_date("1", month, year)

      # DD.MM.YYYY
      capture = Regex.run(~r/\b(\d{1,2})\.(\d{1,2})\.(\d{4})\b/, date_str) ->
        [_, day, month, year] = capture
        format_date(day, month, year)

      # DD.MM.YY
      capture = Regex.run(~r/\b(\d{1,2})\.(\d{1,2})\.(\d{2})\b/, date_str) ->
        [_, day, month, year] = capture
        format_date(day, month, expand_year(year))

      # DD. Month YYYY (German)
      capture =
          Regex.run(
            ~r/\b(\d{1,2})\.\s+(Januar|Februar|März|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember)\s+(\d{4})\b/i,
            date_str
          ) ->
        [_, day, month_name, year] = capture
        month = convert_german_month_name_to_number(month_name)
        format_date(day, month, year)

      # DD. Mon YYYY (German abbreviated)
      capture =
          Regex.run(
            ~r/\b(\d{1,2})\.\s+(Jan|Feb|Mär|Apr|Mai|Jun|Jul|Aug|Sep|Okt|Nov|Dez)\s+(\d{4})\b/i,
            date_str
          ) ->
        [_, day, month_abbr, year] = capture
        month = convert_german_month_abbr_to_number(month_abbr)
        format_date(day, month, year)

      # DD. Month (German)
      capture =
          Regex.run(
            ~r/\b(\d{1,2})\.\s+(Januar|Februar|März|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember)\b/i,
            date_str
          ) ->
        [_, day, month_name] = capture
        month = convert_german_month_name_to_number(month_name)
        year = get_current_year()
        format_date(day, month, year)

      # DD. Mon (German abbreviated)
      capture =
          Regex.run(
            ~r/\b(\d{1,2})\.\s+(Jan|Feb|Mär|Apr|Mai|Jun|Jul|Aug|Sep|Okt|Nov|Dez)\b/i,
            date_str
          ) ->
        [_, day, month_abbr] = capture
        month = convert_german_month_abbr_to_number(month_abbr)
        year = get_current_year()
        format_date(day, month, year)

      # German Month YYYY
      capture =
          Regex.run(
            ~r/\b(Januar|Februar|März|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember)\s+(\d{4})\b/i,
            date_str
          ) ->
        [_, month_name, year] = capture
        month = convert_german_month_name_to_number(month_name)
        format_date("1", month, year)

      # German Mon YYYY
      capture =
          Regex.run(
            ~r/\b(Jan|Feb|Mär|Apr|Mai|Jun|Jul|Aug|Sep|Okt|Nov|Dez)\s+(\d{4})\b/i,
            date_str
          ) ->
        [_, month_abbr, year] = capture
        month = convert_german_month_abbr_to_number(month_abbr)
        format_date("1", month, year)

      # If no pattern matches, return original
      true ->
        date_str
    end
  end

  # Helper function to format date components
  defp format_date(day, month, year) do
    day_padded = String.pad_leading("#{day}", 2, "0")
    month_padded = String.pad_leading("#{month}", 2, "0")
    "#{day_padded}.#{month_padded}.#{year}"
  end

  # Helper function to expand 2-digit years to 4-digit years
  defp expand_year(year) do
    year_num = String.to_integer(year)
    if year_num < 50, do: "20#{year}", else: "19#{year}"
  end

  # Helper function to get current year
  defp get_current_year do
    DateTime.utc_now().year
  end

  # Helper function to convert English month names to numbers
  defp convert_month_name_to_number(month) do
    month_lower = String.downcase(month)

    case month_lower do
      "january" -> "1"
      "february" -> "2"
      "march" -> "3"
      "april" -> "4"
      "may" -> "5"
      "june" -> "6"
      "july" -> "7"
      "august" -> "8"
      "september" -> "9"
      "october" -> "10"
      "november" -> "11"
      "december" -> "12"
      # Default to January if unknown
      _ -> "1"
    end
  end

  # Helper function to convert English month abbreviations to numbers
  defp convert_month_abbr_to_number(month) do
    month_lower = String.downcase(month)

    case month_lower do
      "jan" -> "1"
      "feb" -> "2"
      "mar" -> "3"
      "apr" -> "4"
      "may" -> "5"
      "jun" -> "6"
      "jul" -> "7"
      "aug" -> "8"
      "sep" -> "9"
      "oct" -> "10"
      "nov" -> "11"
      "dec" -> "12"
      # Default to January if unknown
      _ -> "1"
    end
  end

  # Helper function to convert German month names to numbers
  defp convert_german_month_name_to_number(month) do
    month_lower = String.downcase(month)

    case month_lower do
      "januar" -> "1"
      "februar" -> "2"
      "märz" -> "3"
      "april" -> "4"
      "mai" -> "5"
      "juni" -> "6"
      "juli" -> "7"
      "august" -> "8"
      "september" -> "9"
      "oktober" -> "10"
      "november" -> "11"
      "dezember" -> "12"
      # Default to January if unknown
      _ -> "1"
    end
  end

  # Helper function to convert German month abbreviations to numbers
  defp convert_german_month_abbr_to_number(month) do
    month_lower = String.downcase(month)

    case month_lower do
      "jan" -> "1"
      "feb" -> "2"
      "mär" -> "3"
      "apr" -> "4"
      "mai" -> "5"
      "jun" -> "6"
      "jul" -> "7"
      "aug" -> "8"
      "sep" -> "9"
      "okt" -> "10"
      "nov" -> "11"
      "dez" -> "12"
      # Default to January if unknown
      _ -> "1"
    end
  end

  # Helper function to normalize values for comparison
  defp normalize_value(value) when is_binary(value) do
    String.trim(value)
  end

  defp normalize_value(value) do
    # For non-string values, convert to string for consistent comparison
    "#{value}"
  end

  def format_report_ids_for_mongodb(report_ids) do
    # For each report ID, create two formatted versions with suffixes 01 and 02
    Enum.flat_map(report_ids, fn report_id ->
      # Ensure we have a 5-digit ID, pad with zeros if needed
      padded_id = String.pad_leading(report_id, 5, "0")

      # Extract the needed parts (first 2 digits and last 2 digits)
      # Assuming the middle digit (3rd) should be 0 and is removed
      first_two = String.slice(padded_id, 0, 2)
      last_two = String.slice(padded_id, 3, 2)

      # Create the two formatted versions
      [
        "GA#{first_two}_#{last_two}_01",
        "GA#{first_two}_#{last_two}_02"
      ]
    end)
  end

  def reformat_report_id(report_id) do
    if Regex.match?(~r/^\d{5}$/, report_id) do
      {first_two, last_three} = String.split_at(report_id, 2)
      "GA#{first_two}/#{last_three}"
    else
      nil
    end
  end

  def normalize_report_id(report_id) do
  end

  # Helper function to sanitize report IDs
  def sanitize_report_id(id_value) do
    # Extract all digits
    digits = Regex.scan(~r/\d/, id_value) |> List.flatten()

    case length(digits) do
      n when n >= 5 ->
        # Take only the first 5 digits
        Enum.take(digits, 5) |> Enum.join("")

      n when n >= 3 ->
        # Extract first two digits
        first_two = Enum.take(digits, 2) |> Enum.join("")

        # Extract remaining digits
        remaining = Enum.drop(digits, 2) |> Enum.join("")

        # Calculate how many zeros to insert to make total length 5
        zeros_needed = 5 - 2 - String.length(remaining)
        zeros = String.duplicate("0", zeros_needed)

        # Combine parts
        first_two <> zeros <> remaining

      # Not enough digits (1-2)
      _ ->
        nil
    end
  end
end
