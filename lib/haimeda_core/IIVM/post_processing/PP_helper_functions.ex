defmodule PostProcessing.HelperFunctions do
  @date_patterns [
    # DD. Month YYYY (German)
    ~r/\b(\d{1,2})\.\s+(Januar|Februar|März|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember)\s+(\d{4})(?=[\s.,;:!?]|$)/i,
    ~r/\b(\d{1,2})\.\s+(Jan|Feb|Mär|Apr|Mai|Jun|Jul|Aug|Sep|Okt|Nov|Dez)\s+(\d{4})(?=[\s.,;:!?]|$)/i,

    # DD Month YYYY (English)
    ~r/\b(\d{1,2})\s+(January|February|March|April|May|June|July|August|September|October|November|December)\s+(\d{4})(?=[\s.,;:!?]|$)/i,
    ~r/\b(\d{1,2})\s+(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d{4})(?=[\s.,;:!?]|$)/i,

    # Numeric formats
    ~r/\b(\d{4})-(\d{1,2})-(\d{1,2})(?=[\s.,;:!?]|$)/,
    ~r/\b(\d{1,2})\/(\d{1,2})\/(\d{4})(?=[\s.,;:!?]|$)/,
    ~r/\b(\d{1,2})\/(\d{1,2})\/(\d{2})(?=[\s.,;:!?]|$)/,
    ~r/\b(\d{1,2})\.(\d{1,2})\.(\d{4})(?=[\s.,;:!?]|$)/,
    ~r/\b(\d{1,2})\.(\d{1,2})\.(\d{2})(?=[\s.,;:!?]|$)/,

    # Month YYYY (German)
    ~r/\b(Januar|Februar|März|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember)\s+(\d{4})(?=[\s.,;:!?]|$)/i,
    ~r/\b(Jan|Feb|Mär|Apr|Mai|Jun|Jul|Aug|Sep|Okt|Nov|Dez)\s+(\d{4})(?=[\s.,;:!?]|$)/i,

    # Month YYYY (English)
    ~r/\b(January|February|March|April|May|June|July|August|September|October|November|December)\s+(\d{4})(?=[\s.,;:!?]|$)/i,
    ~r/\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d{4})(?=[\s.,;:!?]|$)/i,

    # DD. Month (German, no year)
    ~r/\b(\d{1,2})\.\s+(Januar|Februar|März|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember)(?=[\s.,;:!?]|$)/i,
    ~r/\b(\d{1,2})\.\s+(Jan|Feb|Mär|Apr|Mai|Jun|Jul|Aug|Sep|Okt|Nov|Dez)(?=[\s.,;:!?]|$)/i
  ]

  @number_patterns [
    ~r/\b(\d+(?:[.,]\d+)*)(?:\s{0,4}[€%$])?\b/
  ]

  @identifier_patterns [
    # ~r/((?<![a-zA-Z0-9])(?:[a-zA-Z0-9]+(?:-[a-zA-Z0-9]+)+)\b)|((?<![a-zA-Z0-9])(?:[a-zA-Z]{2,}\d{2,})\b)|(\b(?:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\b)|(\b(?:[A-Z]{2,4}-\d{3,})\b)|(\b(?:[A-Z0-9]{8,}\.[A-Z0-9]{3,4})\b)|(\b(?:[A-Z]{2}\d{2}[A-Z0-9]{4,30})\b)|(\b(?:[A-Z]{2}\d{2}(?:[- ][A-Z0-9]{4})+)\b)|(\b(?:[A-Z]{4}[A-Z]{2}[A-Z0-9]{2}(?:[A-Z0-9]{3})?)\b)|(\b(?:(?:INV|REF|PO|ID)[-\/]?\d{4,})\b)|(\b(?:[A-Z]{2}\d{4,6})\b)|(\b(?:ISO \d{4,}(?:[-:]\d{4})?)\b)|(\b(?:[A-HJ-NPR-Z0-9]{17})\b)|(\b(?:(?:\d{4}[- ]){3}\d{4})\b)|(\b(?:\d{4}[- ]?\*{4}[- ]?\*{4}[- ]?\d{4})\b)|(\b(?:\d{3}-\d{2}-\d{4})\b)|(\b(?:\d{11})\b)|(\b(?:[A-Z]{2}[0-9A-Z]{6,12})\b)|(\b(?:[A-Z]{1,2}\d{6,9})\b)|(\b(?:(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?))\b)|(\b(?:(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4})\b)|(\b(?:(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2})\b)/i

    # ~r/(?<!\S)([A-Z]{2}-[A-Za-z0-9]+)(?=[\s.,;:!?]|$)/
    # Hyphenated IDs (e.g. BF-1htj0) - more restrictive
    ~r/(?<![a-zA-Z0-9])([a-zA-Z0-9]+(?:-[a-zA-Z0-9]+)+)\b/,

    # # # Alphanumeric IDs with letters and digits (e.g. ba058123) - more restrictive
    ~r/(?<![a-zA-Z0-9])([a-zA-Z]{2,}\d{2,})\b/,

    # # UUID format
    ~r/\b([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\b/i,

    # # License keys (groups of alphanumerics)
    ~r/\b((?:[A-Z0-9]{4,5}-){2,4}[A-Z0-9]{4,5})\b/i,

    # # Product codes (often prefix + numbers)
    ~r/\b([A-Z]{2,4}-\d{3,})\b/,

    # # File identifiers (extension-like patterns)
    ~r/\b([A-Z0-9]{8,}\.[A-Z0-9]{3,4})\b/i,

    # # IBAN (International Bank Account Number) - without spaces
    ~r/\b([A-Z]{2}\d{2}[A-Z0-9]{4,30})\b/,

    # # IBAN with spaces/dashes
    ~r/\b([A-Z]{2}\d{2}(?:[- ][A-Z0-9]{4})+)\b/,

    # # BIC/SWIFT code (Bank Identifier Code)
    ~r/\b([A-Z]{4}[A-Z]{2}[A-Z0-9]{2}(?:[A-Z0-9]{3})?)\b/,

    # # ISBN-13: 13 digits starting with 978 or 979
    ~r/\b(ISBN(?:-13)?:?\s*(?:978|979)[-\s]\d{1,5}[-\s]\d{1,7}[-\s]\d{1,7}[-\s]\d)\b/i,

    # # ISBN-10: 10 digits or 9 digits + X
    ~r/\b(ISBN(?:-10)?:?\s*\d{1,5}[-\s]\d{1,7}[-\s]\d{1,6}[-\s][\dX])\b/i,

    # # Invoice/reference numbers (often with prefix and slash)
    ~r/\b((?:INV|REF|PO|ID)[-\/]?\d{4,})\b/i,

    # # Alphanumeric codes with specific pattern (e.g. 2 letters + 4-6 digits)
    ~r/\b([A-Z]{2}\d{4,6})\b/,

    # # ISO standard identifiers (e.g. ISO 9001:2015)
    ~r/\b(ISO \d{4,}(?:[-:]\d{4})?)\b/i,

    # # Vehicle identification numbers (VIN)
    ~r/\b([A-HJ-NPR-Z0-9]{17})\b/i,

    # # Credit card masked format
    ~r/\b((?:\d{4}[- ]){3}\d{4})\b/,
    ~r/\b(\d{4}[- ]?\*{4}[- ]?\*{4}[- ]?\d{4})\b/,

    # # Social Security Number (US format)
    ~r/\b(\d{3}-\d{2}-\d{4})\b/,

    # # Tax IDs
    ~r/\b(\d{11})\b/,
    ~r/\b([A-Z]{2}[0-9A-Z]{6,12})\b/

    # # Passport numbers (various formats)
    # ~r/\b([A-Z]{1,2}\d{6,9})\b/,

    # # IP addresses
    # ~r/\b((?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?))\b/,
    # ~r/\b((?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4})\b/,

    # # MAC addresses
    # ~r/\b((?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2})\b/i

    # Driver's license (simplified patterns for common formats)
    # ~r/\b([A-Z]\d{2}-\d{2}-\d{4})\b/i,
    # ~r/\b([A-Z]{1,2}\d{3,7}[A-Z]{0,2})\b/,

    # German legal paragraph references
    # ~r/\b(§\s*\d+(?:[a-z])*(?:\s+(?:Abs\.|Absatz)\s+\d+(?:[a-z])*)?(?:\s+(?:S\.|Satz)\s+\d+)?(?:\s+(?:[A-Z]{2,5}|[A-Za-zäöüÄÖÜß]+gesetz))?)/,
    # ~r/\b(§§\s*\d+(?:[a-z])*\s*(?:-|–|bis)\s*\d+(?:[a-z])*(?:\s+(?:[A-Z]{2,5}|[A-Za-zäöüÄÖÜß]+gesetz))?)/,

    # English legal references
    # ~r/\b((?:Section|Sec\.|Article|Art\.|Paragraph|Para\.|Chapter|Chap\.|Title)\s+\d+(?:[a-z])*(?:\s+of\s+(?:the\s+)?[A-Z][A-Za-z\s]+)?)/i,
    # ~r/\b(§\s*\d+(?:[a-z])*(?:\s+of\s+(?:the\s+)?[A-Z][A-Za-z\s]+)?)/
  ]

  @phrase_patterns [
    # Basic phrase patterns:
    # Capture phrases between punctuation marks
    ~r/[.!?]\s+([A-Z][^.!?]+?)[.!?]/,
    # Capture phrases within quotes
    ~r/"([^"]+)"/,
    ~r/'([^']+)'/,
    ~r/„([^"]+)"/,
    ~r/«([^»]+)»/,
    # Capture phrases between commas
    ~r/,\s*([^,;.!?]+?),/,
    # Capture standalone phrases (start of text to punctuation)
    ~r/\A([A-Z][^.!?]+?)[.!?]/m,
    # Capture phrases preceded by common indicators
    ~r/\b(?:says|said|mentions|mentioned|notes|noted|explains|explained|according to|states|stated)\s+(?:that\s+)?([^.!?]+?)[.!?]/i,
    # Capture subject-verb phrases
    ~r/\b([A-Z][a-z]+(?:\s+[a-z]+){1,7}?\s+(?:is|are|was|were|has|have|had|will|would|can|could|may|might|must|should)\s+[^.!?]+?)[.!?]/,
    # Capture list items
    ~r/(?:^|\n)(?:[•\-*]\s+|\d+\.\s+)([^.!?\n]+)/,
    # Capture short sentences (2-8 words)
    ~r/\b([A-Za-z]+(?:\s+[A-Za-z]+){1,7})\b/
  ]

  # Extract one or multiple patterns from data

  def extract_date_patterns(data) do
    # Apply each regex pattern to the data
    @date_patterns
    |> Enum.flat_map(fn pattern ->
      case Regex.scan(pattern, data) do
        [] ->
          []

        matches ->
          # Extract the full match (first element of each match)
          matches |> Enum.map(fn [full_match | _] -> full_match end)
      end
    end)
    # Remove duplicates
    |> Enum.uniq()
  end

  def extract_number_patterns(data) do
    # Get date and identifier matches with their positions
    date_matches = collect_pattern_occurrences(data, @date_patterns)
    identifier_matches = collect_pattern_occurrences(data, @identifier_patterns)

    # Manually extract number matches with their positions to avoid recursion
    number_matches =
      Enum.flat_map(@number_patterns, fn pattern ->
        Regex.scan(pattern, data, return: :index)
        |> Enum.map(fn [{pos, len} | _] ->
          # Extract the matched text
          match_text = String.slice(data, pos, len)
          {pos, len, match_text}
        end)
      end)

    # IO.inspect(number_matches, label: "Number Matches")

    # Resolve overlapping number matches (keep longest matches)
    number_matches = resolve_overlapping_matches(number_matches)

    # IO.inspect(number_matches, label: "Resolved Number Matches")

    # Filter out number matches that overlap with date matches or identifier matches
    non_overlapping_numbers =
      Enum.reject(number_matches, fn {num_pos, num_len, _} ->
        # Check if this number position overlaps with any date position
        date_overlap =
          Enum.any?(date_matches, fn {date_pos, date_len, _} ->
            # Overlap occurs if:
            # 1. Number starts within date range
            # 2. Date starts within number range
            (num_pos >= date_pos && num_pos < date_pos + date_len) ||
              (date_pos >= num_pos && date_pos < num_pos + num_len)
          end)

        # Check if this number position overlaps with any identifier position
        identifier_overlap =
          Enum.any?(identifier_matches, fn {id_pos, id_len, _} ->
            # Same overlap detection logic
            (num_pos >= id_pos && num_pos < id_pos + id_len) ||
              (id_pos >= num_pos && id_pos < num_pos + num_len)
          end)

        # Return true if there's an overlap with either dates or identifiers
        date_overlap || identifier_overlap
      end)

    # Extract just the matched text for the result
    results =
      Enum.map(non_overlapping_numbers, fn {_, _, match_text} -> match_text end)
      |> Enum.uniq()

    # Explicitly return results to ensure we never return nil
    results
  end

  def extract_identifier_patterns(data) do
    # Get date matches with their positions
    date_matches = collect_pattern_occurrences(data, @date_patterns)

    # Manually extract identifier matches with their positions to avoid recursion
    identifier_matches =
      Enum.flat_map(@identifier_patterns, fn pattern ->
        Regex.scan(pattern, data, return: :index)
        |> Enum.map(fn [{pos, len} | _] ->
          # Extract the matched text
          match_text = String.slice(data, pos, len)
          {pos, len, match_text}
        end)
      end)

    # identifier_matches =
    #   Enum.flat_map(@identifier_patterns, fn pattern ->
    #     Regex.scan(pattern, data, return: :index)
    #     |> Enum.map(fn matches ->
    #       case matches do
    #         # If there are capture groups, use the first capture group
    #         [{_full_pos, _full_len}, {capture_pos, capture_len} | _] ->
    #           # Extract only the captured text (the identifier without surrounding context)
    #           match_text = String.slice(data, capture_pos, capture_len)
    #           {capture_pos, capture_len, match_text}

    #         # If no capture groups, fall back to full match
    #         [{pos, len}] ->
    #           match_text = String.slice(data, pos, len)
    #           {pos, len, match_text}
    #       end
    #     end)
    #   end)

    # IO.inspect(identifier_matches, label: "Identifier Matches")

    if identifier_matches != [] do
      IO.inspect(data, label: "Data for Identifier Extraction")
    end

    # Resolve overlapping identifier matches (keep longest matches)
    identifier_matches = resolve_overlapping_matches(identifier_matches)

    # IO.inspect(identifier_matches, label: "Resolved Identifier Matches")
    # Filter out identifier matches that overlap with date matches
    non_overlapping_identifiers =
      Enum.reject(identifier_matches, fn {id_pos, id_len, _} ->
        # Check if this identifier position overlaps with any date position
        Enum.any?(date_matches, fn {date_pos, date_len, _} ->
          # Overlap occurs if:
          # 1. Identifier starts within date range
          # 2. Date starts within identifier range
          (id_pos >= date_pos && id_pos < date_pos + date_len) ||
            (date_pos >= id_pos && date_pos < id_pos + id_len)
        end)
      end)

    # IO.inspect(non_overlapping_identifiers, label: "Non-overlapping Identifier Matches")

    # Extract just the matched text for the result
    results =
      Enum.map(non_overlapping_identifiers, fn {_, _, match_text} -> match_text end)
      |> Enum.uniq()

    # IO.inspect(results, label: "Final Identifier Results")

    results = Enum.reject(results, fn str -> String.match?(str, ~r/\s/) end)

    # Explicitly return results to ensure we never return nil
    results
  end

  def extract_phrase_patterns(data) do
    # Split data into words and count them
    words = data |> String.split(~r/\s+/, trim: true)
    word_count = length(words)

    # Only process if less than 5 words in total
    if word_count < 5 do
      # First collect all pattern occurrences with their positions
      date_matches = collect_pattern_occurrences(data, @date_patterns)
      number_matches = collect_pattern_occurrences(data, @number_patterns)
      identifier_matches = collect_pattern_occurrences(data, @identifier_patterns)

      # Combine all matches and sort by position
      all_matches = date_matches ++ number_matches ++ identifier_matches
      # IO.inspect(all_matches, label: "All Matches")

      # Create a map of non-whitespace characters
      # Each entry contains {original_pos, is_whitespace}
      char_map =
        data
        |> String.graphemes()
        |> Enum.with_index()
        |> Enum.map(fn {char, idx} -> {idx, !String.match?(char, ~r/\s/)} end)

      # Filter to get only non-whitespace positions
      non_whitespace_positions = Enum.filter(char_map, fn {_, is_non_ws} -> is_non_ws end)

      # Create a mapping from original positions to non-whitespace positions
      pos_mapping =
        Enum.reduce(char_map, %{}, fn {orig_pos, is_non_ws}, acc ->
          if is_non_ws do
            non_ws_idx = Enum.count(Map.values(acc))
            Map.put(acc, orig_pos, non_ws_idx)
          else
            acc
          end
        end)

      # Calculate non-whitespace text length
      non_ws_length = length(non_whitespace_positions)

      # Create a coverage map for non-whitespace characters only
      coverage = List.duplicate(false, non_ws_length)

      # Update coverage based on all pattern matches, mapping to non-whitespace positions
      updated_coverage =
        Enum.reduce(all_matches, coverage, fn {pos, len, match_text}, acc ->
          # For each character in the match, if it's non-whitespace, mark it as covered
          Enum.reduce(0..(len - 1), acc, fn offset, inner_acc ->
            orig_pos = pos + offset

            if Map.has_key?(pos_mapping, orig_pos) do
              # This is a non-whitespace character - mark it as covered
              non_ws_pos = Map.get(pos_mapping, orig_pos)
              List.replace_at(inner_acc, non_ws_pos, true)
            else
              # This is a whitespace - skip it
              inner_acc
            end
          end)
        end)

      # Calculate what percentage of the non-whitespace text is covered by patterns
      covered_count = Enum.count(updated_coverage, fn covered -> covered end)
      coverage_percentage = if non_ws_length > 0, do: covered_count / non_ws_length, else: 0.0

      # IO.inspect(covered_count, label: "Coverage chars")
      # IO.inspect(coverage_percentage, label: "Coverage Percentage")
      # If more than 60% is covered by other entities, don't create a phrase pattern
      if coverage_percentage > 0.6 do
        []
      else
        # Replace matches with placeholders
        sorted_matches = Enum.sort(all_matches, fn {pos1, _, _}, {pos2, _, _} -> pos1 < pos2 end)
        processed_text = sequential_replace_with_placeholders(data, sorted_matches)

        # Clean up punctuation and extra whitespace
        processed_text = clean_text(processed_text)

        # Remove placeholders at the beginning and at the end of the text
        cleaned_text = processed_text |> String.replace(~r/^\s*\[\d+\]\s*|\s*\[\d+\]\s*$/, "")

        # Check if the resulting text is just placeholders with possible spaces between them
        only_placeholders = Regex.match?(~r/^\s*(?:\[\d+\]\s*)*$/, cleaned_text)

        if only_placeholders || String.trim(cleaned_text) == "" do
          # If only placeholders remain or text is empty after removing edge placeholders, return empty list
          []
        else
          # Final check: ensure there's at least one real word left after all processing
          remaining_words =
            cleaned_text
            |> String.replace(~r/\[\d+\]/, "")
            |> String.split(~r/\s+/, trim: true)
            |> Enum.filter(fn word ->
              String.length(word) > 0 && !String.match?(word, ~r/^\[\d+\]$/)
            end)

          # IO.inspect(remaining_words, label: "Remaining Words")

          if length(remaining_words) > 0 do
            # Return the cleaned text without edge placeholders
            [cleaned_text]
          else
            []
          end
        end
      end
    else
      # If more than 5 words, return empty list
      []
    end
  end

  def extract_statements(data) when is_binary(data) do
    # Handle single string input by splitting it into statements,
    # then filtering for valid statements
    statements =
      data
      |> split_into_statements()
      |> Enum.filter(&valid_statement?/1)

    # Filter out statements that are primarily patterns (dates, numbers, identifiers)
    filtered_statements =
      Enum.filter(statements, fn statement ->
        # Extract all pattern matches for the statement
        date_matches = collect_pattern_occurrences(statement, @date_patterns)
        number_matches = collect_pattern_occurrences(statement, @number_patterns)
        identifier_matches = collect_pattern_occurrences(statement, @identifier_patterns)

        # IO.inspect(statement, label: "Original Data")
        # IO.inspect(date_matches, label: "Date Matches")
        # IO.inspect(number_matches, label: "Number Matches")
        # IO.inspect(identifier_matches, label: "Identifier Matches")
        # Combine all matches
        all_matches = date_matches ++ number_matches ++ identifier_matches

        # Calculate total statement length
        statement_length = String.length(statement)

        # Nothing to filter if statement is empty or no matches found
        if statement_length == 0 || all_matches == [] do
          true
        else
          # Create a coverage map to check how much of the text is covered by patterns
          coverage = List.duplicate(false, statement_length)

          # Update coverage based on all pattern matches
          updated_coverage =
            Enum.reduce(all_matches, coverage, fn {pos, len, _}, acc ->
              # Mark positions from pos to pos+len-1 as covered
              Enum.with_index(acc)
              |> Enum.map(fn {covered, idx} ->
                if idx >= pos && idx < pos + len, do: true, else: covered
              end)
            end)

          # IO.inspect(updated_coverage, label: "Updated Coverage")

          # Calculate coverage percentage
          covered_count = Enum.count(updated_coverage, fn covered -> covered end)
          coverage_percentage = covered_count / statement_length

          # IO.inspect(covered_count, label: "Coverage chars")
          # IO.inspect(coverage_percentage, label: "Coverage Percentage")
          # IO.puts("\n")

          # Keep statement only if less than 80% is covered by patterns
          coverage_percentage < 0.4
        end
      end)

    filtered_statements
  end

  @doc """
  Splits a text into statements based on sentence terminators.
  Also extracts content in brackets as separate statements while preserving their internal structure.
  Additionally detects and handles sub-clauses in sentences.
  Doesn't split at periods used in abbreviations (detected by a non-uppercase word following).
  """
  def split_into_statements(text) when is_binary(text) do
    # Extract bracket content first
    {text_without_brackets, bracket_contents} = extract_bracket_content(text)

    # Process for sentences with sub-clauses
    {text_without_subclauses, subclause_contents} = extract_subclauses(text_without_brackets)

    # Pre-process text to identify and protect abbreviations
    text_with_protected_abbrevs = protect_abbreviations(text_without_subclauses)

    # Process regular statements
    regular_statements =
      text_with_protected_abbrevs
      # Split at common sentence terminators
      |> String.split(~r/((?<=[,.;:!?\n])\s+|(?=\n))/, trim: true)
      |> Enum.map(&String.trim/1)
      # Remove terminal separators from each statement
      |> Enum.map(&String.replace(&1, ~r/[,.;:!?]$/, ""))
      # Restore periods in abbreviations
      |> Enum.map(&restore_abbreviation_periods/1)
      |> Enum.reject(&(String.length(&1) == 0))

    # Combine all extracted statements
    (regular_statements ++ bracket_contents ++ subclause_contents)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(String.length(&1) == 0))
  end

  def split_into_statements(_), do: []

  # Helper function to protect periods in abbreviations by replacing them temporarily
  defp protect_abbreviations(text) do
    # This regex looks for a period followed by a space and a lowercase letter
    # indicating that the period is likely part of an abbreviation, not a sentence end
    Regex.replace(~r/(\.)(\s+)([a-z])/u, text, fn _, period, space, next_char ->
      # Replace period with a special marker that won't be split on
      "^^ABBREV^^#{space}#{next_char}"
    end)
  end

  # Helper function to restore abbreviation periods
  defp restore_abbreviation_periods(text) do
    String.replace(text, "^^ABBREV^^", ".")
  end

  # Helper function to extract sub-clauses in sentences
  defp extract_subclauses(text) do
    # First, split text into sentences to avoid processing across sentence boundaries
    sentences = String.split(text, ~r/(?<=\.)\s+/, trim: true)

    # Process each sentence separately
    sentences_results =
      Enum.map(sentences, fn sentence ->
        # Match sentences with sub-clauses (text between two commas with at least 3 words)
        # The pattern now looks for: some text within a single sentence,
        # then comma, then 3+ words, then another comma, then text until end of sentence
        subclause_regex = ~r/([^,.]+),\s*([^,]+(?:\s+\w+){2,}),\s*([^.]+)/

        # Find potential sub-clause in this sentence
        case Regex.run(subclause_regex, sentence) do
          [full_match, prefix, subclause, suffix] ->
            # Create the main sentence by joining prefix and suffix
            main_sentence = "#{String.trim(prefix)} #{String.trim(suffix)}"
            clean_subclause = String.trim(subclause)

            # Return the modified sentence and the extracted subclause
            {main_sentence, [clean_subclause]}

          nil ->
            # No subclause found in this sentence
            {sentence, []}
        end
      end)

    # Combine results from all sentences
    {
      Enum.map(sentences_results, fn {sent, _} -> sent end) |> Enum.join(" "),
      Enum.flat_map(sentences_results, fn {_, subclauses} -> subclauses end)
    }
  end

  # Helper function to extract content inside brackets and return both the content
  # without brackets and the extracted content as separate statements
  defp extract_bracket_content(text) do
    # Match content inside various bracket types
    bracket_regex = ~r/\(([^()]+)\)|\[([^\[\]]+)\]|\{([^{}]+)\}/

    # Find all bracket contents
    brackets = Regex.scan(bracket_regex, text)

    # Extract matched content from capture groups (any of the bracket types)
    bracket_contents =
      Enum.map(brackets, fn match ->
        # Each match has the format [full_match, paren_content, square_content, curly_content]
        # We take the first non-nil capture group
        match
        # Skip the full match
        |> Enum.drop(1)
        |> Enum.find(&(&1 != nil))
        |> String.trim()
      end)

    # Replace bracketed content with a single space, ensuring proper spacing
    text_without_brackets =
      Regex.replace(bracket_regex, text, fn full_match, _, _, _ ->
        # Check if there are spaces before and after the match
        cond do
          # Already has spaces on both sides, replace with single space
          String.match?(text, ~r/\s#{Regex.escape(full_match)}\s/) -> " "
          # Space before but not after, keep one space
          String.match?(text, ~r/\s#{Regex.escape(full_match)}/) -> " "
          # Space after but not before, keep one space
          String.match?(text, ~r/#{Regex.escape(full_match)}\s/) -> " "
          # No spaces on either side, add one space
          true -> " "
        end
      end)

    # Normalize any multiple spaces that might have been created
    text_without_brackets = String.replace(text_without_brackets, ~r/\s+/, " ")

    {text_without_brackets, bracket_contents}
  end

  @doc """
  Validates that a statement is worth comparing (not too short, contains meaningful text)
  """
  def valid_statement?(statement) do
    # Statement should be at least 3 characters long
    # And contain at least one alphanumeric character
    String.length(statement) >= 5 &&
      Regex.match?(~r/[a-zA-Z0-9]/, statement)
  end

  # Sequential pattern replacement helper
  defp sequential_replace_with_placeholders(text, matches) do
    matches
    |> Enum.sort(fn {p1, _, _}, {p2, _, _} -> p1 < p2 end)
    |> Enum.reduce(text, fn {_pos, len, match_text}, acc ->
      placeholder = "[#{len}]"
      String.replace(acc, match_text, placeholder, global: false)
    end)
  end

  # Helper function to collect matches for a given set of patterns
  defp collect_pattern_occurrences(text, patterns) do
    # Determine which extraction function to use based on the patterns
    extraction_function =
      cond do
        patterns == @date_patterns -> &extract_date_patterns/1
        patterns == @number_patterns -> &extract_number_patterns/1
        patterns == @identifier_patterns -> &extract_identifier_patterns/1
        true -> nil
      end

    if extraction_function do
      # 1. First extract all matches using the appropriate extraction function
      extracted_matches = extraction_function.(text)

      # 2. For each extracted match, find its position in the original text
      matches =
        Enum.flat_map(extracted_matches, fn match ->
          # Escape special regex characters in the match to use it as a literal search pattern
          escaped_match = Regex.escape(match)

          # Find all occurrences of this exact match in the text
          Regex.scan(~r/#{escaped_match}/, text, return: :index)
          |> Enum.map(fn [{pos, len} | _] ->
            # Return position, length, and the matched text
            {pos, len, match}
          end)
        end)

      # 3. Resolve overlapping matches by keeping only the most comprehensive match
      matches |> resolve_overlapping_matches()
    else
      # Fallback to the original implementation if no specific extraction function is identified
      matches =
        Enum.flat_map(patterns, fn pattern ->
          Regex.scan(pattern, text, return: :index)
          |> Enum.map(fn [{pos, len} | _] ->
            # Extract the matched text
            match_text = String.slice(text, pos, len)
            {pos, len, match_text}
          end)
        end)

      # Resolve overlapping matches here as well
      matches |> resolve_overlapping_matches()
    end
  end

  # Resolve overlapping matches helper
  defp resolve_overlapping_matches(matches) do
    # Sort by position and then by length (descending) for better overlap detection
    sorted_matches =
      Enum.sort(matches, fn {pos1, len1, _}, {pos2, len2, _} ->
        if pos1 == pos2, do: len1 > len2, else: pos1 < pos2
      end)

    # Remove overlapping matches, preferring longer matches
    Enum.reduce(sorted_matches, [], fn current_match = {curr_pos, curr_len, _}, acc ->
      # Check if current match overlaps with any already accepted match
      overlapping =
        Enum.any?(acc, fn {acc_pos, acc_len, _} ->
          # Check for overlap: one match starts within the range of another match
          (curr_pos >= acc_pos && curr_pos < acc_pos + acc_len) ||
            (acc_pos >= curr_pos && acc_pos < curr_pos + curr_len)
        end)

      if overlapping do
        # If there's an overlap, check if we should replace an existing match
        replacement_made = false

        new_acc =
          Enum.map(acc, fn existing = {ex_pos, ex_len, _} ->
            # If matches overlap and current is longer or starts earlier, replace the existing one
            if ((curr_pos >= ex_pos && curr_pos < ex_pos + ex_len) ||
                  (ex_pos >= curr_pos && ex_pos < curr_pos + curr_len)) &&
                 (curr_len > ex_len || (curr_len == ex_len && curr_pos < ex_pos)) do
              replacement_made = true
              current_match
            else
              existing
            end
          end)

        # If no replacement was made, it means current match is suboptimal, so ignore it
        if replacement_made, do: new_acc, else: acc
      else
        # No overlap, add to accepted matches
        [current_match | acc]
      end
    end)
    # Reverse back to position-based order
    |> Enum.reverse()
    # Remove any duplicates that might have been created
    |> Enum.uniq()
  end

  # Helper function to replace matches with placeholder tags
  defp replace_matches_with_placeholders(text, matches) do
    # Convert text to charlist for easier manipulation
    text_chars = String.graphemes(text)
    text_length = length(text_chars)

    # Process matches in reverse order to avoid position shifts
    {result, _} =
      Enum.reverse(matches)
      |> Enum.reduce({text_chars, 0}, fn {pos, len, match_text}, {current_chars, offset} ->
        # Calculate the actual position with offset
        actual_pos = pos - offset

        # Split the charlist at the match position
        {prefix, rest} = Enum.split(current_chars, actual_pos)
        {_, suffix} = Enum.split(rest, len)
        placeholder_len = len

        # Create placeholder with length of the matched pattern
        placeholder = "[#{placeholder_len}]"

        # Calculate new offset (difference between original and placeholder length)
        new_offset = offset + (len - String.length(placeholder))

        # Rebuild the text with placeholder
        {prefix ++ String.graphemes(placeholder) ++ suffix, new_offset}
      end)

    # Convert back to string
    Enum.join(result, "")
  end

  # Helper function to clean up punctuation and whitespace
  defp clean_text(text) do
    text
    # Replace punctuation with space
    |> String.replace(~r/[.,;:!?"\n\r]/, " ")
    # Normalize whitespace
    |> String.replace(~r/\s+/, " ")
    # Remove leading/trailing whitespace
    |> String.trim()
  end

  #
  # Create derivations
  #

  def create_date_derivations(pattern) do
    # Attempt to parse the input pattern using all available patterns
    case parse_date_using_patterns(pattern) do
      nil ->
        [pattern]

      {day, month, year} ->
        # Start with the original pattern
        [pattern | generate_date_variations(day, month, year)]
        |> Enum.uniq()
    end
  end

  def create_number_derivations(pattern) do
    # Enhanced logic to create more comprehensive variations
    variations =
      case extract_number_parts(pattern) do
        nil ->
          # If we can't parse the number, return just the original pattern
          []

        {integer_part, decimal_part} ->
          # Generate variations with different formats
          generate_number_format_variations(integer_part, decimal_part)
      end

    # Start with the original pattern and add all variations
    integer_only_allowed =
      case extract_number_parts(pattern) do
        {_, decimal_part} when is_binary(decimal_part) ->
          String.replace(decimal_part, ~r/0/, "") == ""

        {_, nil} ->
          true

        _ ->
          false
      end

    filtered_variations =
      variations
      |> Enum.reject(fn variation ->
        # Remove integer-only version if not allowed
        not integer_only_allowed and Regex.match?(~r/^\d+$/, variation)
      end)
      |> Enum.uniq()
      |> Enum.reject(fn variation ->
        # Reject variations that look like dates
        Enum.any?(@date_patterns, fn date_pattern ->
          Regex.match?(date_pattern, variation)
        end)
      end)

    [pattern | filtered_variations]
  end

  # Extract integer and decimal parts from a number pattern
  defp extract_number_parts(pattern) do
    # Remove non-numeric characters (except . and ,)
    clean_pattern = String.replace(pattern, ~r/[^0-9.,]/, "")

    cond do
      # Format with comma as decimal separator: 23298,00
      Regex.match?(~r/^\d+,\d+$/, clean_pattern) ->
        [integer_part, decimal_part] = String.split(clean_pattern, ",")
        {integer_part, decimal_part}

      # Format with dot as decimal separator: 23298.00
      Regex.match?(~r/^\d+\.\d+$/, clean_pattern) ->
        [integer_part, decimal_part] = String.split(clean_pattern, ".")
        {integer_part, decimal_part}

      # Format with thousand separators using dots: 23.298,00
      Regex.match?(~r/^\d{1,3}(?:\.\d{3})*,\d+$/, clean_pattern) ->
        [integer_with_separators, decimal_part] = String.split(clean_pattern, ",")
        integer_part = String.replace(integer_with_separators, ".", "")
        {integer_part, decimal_part}

      # Format with thousand separators using commas: 23,298.00
      Regex.match?(~r/^\d{1,3}(?:,\d{3})*\.\d+$/, clean_pattern) ->
        [integer_with_separators, decimal_part] = String.split(clean_pattern, ".")
        integer_part = String.replace(integer_with_separators, ",", "")
        {integer_part, decimal_part}

      # Format with space as thousand separator: 23 298,00
      Regex.match?(~r/^\d{1,3}(?: \d{3})*,\d+$/, clean_pattern) ->
        [integer_with_spaces, decimal_part] = String.split(clean_pattern, ",")
        integer_part = String.replace(integer_with_spaces, " ", "")
        {integer_part, decimal_part}

      # Just an integer without decimal part: 23298
      Regex.match?(~r/^\d+$/, clean_pattern) ->
        {clean_pattern, nil}

      # Can't parse the pattern
      true ->
        nil
    end
  end

  # Generate different number format variations based on integer and decimal parts
  defp generate_number_format_variations(integer_part, decimal_part) do
    # Ensure we have proper strings
    integer_str = "#{integer_part}"

    # Always include integer-only variations (without decimal part)
    integer_only_variations = [
      # Just the integer without any formatting
      "#{integer_str}"
    ]

    # Add thousand separator variations for the integer-only format if length >= 4
    integer_only_variations =
      if String.length(integer_str) >= 4 do
        with_dots = format_with_separators(integer_str, ".", 3)
        with_commas = format_with_separators(integer_str, ",", 3)
        with_spaces = format_with_separators(integer_str, " ", 3)

        integer_only_variations ++ [with_dots, with_commas, with_spaces]
      else
        integer_only_variations
      end

    # Prepare variations with decimal part if it exists
    decimal_variations =
      if decimal_part do
        [
          # Basic formats with decimal parts
          # With dot
          "#{integer_str}.#{decimal_part}",
          # With comma
          "#{integer_str},#{decimal_part}"
        ]
      else
        # For integers, add variations with decimal zeros
        [
          # With dot and zeros
          "#{integer_str}.00",
          # With comma and zeros
          "#{integer_str},00"
        ]
      end

    # For numbers with 4+ digits, add thousand separator variations with decimal part
    thousand_variations =
      if String.length(integer_str) >= 4 do
        # Format with different thousand separators
        with_dots = format_with_separators(integer_str, ".", 3)
        with_commas = format_with_separators(integer_str, ",", 3)
        with_spaces = format_with_separators(integer_str, " ", 3)

        if decimal_part do
          [
            # With dots as thousand separators
            "#{with_dots},#{decimal_part}",
            # With commas as thousand separators
            "#{with_commas}.#{decimal_part}",
            # With spaces as thousand separators
            "#{with_spaces}.#{decimal_part}",
            "#{with_spaces},#{decimal_part}"
          ]
        else
          [
            # With added decimal zeros
            "#{with_dots},00",
            "#{with_commas}.00",
            "#{with_spaces}.00",
            "#{with_spaces},00"
          ]
        end
      else
        []
      end

    # Combine all variation types
    integer_only_variations ++ decimal_variations ++ thousand_variations
  end

  # Format a number with separators at specified intervals
  defp format_with_separators(number_str, separator, interval) do
    number_str
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(interval)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
    |> Enum.join(separator)
  end

  def create_identifier_derivations(pattern) do
    # Start with the original pattern as the first item
    [pattern | generate_identifier_variations(pattern)]
    |> Enum.uniq()
    |> Enum.reject(fn variation ->
      # Reject variations that look like dates or numbers
      Enum.any?(@date_patterns, fn date_pattern ->
        Regex.match?(date_pattern, variation)
      end) or
        Enum.any?(@number_patterns, fn number_pattern ->
          Regex.match?(number_pattern, variation)
        end)
    end)
  end

  def create_phrase_derivations(pattern) do
    # Check if the pattern contains placeholders before attempting replacement
    has_placeholders = String.match?(pattern, ~r/\[\d+\]/)

    # Process placeholders like [10] and convert them to regex patterns if they exist
    processed_pattern =
      if has_placeholders do
        # First check if pattern ends with a placeholder
        end_placeholder = Regex.run(~r/\s*\[(\d+)\]\s*$/, pattern)

        # Process all placeholders
        processed =
          Regex.replace(~r/\s*\[(\d+)\]\s*/, pattern, fn _, length_str ->
            length = String.to_integer(length_str) + 4
            ".{0,#{length}}"
          end)

        # Make sure the pattern has a word boundary marker at the end if it ended with a placeholder
        if end_placeholder do
          processed = String.replace_trailing(processed, "\\b", "")
        end

        processed
      else
        pattern
      end

    # Escape literal segments and preserve regex placeholders:
    escaped_pattern =
      Regex.split(~r/(\.\{0,\d+\})/, processed_pattern, include_captures: true)
      |> Enum.map(fn segment ->
        if Regex.match?(~r/^\.\{0,\d+\}$/, segment), do: segment, else: Regex.escape(segment)
      end)
      |> Enum.join("")

    original_regex = "\\b" <> escaped_pattern <> "\\b"

    # Extract words from the pattern and sanitize them
    # If we have placeholders, remove them before word splitting
    words =
      if has_placeholders do
        pattern
        # Remove placeholder tags for word counting
        |> String.replace(~r/\s*\[\d+\]\s*/, " ")
        |> String.split(~r/\s+/)
      else
        pattern |> String.split(~r/\s+/)
      end
      |> Enum.map(&sanitize_word/1)
      |> Enum.filter(fn word ->
        # Keep only meaningful words (longer than 4 characters)
        String.length(word) > 4
      end)

    # If fewer than 2 meaningful words, just return the original pattern
    if length(words) < 2 do
      [original_regex, String.downcase(original_regex)]
    else
      # Extract word stems using German stemming
      stems =
        words
        |> Enum.map(fn word ->
          word
          |> german_stem()
        end)
        # Only keep stems of sufficient length
        |> Enum.filter(&(String.length(&1) >= 4))

      # Create variations with stems and flexible spacing
      variations =
        if length(stems) >= 2 do
          # Build a regex pattern with stems and flexible gaps
          flexible_regex =
            stems
            |> Enum.join(".{0,10}")
            |> then(fn joined -> "\\b#{joined}.{0,10}\\b" end)

          [flexible_regex]
        else
          []
        end

      downcase_variations =
        variations
        |> Enum.map(&String.downcase/1)

      # Only mix up words if pattern contains fewer than 5 words to avoid excessive combinations
      mixup_variations =
        if length(stems) < 5 do
          mixup_words_variations(variations)
        else
          []
        end

      downcase_mixup_variations =
        mixup_variations
        |> Enum.map(&String.downcase/1)

      # Extract only words with starting uppercase letter from variations
      only_noun_variations = extract_german_noun_pattern(List.first(variations))

      final_variations =
        ([original_regex, String.downcase(original_regex)] ++
           variations ++ downcase_variations ++ mixup_variations ++ downcase_mixup_variations)
        |> Enum.uniq()

      if only_noun_variations && length(only_noun_variations) > 0 do
        noun_mixed_up_variations = mixup_words_variations(only_noun_variations)

        noun_downcase_variations =
          noun_mixed_up_variations
          |> Enum.map(&String.downcase/1)

        noun_downcase_mixup_variations =
          noun_mixed_up_variations
          |> Enum.map(&String.downcase/1)

        # Return all possible variations
        (final_variations ++
           only_noun_variations ++
           noun_downcase_variations ++
           noun_mixed_up_variations ++
           noun_downcase_mixup_variations)
        |> Enum.uniq()
      else
        # Return just the original, stem variations and their downcased versions
        final_variations
      end
    end
  end

  # Helper function to extract German noun patterns (words starting with uppercase)
  defp extract_german_noun_pattern(pattern) do
    if is_nil(pattern) do
      nil
    else
      # First, clean up the pattern by removing regex markers
      clean_pattern =
        pattern
        |> String.replace("\\b", "")
        |> String.replace("\\\\b", "")
        |> String.replace("\\s*", " ")

      # Extract actual words, ignoring the .{0,\d+} patterns
      words =
        Regex.scan(~r/([A-Za-zÄÖÜäöüß]+)(?:\.{0,\d+})?/, clean_pattern)
        |> Enum.map(fn [_, word] -> word end)

      # Count the German nouns (words starting with uppercase)
      german_nouns =
        words
        |> Enum.filter(fn word ->
          String.match?(word, ~r/^[A-ZÄÖÜ]/)
        end)

      # Only proceed if we have at least two German nouns
      if length(german_nouns) >= 2 do
        # Create a new pattern that makes non-noun words more flexible
        processed_pattern =
          Enum.reduce(words, pattern, fn word, acc ->
            if String.match?(word, ~r/^[A-ZÄÖÜ]/) do
              # Keep German nouns exactly as they are
              acc
            else
              # Replace non-German noun words with flexible patterns
              # Use word boundaries to ensure exact word replacement
              String.replace(acc, word, fn _ ->
                length = String.length(word) + 4
                ".{0,#{length}}"
              end)
            end
          end)

        [processed_pattern]
      else
        # Not enough German nouns found

        nil
      end
    end
  end

  # Other helper functions

  # Sanitize words by removing punctuation and extra whitespace
  defp sanitize_word(word) do
    word
    |> String.replace(~r/[,\.\-_\(\)\[\]\{\}\<\>\?!:;\"\'´`]/, "")
    |> String.trim()
  end

  # German word stemming function
  defp german_stem(word) do
    # Ensure minimum length - don't stem very short words
    if String.length(word) < 6 do
      word
    else
      # Start with the original word
      word
      # Remove common German noun suffixes
      |> remove_suffix("ungen")
      |> remove_suffix("heit")
      |> remove_suffix("keit")
      |> remove_suffix("isch")
      |> remove_suffix("chen")
      |> remove_suffix("lein")
      |> remove_suffix("ling")
      |> remove_suffix("lich")
      |> remove_suffix("isch")
      |> remove_suffix("ität")
      |> remove_suffix("tion")
      |> remove_suffix("ung")
      |> remove_suffix("bar")
      |> remove_suffix("nis")
      |> remove_suffix("sam")
      |> remove_suffix("end")
      |> remove_suffix("ern")
      |> remove_suffix("ion")
      |> remove_suffix("tät")
      # Remove common verb endings
      |> remove_suffix("test")
      |> remove_suffix("end")
      |> remove_suffix("est")
      |> remove_suffix("ten")
      |> remove_suffix("tet")
      |> remove_suffix("ter")
      |> remove_suffix("ten")
      |> remove_suffix("en")
      |> remove_suffix("st")
      |> remove_suffix("te")
      |> remove_suffix("et")
      |> remove_suffix("er")
      |> remove_suffix("em")
      |> remove_suffix("es")
      |> remove_suffix("en")
      |> remove_suffix("nd")
      |> remove_suffix("t")
      |> remove_suffix("e")
      # Ensure minimum stem length
      |> ensure_minimum_stem_length(4)
    end
  end

  # Helper function to remove a suffix if present and result would be long enough
  defp remove_suffix(word, suffix) do
    if String.ends_with?(word, suffix) do
      stem_length = String.length(word) - String.length(suffix)

      if stem_length >= 4 do
        String.slice(word, 0, stem_length)
      else
        word
      end
    else
      word
    end
  end

  # Helper function to ensure minimum stem length
  defp ensure_minimum_stem_length(stem, min_length) do
    if String.length(stem) < min_length do
      original_length = String.length(stem)

      if original_length < min_length do
        stem
      else
        String.slice(stem, 0, original_length)
      end
    else
      stem
    end
  end

  # Generate variations for identifier patterns
  defp generate_identifier_variations(pattern) do
    # Find potential separators in the pattern
    has_dash = String.contains?(pattern, "-")
    has_underscore = String.contains?(pattern, "_")
    has_dot = String.contains?(pattern, ".")
    has_slash = String.contains?(pattern, "/")
    has_space = String.contains?(pattern, " ")

    # Split the pattern into segments based on common separators
    segments =
      pattern
      |> String.replace(~r/[-_\.\/ ]/, "|")
      |> String.split("|", trim: true)

    # Only proceed with variations if we have meaningful segments
    if length(segments) > 1 do
      variations = []

      # 1. Generate variations with different separators
      variations =
        variations ++
          [
            Enum.join(segments, "-"),
            Enum.join(segments, "_"),
            Enum.join(segments, "."),
            Enum.join(segments, "/"),
            Enum.join(segments, " ")
          ]

      # 2. Generate variations with double separators
      if has_dash do
        variations = variations ++ [String.replace(pattern, "-", "--")]
      end

      if has_underscore do
        variations = variations ++ [String.replace(pattern, "_", "__")]
      end

      if has_dot do
        variations = variations ++ [String.replace(pattern, ".", "..")]
      end

      if has_slash do
        variations = variations ++ [String.replace(pattern, "/", "//")]
      end

      # 3. Generate variations with no separators
      variations = variations ++ [Enum.join(segments, "")]

      # 4. Generate casing variations (if applicable)
      if Regex.match?(~r/[a-z]/, pattern) and Regex.match?(~r/[A-Z]/, pattern) do
        variations =
          variations ++
            [
              String.upcase(pattern),
              String.downcase(pattern)
            ]
      end

      # 5. Generate variations with spaces around separators
      if has_dash do
        variations = variations ++ [String.replace(pattern, "-", " - ")]
      end

      if has_underscore do
        variations = variations ++ [String.replace(pattern, "_", " _ ")]
      end

      if has_dot do
        variations = variations ++ [String.replace(pattern, ".", " . ")]
      end

      if has_slash do
        variations = variations ++ [String.replace(pattern, "/", " / ")]
      end

      # 6. Handle alphanumeric patterns with potential formatting variations
      if Regex.match?(~r/^[A-Z0-9-_\.\/]+$/, pattern) do
        # For alphanumeric identifiers, generate variations with different groupings
        if String.length(pattern) > 6 do
          # Example: "ABC1234" could be "ABC-1234" or "ABC.1234"
          case Regex.run(~r/^([A-Z]+)(\d+)$/, pattern) do
            [_, letters, numbers] ->
              variations =
                variations ++
                  [
                    "#{letters}-#{numbers}",
                    "#{letters}.#{numbers}",
                    "#{letters}_#{numbers}",
                    "#{letters} #{numbers}"
                  ]

            _ ->
              nil
          end
        end
      end

      variations
      # Remove the original pattern
      |> Enum.reject(fn var -> var == pattern end)
      |> Enum.filter(fn var ->
        # Ensure the variation is recognizably similar to the original
        segments_similarity(pattern, var) > 0.6
      end)
    else
      # If no separators or only one segment, return limited variations
      case Regex.run(~r/^([A-Za-z]+)(\d+)$/, pattern) do
        [_, letters, numbers] ->
          [
            "#{letters}-#{numbers}",
            "#{letters}.#{numbers}",
            "#{letters}_#{numbers}",
            "#{letters} #{numbers}",
            String.upcase(pattern),
            String.downcase(pattern)
          ]

        _ ->
          []
      end
    end
  end

  # Helper function to measure similarity between two strings for identifier variations
  defp segments_similarity(original, variation) do
    # Extract alphanumeric content from both strings
    original_content = String.replace(original, ~r/[^A-Za-z0-9]/, "")
    variation_content = String.replace(variation, ~r/[^A-Za-z0-9]/, "")

    # If variation contains all the content from original (ignoring separators),
    # consider it similar
    if String.contains?(variation_content, original_content) or
         String.contains?(original_content, variation_content) do
      1.0
    else
      # Calculate string similarity
      original_length = String.length(original_content)
      variation_length = String.length(variation_content)

      # Count characters that appear in both strings
      common_chars =
        original_content
        |> String.graphemes()
        |> Enum.count(fn char -> String.contains?(variation_content, char) end)

      # Similarity ratio
      common_chars / max(original_length, variation_length)
    end
  end

  # Parse a date pattern using the defined @date_patterns
  defp parse_date_using_patterns(pattern) do
    # Try each regex pattern to parse the date
    Enum.reduce_while(@date_patterns, nil, fn regex, _acc ->
      case Regex.run(regex, pattern) do
        nil ->
          {:cont, nil}

        captures ->
          case extract_date_components(regex, captures) do
            nil -> {:cont, nil}
            result -> {:halt, result}
          end
      end
    end)
  end

  # Extract date components based on the matched regex pattern
  defp extract_date_components(regex, captures) do
    case regex do
      # ISO format: YYYY-MM-DD
      ~r/\b(\d{4})-(\d{1,2})-(\d{1,2})\b/ ->
        [_, year, month, day] = captures
        {String.to_integer(day), String.to_integer(month), String.to_integer(year)}

      # DD/MM/YYYY or MM/DD/YYYY - assuming DD/MM/YYYY
      ~r/\b(\d{1,2})\/(\d{1,2})\/(\d{4})\b/ ->
        [_, day, month, year] = captures
        {String.to_integer(day), String.to_integer(month), String.to_integer(year)}

      # DD/MM/YY or MM/DD/YY - assuming DD/MM/YY
      ~r/\b(\d{1,2})\/(\d{1,2})\/(\d{2})\b/ ->
        [_, day, month, year] = captures
        year_int = String.to_integer(year)
        full_year = if year_int < 50, do: 2000 + year_int, else: 1900 + year_int
        {String.to_integer(day), String.to_integer(month), full_year}

      # DD.MM.YYYY
      ~r/\b(\d{1,2})\.(\d{1,2})\.(\d{4})\b/ ->
        [_, day, month, year] = captures
        {String.to_integer(day), String.to_integer(month), String.to_integer(year)}

      # DD.MM.YY
      ~r/\b(\d{1,2})\.(\d{1,2})\.(\d{2})\b/ ->
        [_, day, month, year] = captures
        year_int = String.to_integer(year)
        full_year = if year_int < 50, do: 2000 + year_int, else: 1900 + year_int
        {String.to_integer(day), String.to_integer(month), full_year}

      # DD Month YYYY (English)
      ~r/\b(\d{1,2})\s+(January|February|March|April|May|June|July|August|September|October|November|December)\s+(\d{4})\b/i ->
        [_, day, month_name, year] = captures
        month = get_month_number(month_name)
        {String.to_integer(day), month, String.to_integer(year)}

      # DD Mon YYYY (English)
      ~r/\b(\d{1,2})\s+(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d{4})\b/i ->
        [_, day, month_abbr, year] = captures
        month = get_month_number(month_abbr)
        {String.to_integer(day), month, String.to_integer(year)}

      # Month YYYY - No day (English)
      ~r/\b(January|February|March|April|May|June|July|August|September|October|November|December)\s+(\d{4})\b/i ->
        [_, month_name, year] = captures
        month = get_month_number(month_name)
        # No day specified - use nil to indicate day is missing
        {nil, month, String.to_integer(year)}

      # Mon YYYY - No day (English)
      ~r/\b(Jan|Feb|Mar|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d{4})\b/i ->
        [_, month_abbr, year] = captures
        month = get_month_number(month_abbr)
        # No day specified - use nil to indicate day is missing
        {nil, month, String.to_integer(year)}

      # DD. Month YYYY (German)
      ~r/\b(\d{1,2})\.\s+(Januar|Februar|März|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember)\s+(\d{4})\b/i ->
        [_, day, month_name, year] = captures
        month = get_month_number(month_name)
        {String.to_integer(day), month, String.to_integer(year)}

      # DD. Mon YYYY (German)
      ~r/\b(\d{1,2})\.\s+(Jan|Feb|Mär|Apr|Mai|Jun|Jul|Aug|Sep|Okt|Nov|Dez)\s+(\d{4})\b/i ->
        [_, day, month_abbr, year] = captures
        month = get_month_number(month_abbr)
        {String.to_integer(day), month, String.to_integer(year)}

      # DD. Month (German) - No year
      ~r/\b(\d{1,2})\.\s+(Januar|Februar|März|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember)\b/i ->
        [_, day, month_name] = captures
        month = get_month_number(month_name)
        # No year specified - use nil to indicate year is missing
        {String.to_integer(day), month, nil}

      # DD. Mon (German) - No year
      ~r/\b(\d{1,2})\.\s+(Jan|Feb|Mär|Apr|Mai|Jun|Jul|Aug|Sep|Okt|Nov|Dez)\b/i ->
        [_, day, month_abbr] = captures
        month = get_month_number(month_abbr)
        # No year specified - use nil to indicate year is missing
        {String.to_integer(day), month, nil}

      # Month YYYY - No day (German)
      ~r/\b(Januar|Februar|März|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember)\s+(\d{4})\b/i ->
        [_, month_name, year] = captures
        month = get_month_number(month_name)
        # No day specified - use nil to indicate day is missing
        {nil, month, String.to_integer(year)}

      # Mon YYYY - No day (German)
      ~r/\b(Jan|Feb|Mär|Apr|Mai|Jun|Jul|Aug|Sep|Okt|Nov|Dez)\s+(\d{4})\b/i ->
        [_, month_abbr, year] = captures
        month = get_month_number(month_abbr)
        # No day specified - use nil to indicate day is missing
        {nil, month, String.to_integer(year)}

      # Pattern not recognized
      _ ->
        nil
    end
  end

  # Helper to get the current year
  defp current_year do
    DateTime.utc_now().year
  end

  # Helper to convert month name to number
  defp get_month_number(month_name) do
    month_map = %{
      "january" => 1,
      "jan" => 1,
      "february" => 2,
      "feb" => 2,
      "march" => 3,
      "mar" => 3,
      "april" => 4,
      "apr" => 4,
      "may" => 5,
      "june" => 6,
      "jun" => 6,
      "july" => 7,
      "jul" => 7,
      "august" => 8,
      "aug" => 8,
      "september" => 9,
      "sep" => 9,
      "october" => 10,
      "oct" => 10,
      "november" => 11,
      "nov" => 11,
      "december" => 12,
      "dec" => 12,
      # German months
      "januar" => 1,
      "februar" => 2,
      "märz" => 3,
      "mär" => 3,
      "april" => 4,
      "apr" => 4,
      "mai" => 5,
      "juni" => 6,
      "jun" => 6,
      "juli" => 7,
      "jul" => 7,
      "august" => 8,
      "aug" => 8,
      "september" => 9,
      "sep" => 9,
      "oktober" => 10,
      "okt" => 10,
      "november" => 11,
      "nov" => 11,
      "dezember" => 12,
      "dez" => 12
    }

    Map.get(month_map, String.downcase(month_name))
  end

  # Helper to pad numbers with leading zeros if needed
  defp pad_number(number) when number < 10, do: "0#{number}"
  defp pad_number(number), do: "#{number}"

  # Generate all possible date format variations
  defp generate_date_variations(day, month, year) do
    # Get month names
    en_month_name = get_english_month_name(month)
    en_month_abbr = get_english_month_abbr(month)
    de_month_name = get_german_month_name(month)
    de_month_abbr = get_german_month_abbr(month)

    cond do
      # Case 1: Only month is known (no day, no year)
      is_nil(day) and is_nil(year) ->
        [
          # English formats
          en_month_name,
          en_month_abbr,
          # German formats
          de_month_name,
          de_month_abbr
        ]

      # Case 2: Month and year known, but no day
      is_nil(day) ->
        short_year = rem(year, 100)

        [
          # English formats
          "#{en_month_name} #{year}",
          "#{en_month_abbr} #{year}",
          "#{en_month_name} #{short_year}",
          "#{en_month_abbr} #{short_year}",

          # German formats
          "#{de_month_name} #{year}",
          "#{de_month_abbr} #{year}",
          "#{de_month_name} #{short_year}",
          "#{de_month_abbr} #{short_year}"
        ]

      # Case 3: Month and day known, but no year
      is_nil(year) ->
        [
          # English formats
          "#{pad_number(day)} #{en_month_name}",
          "#{day} #{en_month_name}",
          "#{pad_number(day)} #{en_month_abbr}",
          "#{day} #{en_month_abbr}",

          # German formats
          "#{pad_number(day)}. #{de_month_name}",
          "#{day}. #{de_month_name}",
          "#{pad_number(day)}. #{de_month_abbr}",
          "#{day}. #{de_month_abbr}"
        ]

      # Case 4: Complete date with day, month, and year
      true ->
        short_year = rem(year, 100)

        [
          # ISO format
          "#{year}-#{pad_number(month)}-#{pad_number(day)}",

          # Slash formats
          "#{pad_number(day)}/#{pad_number(month)}/#{year}",
          "#{day}/#{month}/#{year}",
          "#{pad_number(day)}/#{pad_number(month)}/#{pad_number(short_year)}",
          "#{day}/#{month}/#{short_year}",

          # German dot formats
          "#{pad_number(day)}.#{pad_number(month)}.#{year}",
          "#{day}.#{month}.#{year}",
          "#{pad_number(day)}.#{pad_number(month)}.#{pad_number(short_year)}",
          "#{day}.#{month}.#{short_year}",

          # English written formats
          "#{pad_number(day)} #{en_month_name} #{year}",
          "#{day} #{en_month_name} #{year}",
          "#{pad_number(day)} #{en_month_abbr} #{year}",
          "#{day} #{en_month_abbr} #{year}",
          "#{pad_number(day)} #{en_month_name} #{short_year}",
          "#{day} #{en_month_name} #{short_year}",
          "#{pad_number(day)} #{en_month_abbr} #{short_year}",
          "#{day} #{en_month_abbr} #{short_year}",

          # German written formats
          "#{pad_number(day)}. #{de_month_name} #{year}",
          "#{day}. #{de_month_name} #{year}",
          "#{pad_number(day)}. #{de_month_abbr} #{year}",
          "#{day}. #{de_month_abbr} #{year}",
          "#{pad_number(day)}. #{de_month_name} #{short_year}",
          "#{day}. #{de_month_name} #{short_year}",
          "#{pad_number(day)}. #{de_month_abbr} #{short_year}",
          "#{day}. #{de_month_abbr} #{short_year}",

          # Also include month-day variations without year
          "#{pad_number(day)}. #{de_month_name}",
          "#{day}. #{de_month_name}",
          "#{pad_number(day)}. #{de_month_abbr}",
          "#{day}. #{de_month_abbr}",
          "#{pad_number(day)} #{en_month_name}",
          "#{day} #{en_month_name}",
          "#{pad_number(day)} #{en_month_abbr}",
          "#{day} #{en_month_abbr}",

          # Also include month-year variations without day
          "#{en_month_name} #{year}",
          "#{en_month_abbr} #{year}",
          "#{de_month_name} #{year}",
          "#{de_month_abbr} #{year}"
        ]
    end
  end

  # Helper functions for month names
  defp get_english_month_name(month) do
    [
      "",
      "January",
      "February",
      "March",
      "April",
      "May",
      "June",
      "July",
      "August",
      "September",
      "October",
      "November",
      "December"
    ]
    |> Enum.at(month)
  end

  defp get_english_month_abbr(month) do
    [
      "",
      "Jan",
      "Feb",
      "Mar",
      "Apr",
      "May",
      "Jun",
      "Jul",
      "Aug",
      "Sep",
      "Oct",
      "Nov",
      "Dec"
    ]
    |> Enum.at(month)
  end

  defp get_german_month_name(month) do
    [
      "",
      "Januar",
      "Februar",
      "März",
      "April",
      "Mai",
      "Juni",
      "Juli",
      "August",
      "September",
      "Oktober",
      "November",
      "Dezember"
    ]
    |> Enum.at(month)
  end

  defp get_german_month_abbr(month) do
    [
      "",
      "Jan",
      "Feb",
      "Mär",
      "Apr",
      "Mai",
      "Jun",
      "Jul",
      "Aug",
      "Sep",
      "Okt",
      "Nov",
      "Dez"
    ]
    |> Enum.at(month)
  end

  # Generate variations by mixing up the order of words in regex patterns
  defp mixup_words_variations(patterns) when is_list(patterns) do
    Enum.flat_map(patterns, fn pattern ->
      # Split the pattern into tokens (words and non-words)
      tokens = tokenize_pattern(pattern)

      # Find all actual words in the pattern
      words = Enum.filter(tokens, fn {type, _} -> type == :word end)

      # Only proceed if we have at least 2 words to permute
      if length(words) >= 2 do
        # Get all permutations of the words
        word_permutations = permutations(Enum.map(words, fn {_, word} -> word end))

        # For each permutation, reconstruct the pattern
        Enum.map(word_permutations, fn permuted_words ->
          reconstruct_pattern(tokens, permuted_words)
        end)
        # Remove the original pattern from results
        |> Enum.filter(fn perm -> perm != pattern end)
      else
        # If fewer than 2 words, return empty list (no permutations)
        []
      end
    end)
  end

  # Split a regex pattern into tokens (words and regex components)
  defp tokenize_pattern(pattern) do
    # Regex to match words, regex placeholders, and other regex components
    parts =
      Regex.scan(~r/\\b|\\s\*|[A-Za-zÄÖÜäöüß]+|\.\{0,\d+\}|./, pattern)
      |> List.flatten()

    # Classify each part as :word or :special
    Enum.map(parts, fn part ->
      cond do
        # Match actual words (sequences of letters)
        Regex.match?(~r/^[A-Za-zÄÖÜäöüß]+$/, part) ->
          {:word, part}

        # Everything else is considered a special regex component
        true ->
          {:special, part}
      end
    end)
  end

  # Reconstruct the pattern by replacing words with their permuted versions
  defp reconstruct_pattern(tokens, permuted_words) do
    # Use reduce to track the word index while rebuilding the pattern
    {result, _} =
      Enum.reduce(tokens, {[], 0}, fn token, {acc, word_index} ->
        case token do
          {:word, _} ->
            # Get the current permuted word and increment index
            word = Enum.at(permuted_words, word_index)
            {[word | acc], word_index + 1}

          {:special, special} ->
            # Keep special tokens unchanged
            {[special | acc], word_index}
        end
      end)

    # Join and reverse the accumulated tokens to get the final pattern
    result
    |> Enum.reverse()
    |> Enum.join("")
  end

  # Generate all possible permutations of a list
  defp permutations([]), do: [[]]

  defp permutations(list) do
    for x <- list, y <- permutations(list -- [x]), do: [x | y]
  end
end
