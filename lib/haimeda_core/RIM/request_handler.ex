defmodule RIM.RequestHandler do
  alias RIM.SymbolicWordProcessor, as: SWP
  alias RIM.{VectorPersistence, ResourceAgent}
  require Logger

  def construct_query_processor_map(input_info) do
    user_request = Map.get(input_info, :user_request)
    table_column_indicators = SWP.extract_table_column_indicators(user_request)

    {query_entities, rest_question_fragments} =
      SWP.extract_query_entities_from_request(user_request)

    report_indicators = SWP.extract_report_indicators(user_request)
    table_indicators = SWP.extract_table_indicators(user_request)
    question_indicators = SWP.extract_question_indicators(user_request)
    amount_indicators = SWP.extract_amount_indicators(user_request)
    party_indicators = SWP.extract_party_indicators(user_request)
    location_indicators = SWP.extract_location_indicators(user_request)

    request_type =
      if report_indicators != [] do
        :report
      else
        :meta_info
      end

    processor_results_map = %{
      report_indicators: report_indicators,
      question_indicators: question_indicators,
      amount_indicators: amount_indicators,
      party_indicators: party_indicators,
      location_indicators: location_indicators,
      query_entities: query_entities,
      table_indicators: table_indicators,
      rest_question_fragments: rest_question_fragments,
      user_request: user_request,
      embedded_user_request: Map.get(input_info, :embedded_user_request),
      request_type: request_type,
      rag_config: Map.get(input_info, :rag_config)
    }

    filtered_request_fragments =
      SWP.filter_fragments(processor_results_map)

    IO.inspect(filtered_request_fragments,
      label: "Filtered Request Fragments"
    )

    direct_value_matches =
      SWP.find_fitting_column_names_for_fragments(filtered_request_fragments)

    IO.inspect(direct_value_matches,
      label: "Direct Value Matches before adding to table_column_indicators"
    )

    table_column_indicators =
      SWP.add_indicators_from_direct_value_matches(
        table_column_indicators,
        direct_value_matches
      )

    processor_results_map =
      Map.put(processor_results_map, :filtered_request_fragments, filtered_request_fragments)

    processor_results_map =
      Map.put(processor_results_map, :direct_value_matches, direct_value_matches)

    processor_results_map =
      Map.put(processor_results_map, :table_column_indicators, table_column_indicators)

    processor_results_map
  end

  def extract_report_data_with_id(report_ids) do
    # Create a list of maps where each map has "Gutachten-Nr" as the key and a report ID as the value
    column_value_maps =
      Enum.map(report_ids, fn report_id ->
        %{"Gutachten-Nr" => report_id}
      end)

    # Call extract_record_data with "Schaden" as the table name and our list of maps
    extract_mdb_record_data("Schaden", column_value_maps)
  end

  def extract_records_with_queries(queries) do
    # IO.inspect(queries, label: "Queries")

    # Create a map of tables to queries that target them
    tables_to_queries =
      Enum.reduce(queries, %{}, fn query, acc ->
        if is_map(query.location) do
          Enum.reduce(Map.keys(query.location), acc, fn table, tables_acc ->
            # Add this query to the list of queries targeting this table
            Map.update(tables_acc, table, [query], fn existing -> [query | existing] end)
          end)
        else
          acc
        end
      end)

    # Process each query in parallel
    query_tasks =
      Enum.map(queries, fn query ->
        Task.async(fn ->
          case query do
            %{value: value, category: category, location: location} when is_map(location) ->
              # Get the operator if it exists
              operator = Map.get(query, :operator)

              # Process each table and its columns
              results =
                Enum.flat_map(location, fn {table, columns} ->
                  # Ensure columns is a list
                  columns_list = if is_list(columns), do: columns, else: [columns]

                  # Call extract_mdb_record for each table-column pair
                  Enum.map(columns_list, fn column ->
                    # Create the table_column parameter
                    table_column = %{table => column}

                    # Call extract_mdb_record with the operator (which may be nil)
                    extract_mdb_record(value, operator, table_column, category)
                  end)
                end)
                |> List.flatten()

              # Return results with the original query to track table relationships
              {query, results}

            _ ->
              # Skip invalid queries
              {query, []}
          end
        end)
      end)

    # Await all parallel tasks
    all_query_results = Task.await_many(query_tasks, 300_000)

    # Create a map to track which tables each query found records for
    records_by_query_and_table = %{}

    # Process results to organize by query and table
    records_by_query_and_table =
      Enum.reduce(all_query_results, %{}, fn {query, results}, acc ->
        # Create an entry for this query
        query_map = Map.get(acc, query, %{})

        # Process each result to extract records by table
        updated_query_map =
          Enum.reduce(results, query_map, fn result_item, query_acc ->
            case result_item do
              map when is_map(map) ->
                Enum.reduce(map, query_acc, fn {table, records}, inner_acc ->
                  # Store the records this query found for this table
                  Map.put(inner_acc, table, records)
                end)

              _ ->
                query_acc
            end
          end)

        # Update the main accumulator with this query's map
        Map.put(acc, query, updated_query_map)
      end)

    # For each table, check if all queries targeting it found records
    # If any query didn't find records, the result for that table should be empty
    # Otherwise, take the intersection of all record sets
    final_results =
      Enum.map(tables_to_queries, fn {table, targeting_queries} ->
        # Check if all queries targeting this table found records
        all_queries_found_records =
          Enum.all?(targeting_queries, fn query ->
            # Get the records this query found for this table
            query_tables = Map.get(records_by_query_and_table, query, %{})
            records = Map.get(query_tables, table, [])

            # Check if records were found
            is_list(records) and records != []
          end)

        if all_queries_found_records do
          # All queries found records, compute the intersection
          record_sets =
            Enum.map(targeting_queries, fn query ->
              query_tables = Map.get(records_by_query_and_table, query, %{})
              Map.get(query_tables, table, [])
            end)

          # Take the intersection
          records =
            case record_sets do
              [first_set | rest_sets] ->
                Enum.reduce(rest_sets, first_set, fn set, acc ->
                  intersect_records(acc, set)
                end)

              [] ->
                []
            end

          {table, records}
        else
          # At least one query didn't find records, result should be empty
          {table, []}
        end
      end)
      |> Map.new()

    # Ensure uniqueness of records in each table
    Map.new(final_results, fn {table, records} ->
      {table, Enum.uniq(records)}
    end)
  end

  # Helper function to find the intersection of two lists of records
  # Records are considered equal if they have the same structure and values
  defp intersect_records(records1, records2) do
    # Convert each record to a string representation for comparison
    # This handles the case where records are complex maps
    record_strings1 = Enum.map(records1, &:erlang.term_to_binary/1)
    record_strings2 = Enum.map(records2, &:erlang.term_to_binary/1)

    # Find common string representations
    common_strings = MapSet.intersection(MapSet.new(record_strings1), MapSet.new(record_strings2))

    # Map back to the original records from the first list
    Enum.filter(records1, fn record ->
      :erlang.term_to_binary(record) in common_strings
    end)
  end

  # Use ResourceAgent to fetch records and apply matching logic
  def extract_mdb_record(value, operator, table_column, category) do
    # Set default operator if nil
    operator = operator || "=="

    # Get the table name and column name from the table_column map
    {table_name, column_name} =
      case Map.to_list(table_column) do
        [{key, value}] -> {key, value}
        # If the column name is already a list, take the first element
        [{key, [value | _]}] -> {key, value}
        _ -> {nil, nil}
      end

    # Return empty map if we couldn't extract valid table/column names
    if is_nil(table_name) or is_nil(column_name) do
      %{}
    else
      # Get comparison instruction (contains or exact)
      comparison_type = SWP.extract_columns_value_from_json(table_column, 2)

      # Normalize the input value
      normalized_value = normalize_query_value(value, category)

      # Get records from ResourceAgent instead of reading the file
      matching_records =
        case ResourceAgent.get_records(table_name) do
          records when is_list(records) ->
            # Filter records based on the column value match
            Enum.filter(records, fn record ->
              # Get the value for this column from the record
              record_value = Map.get(record, column_name)

              if record_value do
                # Normalize the record value
                normalized_record_value = normalize_mdb_value(table_column, record_value)

                # Skip the comparison if both values are nil
                if is_nil(normalized_record_value) or is_nil(normalized_value) do
                  false
                else
                  # Apply comparison based on the type and operator
                  case comparison_type do
                    "contains" ->
                      # For contains, we ignore the operator and just check if the value is contained
                      if is_binary(normalized_record_value) and is_binary(normalized_value) do
                        String.contains?(
                          String.downcase("#{normalized_record_value}"),
                          String.downcase("#{normalized_value}")
                        )
                      else
                        false
                      end

                    "exact" ->
                      # For exact matching, apply the specified operator
                      apply_comparison(
                        normalized_record_value,
                        operator,
                        normalized_value,
                        category
                      )

                    _ ->
                      # Default to false if comparison_type is unknown
                      false
                  end
                end
              else
                # No matching column in this record
                false
              end
            end)

          _ ->
            # Return empty list if records not found
            []
        end

      # Return results as a map with table name as key and records as value
      %{table_name => matching_records}
    end
  end

  # Find records matching given column/value maps via ResourceAgent
  def extract_mdb_record_data(table_name, column_value_maps) do
    # Get records from ResourceAgent instead of reading the file
    case ResourceAgent.get_records(table_name) do
      records when is_list(records) ->
        # For each map in column_value_maps, find matching records
        Enum.flat_map(column_value_maps, fn search_criteria ->
          Enum.filter(records, fn record ->
            # Check if all keys and values in search_criteria match the record
            Enum.all?(search_criteria, fn {column, value} ->
              # Handle case where record might not have this column
              case Map.get(record, column) do
                nil ->
                  false

                record_value ->
                  # Normalize values for comparison (handle string/number differences)
                  SWP.normalize_value(record_value) == SWP.normalize_value(value)
              end
            end)
          end)
        end)
        # Remove any duplicate records
        |> Enum.uniq()

      _ ->
        Logger.error("Error reading #{table_name} data from ResourceAgent")
        []
    end
  end

  # Apply operator comparison based on category
  defp apply_comparison(record_value, operator, input_value, category) do
    case category do
      # Handle both number and quantity as numeric comparisons
      type when type in [:number, :quantity] ->
        # For numbers, convert to numeric values and apply operator directly
        num_record =
          if is_binary(record_value), do: parse_number(record_value), else: record_value

        num_input = if is_binary(input_value), do: parse_number(input_value), else: input_value

        # Apply the numeric comparison
        case operator do
          "<" -> num_record < num_input
          "<=" -> num_record <= num_input
          ">" -> num_record > num_input
          ">=" -> num_record >= num_input
          "==" -> num_record == num_input
          "!=" -> num_record != num_input
          _ -> false
        end

      :date ->
        # For dates, parse the dates and compare them
        compare_dates(record_value, operator, input_value)

      _ ->
        # For other types (strings, etc.), apply basic comparison
        str_record = String.downcase("#{record_value}")
        str_input = String.downcase("#{input_value}")

        case operator do
          "<" -> str_record < str_input
          "<=" -> str_record <= str_input
          ">" -> str_record > str_input
          ">=" -> str_record >= str_input
          "==" -> str_record == str_input
          "!=" -> str_record != str_input
          _ -> false
        end
    end
  end

  # Parse a number from string, handling both integers and floats
  defp parse_number(str) when is_binary(str) do
    case Float.parse(str) do
      {float, _} -> float
      :error -> 0
    end
  end

  defp parse_number(num) when is_number(num), do: num
  defp parse_number(_), do: 0

  # Compare dates in "DD.MM.YYYY" format
  defp compare_dates(date1, operator, date2) do
    # Parse dates to Date structs
    parsed_date1 = parse_date(date1)
    parsed_date2 = parse_date(date2)

    # Apply the comparison operator
    case operator do
      "<" -> Date.compare(parsed_date1, parsed_date2) == :lt
      "<=" -> Date.compare(parsed_date1, parsed_date2) in [:lt, :eq]
      ">" -> Date.compare(parsed_date1, parsed_date2) == :gt
      ">=" -> Date.compare(parsed_date1, parsed_date2) in [:gt, :eq]
      "==" -> Date.compare(parsed_date1, parsed_date2) == :eq
      "!=" -> Date.compare(parsed_date1, parsed_date2) != :eq
      _ -> false
    end
  end

  # Parse a date string in "DD.MM.YYYY" format to a Date struct
  defp parse_date(date_str) when is_binary(date_str) do
    case Regex.run(~r/(\d{2})\.(\d{2})\.(\d{4})/, date_str) do
      [_, day, month, year] ->
        # Convert strings to integers
        day_int = String.to_integer(day)
        month_int = String.to_integer(month)
        year_int = String.to_integer(year)

        # Create a Date struct
        case Date.new(year_int, month_int, day_int) do
          {:ok, date} -> date
          # Return a default date if invalid
          _ -> ~D[1970-01-01]
        end

      # Return a default date if pattern doesn't match
      _ ->
        ~D[1970-01-01]
    end
  end

  # Handle non-string dates by converting to string first
  defp parse_date(date) when not is_binary(date) do
    parse_date("#{date}")
  end

  def extract_matching_vector_records(report_ids, embedded_request, rag_config) do
    mongodb_formatted_report_ids = SWP.format_report_ids_for_mongodb(report_ids)
    IO.inspect(mongodb_formatted_report_ids, label: "MongoDB Formatted Report IDs")

    search_map = %{
      "chapter_type" => "regular_chapter",
      "subcollection" => "single_chapter_vectors",
      "report_id" => mongodb_formatted_report_ids
    }

    results =
      VectorPersistence.extract_similar_vectors_data(
        search_map,
        embedded_request,
        rag_config
      )

    results_without_vectors =
      case results do
        {:ok, result_list} ->
          Enum.map(result_list, fn result ->
            Map.drop(result, ["vector"])
          end)

        _ ->
          []
      end

    # IO.inspect(results_without_vectors, label: "Matching Vector Records")
    results_without_vectors
  end

  def normalize_mdb_value(table_column, extracted_value) do
    type = SWP.extract_columns_value_from_json(table_column, 1)

    case extracted_value do
      "" ->
        nil

      nil ->
        nil

      _ ->
        case type do
          "string" ->
            String.trim(extracted_value)

          "integer" ->
            case extracted_value do
              v when is_integer(v) ->
                v

              v when is_float(v) ->
                trunc(v)

              v when is_binary(v) ->
                v
                |> String.replace(~r/[^\d]/, "")
                |> String.trim()
                |> case do
                  "" -> nil
                  str -> String.to_integer(str)
                end

              _ ->
                nil
            end

          "float_4" ->
            case extracted_value do
              v when is_float(v) ->
                Float.round(v, 2)

              v when is_integer(v) ->
                v * 1.0

              v when is_binary(v) ->
                case String.trim(v) do
                  "" ->
                    nil

                  trimmed ->
                    trimmed
                    |> String.replace(",", ".")
                    |> Float.parse()
                    |> case do
                      {float, _} -> Float.round(float, 2)
                      :error -> nil
                    end
                end

              _ ->
                nil
            end

          "date_single_integer" ->
            case extracted_value do
              v when is_binary(v) ->
                # Remove any non-digit characters
                digits = String.replace(v, ~r/[^\d]/, "")

                # If we have exactly 8 digits (DDMMYYYY format), add the dots
                case String.length(digits) do
                  8 ->
                    day = String.slice(digits, 0, 2)
                    month = String.slice(digits, 2, 2)
                    year = String.slice(digits, 4, 4)
                    "#{day}.#{month}.#{year}"

                  _ ->
                    # Return original value if not in expected format
                    nil
                end

              _ ->
                # Return original value for non-string inputs
                nil
            end

          "date_MDY_time" ->
            case extracted_value do
              v when is_binary(v) ->
                # Try to parse MM/DD/YY HH:MM:SS format
                case Regex.run(~r/(\d{1,2})\/(\d{1,2})\/(\d{1,2})/, v) do
                  [_, month, day, year] ->
                    # Convert to DD.MM.YYYY format
                    # Handle two-digit year (add "20" prefix if less than 50, else "19")
                    full_year =
                      case String.to_integer(year) do
                        y when y < 50 -> "20" <> year
                        _ -> "19" <> year
                      end

                    # Pad day and month with leading zero if needed
                    day_padded = String.pad_leading(day, 2, "0")
                    month_padded = String.pad_leading(month, 2, "0")
                    "#{day_padded}.#{month_padded}.#{full_year}"

                  _ ->
                    # Return original if not matching the expected pattern
                    nil
                end

              _ ->
                # Return original value for non-string inputs
                nil
            end

          "report_single_integer" ->
            SWP.reformat_report_id(extracted_value)

          "integer_spaces" ->
            case extracted_value do
              v when is_binary(v) ->
                v
                |> String.replace(~r/[^\d]/, "")
                |> String.trim()
                |> case do
                  "" -> nil
                  str -> String.to_integer(str)
                end

              v when is_integer(v) ->
                v

              v when is_float(v) ->
                trunc(v)

              _ ->
                nil
            end

          "id_with_spaces" ->
            case extracted_value do
              "" ->
                nil

              v when is_binary(v) ->
                if String.contains?(v, ",") do
                  # If commas exist, preserve them and only remove spaces between other characters
                  result =
                    v
                    |> String.split(",")
                    |> Enum.map(fn part -> String.replace(part, ~r/\s+/, "") end)
                    |> Enum.join(",")
                    |> String.trim()

                  if result == "", do: nil, else: result
                else
                  # If no commas, remove all whitespace
                  result =
                    v
                    |> String.replace(~r/\s+/, "")
                    |> String.trim()

                  if result == "", do: nil, else: result
                end

              _ ->
                extracted_value
            end

          "integer_to_Y/N" ->
            case extracted_value do
              "1" -> "ja"
              1 -> "ja"
              "0" -> "nein"
              0 -> "nein"
              _ -> extracted_value
            end

          _ ->
            # Default case: return the value as is
            extracted_value
        end
    end
  end

  def normalize_query_value(value, category) do
    case value do
      "" ->
        nil

      nil ->
        nil

      _ ->
        case category do
          :quantity ->
            # Convert to float and round to 2 decimal places
            case Float.parse(String.trim(value)) do
              {float_val, _} -> Float.round(float_val, 2)
              # Return original if can't parse
              :error -> value
            end

          :number ->
            # Convert to integer
            case Integer.parse(String.trim(value)) do
              {int_val, _} -> int_val
              # Return original if can't parse
              :error -> value
            end

          :date ->
            # Format date to DD.MM.YYYY
            SWP.normalize_date_value(value)

          :id ->
            String.replace(value, ~r/\s+/, "")

          # Just trim whitespace for these categories
          category when category in [:location, :other, :party] ->
            String.trim(value)

          # Default case - return as is
          _ ->
            value
        end
    end
  end

  def format_record_values(records) do
    Enum.reduce(records, %{}, fn {table, table_records}, acc ->
      # Format records for this table
      formatted_records =
        Enum.map(table_records, fn record ->
          # Process each field in the record
          Enum.reduce(record, %{}, fn {column, value}, record_acc ->
            # Create table_column parameter for extract_columns_value_from_json
            table_column = %{table => column}

            # Format the value using normalize_mdb_value
            formatted_value = normalize_mdb_value(table_column, value)

            # also keep nil values

            Map.put(record_acc, column, formatted_value)
          end)
        end)

      # Add formatted records for this table to accumulator
      Map.put(acc, table, formatted_records)
    end)
  end

  def remove_columns_without_values(records) do
    Enum.reduce(records, %{}, fn {table, table_records}, acc ->
      # Process each record in the table
      filtered_records =
        Enum.map(table_records, fn record ->
          # Remove keys with nil values
          Enum.reduce(record, %{}, fn {key, value}, record_acc ->
            if value != nil do
              Map.put(record_acc, key, value)
            else
              record_acc
            end
          end)
        end)

      # Add filtered records for this table to the result
      Map.put(acc, table, filtered_records)
    end)
  end

  def combine_search_results(hp_records, lp_records) do
    # Find tables that exist in both sets
    hp_tables = Map.keys(hp_records)
    lp_tables = Map.keys(lp_records)

    # Tables in both sets
    common_tables = MapSet.intersection(MapSet.new(hp_tables), MapSet.new(lp_tables))

    # Process common tables - compute intersection of records
    common_results =
      Enum.map(common_tables, fn table ->
        hp_table_records = Map.get(hp_records, table, [])
        lp_table_records = Map.get(lp_records, table, [])

        # Compute intersection of records
        intersection = intersect_records(hp_table_records, lp_table_records)

        # Return table with intersected records
        {table, intersection}
      end)
      |> Map.new()

    # Tables only in high priority records
    hp_only_tables = MapSet.difference(MapSet.new(hp_tables), common_tables)

    hp_only_results =
      Enum.map(hp_only_tables, fn table ->
        {table, Map.get(hp_records, table, [])}
      end)
      |> Map.new()

    # Tables only in low priority records
    lp_only_tables = MapSet.difference(MapSet.new(lp_tables), common_tables)

    lp_only_results =
      Enum.map(lp_only_tables, fn table ->
        {table, Map.get(lp_records, table, [])}
      end)
      |> Map.new()

    # Combine all results
    Map.merge(common_results, Map.merge(hp_only_results, lp_only_results))
  end

  def get_all_report_ids_from_records(records) do
    # Collect report IDs from all tables and records
    report_ids =
      Enum.flat_map(records, fn {_table, table_records} ->
        # For each record in the table, try to extract the report ID
        Enum.map(table_records, fn record ->
          # Check if the record has a "Gutachten-Nr" field with a non-empty value
          case Map.get(record, "Gutachten-Nr") do
            nil -> nil
            "" -> nil
            id -> id
          end
        end)
        # Remove nil values (records without a report ID)
        |> Enum.reject(&is_nil/1)
      end)

    # Remove duplicates and return the list
    Enum.uniq(report_ids)
  end

  def join_records(records, keep_no_joinable_tables \\ false, priority_table \\ nil) do
    # Skip if empty or single table
    if map_size(records) <= 1 do
      records
    else
      # Convert priority_table to a set for easier lookup
      priority_tables =
        case priority_table do
          nil -> MapSet.new()
          table when is_binary(table) -> MapSet.new([table])
          tables when is_list(tables) -> MapSet.new(tables)
          _ -> MapSet.new()
        end

      # 1. Extract column names for each table
      table_columns =
        Enum.reduce(records, %{}, fn {table, table_records}, acc ->
          columns =
            case List.first(table_records) do
              nil -> []
              record -> Map.keys(record)
            end

          Map.put(acc, table, columns)
        end)

      # 2. Find all potential join pairs based on common columns
      join_pairs = find_join_pairs(table_columns)

      # 3. Filter join pairs to those with actual matching records
      valid_join_pairs =
        Enum.filter(join_pairs, fn {table1, table2, common_columns, _join_types} ->
          table1_records = Map.get(records, table1, [])
          table2_records = Map.get(records, table2, [])

          Enum.any?(table1_records, fn record1 ->
            Enum.any?(table2_records, fn record2 ->
              Enum.all?(common_columns, fn column ->
                # Get join type for this column
                join_type = Map.get(_join_types, column, "exact")
                # Compare values based on join type
                record_values_match?(record1, record2, column, join_type)
              end)
            end)
          end)
        end)

      # 4. Build a set of tables that can be joined with any other table
      joinable_tables =
        Enum.reduce(valid_join_pairs, MapSet.new(), fn {table1, table2, _, _}, acc ->
          MapSet.union(acc, MapSet.new([table1, table2]))
        end)

      # 5. Find an optimal join sequence
      # First try starting with priority tables if they exist
      start_tables =
        if MapSet.size(priority_tables) > 0 do
          # Start with priority tables that have records and are joinable
          priority_list = MapSet.to_list(priority_tables)

          # Only use priority tables that have records
          valid_priority_tables =
            Enum.filter(priority_list, fn table ->
              Map.has_key?(records, table) &&
                length(Map.get(records, table, [])) > 0
            end)

          if valid_priority_tables != [] do
            valid_priority_tables
          else
            # Fall back to all tables sorted by record count
            all_tables_by_size(records)
          end
        else
          # No priority tables, sort all tables by number of records (descending)
          all_tables_by_size(records)
        end

      # Try different starting tables and keep the best result
      join_results =
        Enum.map(start_tables, fn start_table ->
          # Try joining with this table as the primary
          try_join_sequence(start_table, records, valid_join_pairs, table_columns)
        end)

      # Find the best join result (one with most tables successfully joined)
      {best_result, best_joined_tables} =
        Enum.max_by(
          join_results,
          fn {_, joined_tables} ->
            MapSet.size(joined_tables)
          end,
          fn -> {%{}, MapSet.new()} end
        )

      # Apply rules for final result based on parameters
      cond do
        # Case 1: Keep all tables regardless of joinability
        keep_no_joinable_tables ->
          # Keep joined tables + all non-joinable tables
          non_joinable_tables = Map.keys(records) -- MapSet.to_list(joinable_tables)

          # Add non-joinable tables to result
          Enum.reduce(non_joinable_tables, best_result, fn table, acc ->
            Map.put(acc, table, Map.get(records, table, []))
          end)

        # Case 2: Only keep joinable tables, no priority tables
        MapSet.size(priority_tables) == 0 ->
          # Just return the best join result
          best_result

        # Case 3: We have priority tables - only include them if they were actually joined
        true ->
          # Check if priority table was successfully joined with other tables
          priority_table_joined =
            Enum.any?(priority_tables, fn table ->
              # Table is joined if it's in the best_joined_tables set
              # And there are at least 2 tables in the result (it was joined with something)
              MapSet.member?(best_joined_tables, table) &&
                map_size(best_result) > 1
            end)

          if priority_table_joined do
            # Priority table already included in best_result
            best_result
          else
            # Priority table couldn't be joined with anything, exclude it
            best_result
          end
      end
    end
  end

  # Helper function to check if record values match based on join type
  defp record_values_match?(record1, record2, column, join_type) do
    value1 = Map.get(record1, column)
    value2 = Map.get(record2, column)

    # Explicitly check if both values are nil - don't allow this case
    if is_nil(value1) && is_nil(value2) do
      false
      # Skip when either value is nil
    else
      if is_nil(value1) || is_nil(value2) do
        false
      else
        # Convert to strings for comparison
        str_value1 = to_string(value1)
        str_value2 = to_string(value2)

        case join_type do
          "exact" ->
            # Exact matching (case-sensitive)
            value1 == value2

          "contains" ->
            # Both values must be non-empty strings
            if str_value1 == "" || str_value2 == "" do
              false
            else
              # Check if shorter string is contained in longer string
              {shorter, longer} =
                if String.length(str_value1) <= String.length(str_value2),
                  do: {str_value1, str_value2},
                  else: {str_value2, str_value1}

              String.contains?(String.downcase(longer), String.downcase(shorter))
            end

          _ ->
            # Default to exact matching for unknown join types
            value1 == value2
        end
      end
    end
  end

  # Find all possible join pairs between tables
  defp find_join_pairs(table_columns) do
    tables = Map.keys(table_columns)

    # Check all table pairs
    for table1 <- tables,
        table2 <- tables,
        table1 != table2 do
      columns1 = Map.get(table_columns, table1, [])
      columns2 = Map.get(table_columns, table2, [])

      # Find common columns
      common_columns =
        MapSet.intersection(
          MapSet.new(columns1),
          MapSet.new(columns2)
        )
        |> MapSet.to_list()

      if common_columns != [] do
        # Create a map of join types for each common column
        join_types =
          Enum.reduce(common_columns, %{}, fn column, acc ->
            # Try to get join type from table1 first, then table2
            join_type =
              case SWP.extract_columns_value_from_json(%{table1 => column}, 3) do
                join_t when join_t in ["exact", "contains"] ->
                  join_t

                _ ->
                  # Try second table
                  case SWP.extract_columns_value_from_json(%{table2 => column}, 3) do
                    join_t when join_t in ["exact", "contains"] -> join_t
                    # Default to exact if not specified
                    _ -> "exact"
                  end
              end

            Map.put(acc, column, join_type)
          end)

        {table1, table2, common_columns, join_types}
      else
        nil
      end
    end
    |> Enum.reject(&is_nil/1)
  end

  # Try a join sequence starting with the given table
  defp try_join_sequence(start_table, records, valid_join_pairs, table_columns) do
    # Skip if start table doesn't exist
    if not Map.has_key?(records, start_table) do
      {%{}, MapSet.new()}
    else
      # Initialize with starting table
      initial_state = %{
        start_table => Map.get(records, start_table, [])
      }

      # Execute the join sequence
      execute_join_sequence(
        records,
        valid_join_pairs,
        initial_state,
        MapSet.new([start_table]),
        table_columns
      )
    end
  end

  # Executes a join sequence starting from the initial state
  defp execute_join_sequence(records, join_pairs, initial_result, already_joined, table_columns) do
    # Recursively join tables in an optimal sequence
    remaining_tables = Map.keys(records) -- MapSet.to_list(already_joined)

    # Base case: no more tables to join
    if remaining_tables == [] do
      {initial_result, already_joined}
    else
      # Find all possible next tables to join (ones that connect to what we've already joined)
      possible_next_joins =
        Enum.filter(join_pairs, fn {t1, t2, _, _} ->
          (MapSet.member?(already_joined, t1) && Enum.member?(remaining_tables, t2)) ||
            (MapSet.member?(already_joined, t2) && Enum.member?(remaining_tables, t1))
        end)

      # If no more joins possible, return current state
      if possible_next_joins == [] do
        {initial_result, already_joined}
      else
        # Try each possible next join and pick the best one
        join_attempts =
          Enum.map(possible_next_joins, fn {table1, table2, common_cols, join_types} ->
            # Determine which table is already joined and which is the new one
            {joined_table, new_table} =
              if MapSet.member?(already_joined, table1),
                do: {table1, table2},
                else: {table2, table1}

            # For each join direction, calculate a score based on matching records quality
            # Try first direction (keep joined_table as primary)
            primary_records = Map.get(initial_result, joined_table, [])
            secondary_records = Map.get(records, new_table, [])

            # Get score for first direction (more preserved records is better)
            {_, forward_score} =
              calculate_join_quality(
                primary_records,
                secondary_records,
                common_cols,
                join_types
              )

            # Try second direction (use new_table as primary)
            primary_records2 = Map.get(records, new_table, [])
            secondary_records2 = Map.get(initial_result, joined_table, [])

            # Get score for second direction
            {_, reverse_score} =
              calculate_join_quality(
                primary_records2,
                secondary_records2,
                common_cols,
                join_types
              )

            # Decide on join direction based on which preserves more matches
            {final_table1, final_table2, join_direction} =
              if forward_score >= reverse_score do
                {joined_table, new_table, :forward}
              else
                {new_table, joined_table, :reverse}
              end

            # Get unique columns for the second table
            unique_columns =
              Map.get(table_columns, final_table2, [])
              |> Enum.reject(&(&1 in common_cols))

            # Try the join in the chosen direction
            join_result =
              if join_direction == :forward do
                # Keep the current joined table as primary
                join_table_onto_primary(
                  initial_result,
                  final_table1,
                  final_table2,
                  common_cols,
                  unique_columns,
                  Map.get(records, final_table2, []),
                  join_types
                )
              else
                # Use the new table as primary - this requires rebuilding the result map
                # First, get all records from the new table
                new_primary_records = Map.get(records, final_table1, [])
                # Map of all tables except the one we're replacing
                tables_to_keep = Map.drop(initial_result, [final_table2])

                # Create a new base map with the new primary table
                new_base = Map.put(%{}, final_table1, new_primary_records)

                # Add back all other tables from the initial result
                new_base = Map.merge(new_base, tables_to_keep)

                # Now join the old primary onto the new primary
                join_table_onto_primary(
                  new_base,
                  final_table1,
                  final_table2,
                  common_cols,
                  unique_columns,
                  Map.get(initial_result, final_table2, []),
                  join_types
                )
              end

            # Check if join was successful by looking at the primary table
            primary_table = if join_direction == :forward, do: final_table1, else: final_table1

            original_records =
              if join_direction == :forward,
                do: Map.get(initial_result, primary_table, []),
                else: Map.get(records, primary_table, [])

            joined_records = Map.get(join_result, primary_table, [])

            # A successful join means we have records and they're different from original
            if joined_records != [] do
              # Get actual match count for quality score
              {match_count, _} =
                calculate_join_quality(
                  original_records,
                  joined_records,
                  Map.keys(List.first(joined_records) || %{}),
                  # No special join types for this quality check
                  %{}
                )

              # Join succeeded, return result with quality score
              {join_result, MapSet.put(already_joined, final_table2), match_count}
            else
              # Join failed
              nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        # If no successful joins, return current state
        if join_attempts == [] do
          {initial_result, already_joined}
        else
          # Pick the best join attempt (the one that preserved most records)
          {best_result, best_joined, _} =
            Enum.max_by(join_attempts, fn {_, _, score} -> score end)

          # Continue with this join
          execute_join_sequence(
            records,
            join_pairs,
            best_result,
            best_joined,
            table_columns
          )
        end
      end
    end
  end

  # Calculate join quality between two sets of records
  defp calculate_join_quality(primary_records, secondary_records, common_columns, join_types) do
    # Count how many records from primary match at least one from secondary
    matches =
      Enum.count(primary_records, fn primary_record ->
        Enum.any?(secondary_records, fn secondary_record ->
          # Check if values match on all common columns
          Enum.all?(common_columns, fn column ->
            # Get join type for this column (default to exact)
            join_type = Map.get(join_types, column, "exact")
            # Use the helper function to check if values match
            record_values_match?(primary_record, secondary_record, column, join_type)
          end)
        end)
      end)

    # Total possible matches is min(primary_count, secondary_count)
    max_possible = min(length(primary_records), length(secondary_records))

    # Calculate a normalized score from 0 to 1
    score =
      if max_possible > 0,
        do: matches / max_possible,
        else: 0

    # Return both raw match count and normalized score
    {matches, score}
  end

  # Join records from secondary_table onto primary_table records, keeping only those that match
  defp join_table_onto_primary(
         current_records,
         primary_table,
         secondary_table,
         common_columns,
         unique_secondary_columns,
         secondary_records,
         join_types
       ) do
    primary_records = Map.get(current_records, primary_table, [])

    # Skip if either table has no records
    if primary_records == [] || secondary_records == [] do
      current_records
    else
      # For each primary record, find matching secondary records and merge them
      joined_records =
        Enum.map(primary_records, fn primary_record ->
          # Find all secondary records that match on common columns
          matching_records =
            Enum.filter(secondary_records, fn secondary_record ->
              # Check if values match on all common columns
              Enum.all?(common_columns, fn column ->
                # Get join type for this column (default to exact)
                join_type = Map.get(join_types, column, "exact")
                # Use the helper function to check if values match
                record_values_match?(primary_record, secondary_record, column, join_type)
              end)
            end)

          # If matches found, merge matching records with the primary record
          if matching_records != [] do
            # For each matching record, merge its unique fields into the primary record
            Enum.reduce(matching_records, primary_record, fn matching_record, acc ->
              # Extract all fields from secondary record
              # Only add fields that don't already exist in primary
              unique_fields =
                Enum.reduce(Map.keys(matching_record), %{}, fn key, fields_acc ->
                  if Map.has_key?(acc, key) do
                    # Field already exists in primary record, skip
                    fields_acc
                  else
                    # Field doesn't exist, add it
                    Map.put(fields_acc, key, Map.get(matching_record, key))
                  end
                end)

              # Merge with primary record
              Map.merge(acc, unique_fields)
            end)
          else
            # No matches found, don't include this record
            nil
          end
        end)
        # Remove records that didn't match
        |> Enum.reject(&is_nil/1)

      # Only update if we have results
      if joined_records != [] do
        # Return updated records map with joined records
        Map.put(current_records, primary_table, joined_records)
      else
        # No successful joins, return original
        current_records
      end
    end
  end

  # Helper function to sort tables by size (number of records)
  defp all_tables_by_size(records) do
    records
    |> Enum.sort_by(fn {table, table_records} ->
      # Calculate a "richness score" for each table based on:
      # 1. Number of records (more is better)
      # 2. Number of columns per record (more is better)
      record_count = length(table_records)

      # Get the average column count
      avg_column_count =
        if record_count > 0 do
          table_records
          |> Enum.map(fn record -> map_size(record) end)
          |> Enum.sum()
          |> Kernel./(record_count)
        else
          0
        end

      # Score that prioritizes both record count and column richness
      # Multiply by -1 to sort in descending order
      -1 * (record_count * avg_column_count)
    end)
    |> Enum.map(fn {table, _} -> table end)
  end
end
