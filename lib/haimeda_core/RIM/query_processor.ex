defmodule RIM.QueryProcessor do
  alias RIM.RequestHandler
  alias RIM.SymbolicWordProcessor, as: SWP

  def process_query(query_processor_map) do
    request_type = Map.get(query_processor_map, :request_type, :unknown)
    report_indicators = Map.get(query_processor_map, :report_indicators, [])
    table_indicators = Map.get(query_processor_map, :table_indicators, [])
    question_indicators = Map.get(query_processor_map, :question_indicators, [])
    amount_indicators = Map.get(query_processor_map, :amount_indicators, [])
    party_indicators = Map.get(query_processor_map, :party_indicators, [])
    location_indicators = Map.get(query_processor_map, :location_indicators, [])
    table_column_indicators = Map.get(query_processor_map, :table_column_indicators, [])
    query_entities = Map.get(query_processor_map, :query_entities, [])
    direct_value_matches = Map.get(query_processor_map, :direct_value_matches, [])
    embedded_user_request = Map.get(query_processor_map, :embedded_user_request, nil)
    rag_config = Map.get(query_processor_map, :rag_config, nil)

    IO.inspect(request_type, label: "Request Type")
    IO.inspect(report_indicators, label: "Report Indicators")
    IO.inspect(table_indicators, label: "Table Indicators")
    IO.inspect(table_column_indicators, label: "Table Column Indicators")
    IO.inspect(question_indicators, label: "Question Indicators")
    IO.inspect(amount_indicators, label: "Amount Indicators")
    IO.inspect(party_indicators, label: "Party Indicators")
    IO.inspect(location_indicators, label: "Location Indicators")
    IO.inspect(query_entities, label: "Query Entities")
    IO.inspect(direct_value_matches, label: "Direct Value Matches")

    {high_priority_table_columns, low_priority_table_columns} =
      compare_table_indicators(table_indicators, table_column_indicators)

    IO.inspect(high_priority_table_columns, label: "High Priority Table Columns")
    IO.inspect(low_priority_table_columns, label: "Low Priority Table Columns")

    {specific_report_ids, query_entities} = check_for_named_report_id(query_entities)
    IO.inspect(specific_report_ids, label: "Specific Report IDs")

    {range_queries, query_entities} = determine_range_queries(query_entities, amount_indicators)

    {id_queries, query_entities} =
      determine_id_queries(query_entities)

    {date_queries, query_entities} =
      determine_date_queries(query_entities)

    {aux_queries, query_entities} =
      determine_auxiliary_queries(query_entities, direct_value_matches)

    IO.inspect(aux_queries, label: "Auxiliary Queries")
    IO.inspect(query_entities, label: "Filtered Query Entities")

    hp_range_queries = reduce_query_locations(high_priority_table_columns, range_queries)
    hp_id_queries = reduce_query_locations(high_priority_table_columns, id_queries)
    hp_date_queries = reduce_query_locations(high_priority_table_columns, date_queries)
    hp_aux_queries = reduce_query_locations(high_priority_table_columns, aux_queries)

    lp_range_queries = reduce_query_locations(low_priority_table_columns, range_queries)
    lp_id_queries = reduce_query_locations(low_priority_table_columns, id_queries)
    lp_date_queries = reduce_query_locations(low_priority_table_columns, date_queries)
    lp_aux_queries = reduce_query_locations(low_priority_table_columns, aux_queries)

    queries = %{
      hp_range: query_available?(hp_range_queries),
      hp_id: query_available?(hp_id_queries),
      hp_date: query_available?(hp_date_queries),
      hp_aux: query_available?(hp_aux_queries),
      lp_range: query_available?(lp_range_queries),
      lp_id: query_available?(lp_id_queries),
      lp_date: query_available?(lp_date_queries),
      lp_aux: query_available?(lp_aux_queries)
    }

    query_processor_map =
      query_processor_map
      |> Map.put(:queries, queries)
      |> Map.put(:specific_report_ids, specific_report_ids)
      |> Map.put(:hp_table_columns, high_priority_table_columns)
      |> Map.put(:lp_table_columns, low_priority_table_columns)

    results =
      case request_type do
        :report ->
          process_report_query(query_processor_map)

        :meta_info ->
          process_meta_info_query(query_processor_map)

        _ ->
          {:error, :unkown_request_type}
      end

    {:ok, results}
  end

  def process_report_query(query_processor_map) do
    embedded_user_request = Map.get(query_processor_map, :embedded_user_request, nil)
    rag_config = Map.get(query_processor_map, :rag_config, nil)
    queries = Map.get(query_processor_map, :queries, %{})
    specific_report_ids = Map.get(query_processor_map, :specific_report_ids, [])
    combine_mdb_and_vector_results = Map.get(rag_config, :combine_mdb_and_vector_results, false)

    hp_table_columns =
      Map.get(query_processor_map, :hp_table_columns, [])

    lp_table_columns =
      Map.get(query_processor_map, :lp_table_columns, [])

    IO.inspect(queries, label: "Queries")

    {report_ids, mdb_records} =
      case specific_report_ids do
        [] ->
          combined_results = query_mdb_table_records_with_priorities(queries)

          {extracted_ids, records} = determine_possible_report_ids(combined_results)

          ids =
            extracted_ids
            |> Enum.map(fn id -> SWP.sanitize_report_id(id) end)
            |> Enum.map(fn id -> SWP.reformat_report_id(id) end)

          {ids, records}

        ids ->
          formatted_ids =
            ids
            |> Enum.map(fn id -> SWP.reformat_report_id(id) end)

          report_queries = create_report_queries(formatted_ids)

          mdb_query_results =
            report_queries
            |> RequestHandler.extract_records_with_queries()
            |> RequestHandler.format_record_values()
            |> RequestHandler.remove_columns_without_values()

          {formatted_ids, mdb_query_results}
      end

    IO.inspect(report_ids, label: "Report IDs")

    max_size = rag_config.max_rag_context_chars + rag_config.max_rag_context_chars * (1 / 3)
    mdb_records_size = determine_record_char_size(mdb_records, :mdb)

    {mdb_table_records, vector_records, feedback} =
      case length(report_ids) do
        n when n > 0 and n < 3 ->
          sanitized_report_ids =
            report_ids
            |> Enum.map(fn id -> SWP.sanitize_report_id(id) end)

          IO.inspect(sanitized_report_ids, label: "Sanitized Report IDs")

          vector_results =
            RequestHandler.extract_matching_vector_records(
              sanitized_report_ids,
              embedded_user_request,
              rag_config
            )

          vector_results_size = determine_record_char_size(vector_results, :vector)
          IO.inspect(vector_results_size, label: "Vector Results Size")
          IO.inspect(max_size, label: "Max possible Size")

          if combine_mdb_and_vector_results do
            combined_results_size = mdb_records_size + vector_results_size

            mdb_records =
              case combined_results_size do
                n when n > max_size ->
                  IO.inspect(combined_results_size, label: "Combined Results Size")

                  decrease_record_sizes(
                    mdb_records,
                    hp_table_columns,
                    lp_table_columns,
                    max_size - vector_results_size
                  )

                _ ->
                  mdb_records
              end

            IO.inspect(determine_record_char_size(mdb_records, :mdb),
              label: "MDB Records Size After Decrease"
            )

            feedback =
              case mdb_records do
                nil -> :vector_results
                _ -> :combined_results
              end

            {mdb_records, vector_results, feedback}
          else
            if vector_results_size > 0 and vector_results_size <= max_size do
              {nil, vector_results, :vector_results}
            else
              if mdb_records_size <= max_size do
                {mdb_records, nil, :mdb_results}
              else
                reduced_mdb_records =
                  decrease_record_sizes(
                    mdb_records,
                    hp_table_columns,
                    lp_table_columns,
                    max_size
                  )

                case reduced_mdb_records do
                  nil -> {nil, nil, :too_many_results}
                  _ -> {reduced_mdb_records, nil, :mdb_results}
                end
              end
            end
          end

        _ ->
          IO.inspect(mdb_records_size, label: "MDB Records Size")

          mdb_records =
            case mdb_records_size do
              n when n > max_size ->
                decrease_record_sizes(
                  mdb_records,
                  hp_table_columns,
                  lp_table_columns,
                  max_size
                )

              _ ->
                mdb_records
            end

          feedback =
            case mdb_records do
              nil -> :too_many_results
              _ -> :mdb_results
            end

          {mdb_records, nil, feedback}
      end

    results = %{
      mdb_results: mdb_records,
      vector_results: vector_records,
      status: feedback
    }
  end

  def process_meta_info_query(query_processor_map) do
    queries = Map.get(query_processor_map, :queries, %{})
    rag_config = Map.get(query_processor_map, :rag_config, nil)

    hp_table_columns =
      Map.get(query_processor_map, :hp_table_columns, [])

    lp_table_columns =
      Map.get(query_processor_map, :lp_table_columns, [])

    hp_tables =
      hp_table_columns
      |> Enum.flat_map(fn table_column ->
        Map.keys(table_column)
      end)
      |> Enum.uniq()

    IO.inspect(hp_tables, label: "High Priority Tables")

    join_config = %{
      keep_no_joinable_tables: true
    }

    combined_results = query_mdb_table_records_with_priorities(queries)
    formatted_record_values = RequestHandler.format_record_values(combined_results)

    IO.inspect(get_total_record_count(combined_results), label: "Combined Results Length")

    IO.inspect(get_total_record_count(formatted_record_values),
      label: "Formatted Record Values Length"
    )

    mdb_records = extract_joined_mdb_records(formatted_record_values, join_config)

    max_size = rag_config.max_rag_context_chars + rag_config.max_rag_context_chars * (1 / 3)
    mdb_records_size = determine_record_char_size(mdb_records, :mdb)

    mdb_records =
      case mdb_records_size do
        n when n > max_size ->
          decrease_record_sizes(
            mdb_records,
            hp_table_columns,
            lp_table_columns,
            max_size
          )

        _ ->
          mdb_records
      end

    feedback =
      case mdb_records do
        nil -> :too_many_results
        _ -> :mdb_results
      end

    IO.inspect(determine_record_char_size(mdb_records, :mdb),
      label: "MDB Records Size After Decrease"
    )

    results = %{
      mdb_results: mdb_records,
      vector_results: nil,
      status: feedback
    }
  end

  def decrease_record_sizes(
        mdb_records,
        hp_table_columns,
        lp_table_columns,
        max_size
      ) do
    IO.inspect(hp_table_columns, label: "High Priority Table Columns")
    IO.inspect(lp_table_columns, label: "Low Priority Table Columns")

    # Extract table names from high priority columns
    hp_tables =
      hp_table_columns
      |> Enum.flat_map(fn table_column ->
        Map.keys(table_column)
      end)
      |> Enum.uniq()

    # Try with high priority tables first
    hp_result =
      if hp_tables != [] do
        # Filter mdb_records to only include high priority tables
        hp_filtered =
          Map.take(mdb_records, hp_tables)

        # Check the size
        hp_size = determine_record_char_size(hp_filtered, :mdb)
        IO.inspect(hp_size, label: "High Priority Filtered Size")

        if hp_size <= max_size do
          # Return the filtered records
          hp_filtered
        else
          # Still too big
          nil
        end
      else
        # No high priority tables
        nil
      end

    if hp_result != nil do
      # High priority filtering worked
      hp_result
    else
      # Check if we have "Schaden" records with Gutachten-Nr
      if Map.has_key?(mdb_records, "Schaden") do
        # Extract only Gutachten-Nr fields from Schaden records
        gutachten_records =
          Map.get(mdb_records, "Schaden")
          |> Enum.map(fn record ->
            case Map.get(record, "Gutachten-Nr") do
              nil -> nil
              gutachten_nr -> %{"Gutachten-Nr" => gutachten_nr}
            end
          end)
          |> Enum.reject(&is_nil/1)

        # If we found any Gutachten-Nr values, return them in the original structure
        if gutachten_records != [] do
          %{"Schaden" => gutachten_records}
        else
          # Fall back to low priority tables if no Gutachten-Nr values found
          try_low_priority_tables(mdb_records, lp_table_columns, max_size)
        end
      else
        # No Schaden records, try low priority tables
        try_low_priority_tables(mdb_records, lp_table_columns, max_size)
      end
    end
  end

  # Helper function to try low priority tables when high priority fails
  defp try_low_priority_tables(mdb_records, lp_table_columns, max_size) do
    # Extract table names from low priority columns
    lp_tables =
      lp_table_columns
      |> Enum.flat_map(fn table_column ->
        Map.keys(table_column)
      end)
      |> Enum.uniq()

    if lp_tables != [] do
      # Filter mdb_records to only include low priority tables
      lp_filtered =
        Map.take(mdb_records, lp_tables)

      # Check the size
      lp_size = determine_record_char_size(lp_filtered, :mdb)
      IO.inspect(lp_size, label: "Low Priority Filtered Size")

      if lp_size <= max_size do
        # Return the filtered records
        lp_filtered
      else
        # Still too big, check if "Schaden" table is present in low priority tables
        if "Schaden" in lp_tables && Map.has_key?(lp_filtered, "Schaden") do
          # Extract only Gutachten-Nr fields from Schaden records
          gutachten_records =
            Map.get(lp_filtered, "Schaden")
            |> Enum.map(fn record ->
              case Map.get(record, "Gutachten-Nr") do
                nil -> nil
                gutachten_nr -> %{"Gutachten-Nr" => gutachten_nr}
              end
            end)
            |> Enum.reject(&is_nil/1)

          # If we found any Gutachten-Nr values, return them in the original structure
          if gutachten_records != [] do
            %{"Schaden" => gutachten_records}
          else
            # No Gutachten-Nr values found, return nil
            nil
          end
        else
          # No Schaden table found in low priority tables
          nil
        end
      end
    else
      # No low priority tables
      nil
    end
  end

  def extract_joined_mdb_records(records, join_config) do
    keep_no_joinable_tables =
      Map.get(join_config, :keep_no_joinable_tables, false)

    priority_tables =
      Map.get(join_config, :priority_tables, nil)

    joined_records =
      RequestHandler.join_records(records, true, nil)

    records_removed_nil_values = RequestHandler.remove_columns_without_values(joined_records)

    IO.inspect(records_removed_nil_values, label: "Joined Records")

    IO.inspect(
      get_total_record_count(records_removed_nil_values),
      label: "Joined Records Length"
    )

    records_removed_nil_values
  end

  def query_mdb_table_records_with_priorities(queries) do
    # Extract high priority queries (keys start with "hp_")
    hp_queries =
      queries
      |> Enum.filter(fn {key, {is_available, _}} ->
        is_atom(key) &&
          to_string(key) =~ ~r/^hp_/ &&
          is_available == true
      end)
      |> Enum.flat_map(fn {_, {_, query_data}} -> query_data end)

    # Extract low priority queries (keys start with "lp_")
    lp_queries =
      queries
      |> Enum.filter(fn {key, {is_available, _}} ->
        is_atom(key) &&
          to_string(key) =~ ~r/^lp_/ &&
          is_available == true
      end)
      |> Enum.flat_map(fn {_, {_, query_data}} -> query_data end)

    IO.inspect(hp_queries, label: "High Priority Queries")
    IO.inspect(lp_queries, label: "Low Priority Queries")

    hp_search_results = RequestHandler.extract_records_with_queries(hp_queries)
    lp_search_results = RequestHandler.extract_records_with_queries(lp_queries)

    total_hp_results = get_total_record_count(hp_search_results)
    total_lp_results = get_total_record_count(lp_search_results)

    IO.inspect(hp_search_results, label: "High Priority Search Results")
    IO.inspect(lp_search_results, label: "Low Priority Search Results")
    IO.inspect(total_hp_results, label: "High Priority Search Results Length")
    IO.inspect(total_lp_results, label: "Low Priority Search Results Length")

    combined_search_results =
      RequestHandler.combine_search_results(hp_search_results, lp_search_results)

    IO.inspect(combined_search_results, label: "Combined Search Results")

    combined_search_results
  end

  def determine_possible_report_ids(search_results) do
    formatted_record_values = RequestHandler.format_record_values(search_results)
    total_formatted_results = get_total_record_count(formatted_record_values)

    IO.inspect(formatted_record_values, label: "Formatted Record Values")

    IO.inspect(
      total_formatted_results,
      label: "Combined Search Results Length"
    )

    joined_records =
      RequestHandler.join_records(formatted_record_values, false, ["Schaden"])

    records_removed_nil_values = RequestHandler.remove_columns_without_values(joined_records)

    IO.inspect(records_removed_nil_values, label: "Joined Records")

    IO.inspect(
      get_total_record_count(records_removed_nil_values),
      label: "Joined Records Length"
    )

    # Extract report IDs from the joined records
    extracted_report_ids =
      RequestHandler.get_all_report_ids_from_records(records_removed_nil_values)

    {extracted_report_ids, records_removed_nil_values}
  end

  def create_report_queries(ids) do
    # Create a list of report queries based on the provided IDs
    Enum.map(ids, fn id ->
      %{
        type: :id_query,
        value: id,
        category: :report_id,
        location: SWP.extract_location_for_type("report_id")
      }
    end)
  end

  def determine_record_char_size(records, type) do
    IO.inspect(type, label: "Type for Size Calculation")
    # IO.inspect(records, label: "Records for Size Calculation")
    size = LLMService.count_words_and_tokens_records(records, type)

    IO.inspect(size, label: "Size")

    # Check if size is a map before trying to access fields
    if is_map(size) do
      IO.inspect(Map.get(size, :estimated_tokens, 0), label: "Estimated Tokens")
      Map.get(size, :char_count, 0)
    else
      IO.inspect(size, label: "Size (not a map)")
      # Return a default value when size is not a map
      0
    end
  end

  def get_total_record_count(search_results) do
    search_results
    |> Map.values()
    |> Enum.flat_map(& &1)
    |> length()
  end

  def compare_table_indicators(table_indicators, table_column_indicators) do
    # Extract table names from table_indicators
    table_names =
      Enum.map(table_indicators, fn indicator ->
        indicator.location
      end)

    # Categorize each table column indicator
    {high_priority, low_priority} =
      Enum.reduce(table_column_indicators, {[], []}, fn indicator, {high, low} ->
        # Get the location map (e.g., %{"Auftraggeber" => "Adresse"})
        location_map = indicator.location

        # Get the table name (the key of the location map)
        table_name = location_map |> Map.keys() |> List.first()

        # Check if this table name is in the high priority list
        if table_name in table_names do
          {[location_map | high], low}
        else
          {high, [location_map | low]}
        end
      end)

    # Return the categorized lists
    {high_priority, low_priority}
  end

  def reduce_query_locations(table_columns, queries) do
    # First, transform table_columns for easier lookup
    table_column_map =
      Enum.reduce(table_columns, %{}, fn map, acc ->
        # Each map has exactly one key-value pair
        {table, column} = Map.to_list(map) |> List.first()
        # Get existing columns for this table or initialize empty list
        columns = Map.get(acc, table, [])
        # Add the new column
        Map.put(acc, table, [column | columns])
      end)

    # Update each query's location
    Enum.map(queries, fn query ->
      if Map.has_key?(query, :location) do
        updated_location =
          Enum.reduce(query.location, %{}, fn {table, columns}, acc ->
            # Only process tables that are in table_column_map
            if Map.has_key?(table_column_map, table) do
              # Get the allowed columns for this table
              allowed_columns = Map.get(table_column_map, table, [])

              # Filter columns to only include those in allowed_columns
              filtered_columns =
                Enum.filter(columns, fn column ->
                  column in allowed_columns
                end)

              # Only include this table if there are any matching columns
              if filtered_columns != [] do
                Map.put(acc, table, filtered_columns)
              else
                acc
              end
            else
              acc
            end
          end)

        # Update the query with the new location
        Map.put(query, :location, updated_location)
      else
        # If the query doesn't have a location field, return it as-is
        query
      end
    end)
    # Filter out queries that have empty location maps
    |> Enum.filter(fn query ->
      !Map.has_key?(query, :location) || map_size(query.location) > 0
    end)
  end

  def query_available?(queries) do
    if queries != [] do
      {true, queries}
    else
      {false, []}
    end
  end

  def determine_auxiliary_queries(query_entities, direct_value_matches) do
    # Filter helper value entities that we can transform to aux queries
    helper_value_entities =
      Enum.filter(query_entities, fn entity ->
        entity.type == :helper_value
      end)

    # Transform helper value entities to aux queries
    helper_aux_queries =
      Enum.map(helper_value_entities, fn entity ->
        # Determine the location type based on category
        location_type =
          case entity.category do
            :id -> "ID"
            :date -> "date"
            :quantity -> "quantity"
            :number -> "number"
            :party -> "party"
            :location -> "location"
            _ -> nil
          end

        # Get location from SWP if we have a valid location type
        location =
          if location_type do
            SWP.extract_location_for_type(location_type)
          else
            %{}
          end

        # Create the aux query map
        %{
          type: :aux_query,
          value: entity.value,
          category: entity.category,
          location: location
        }
      end)

    # Transform direct value matches to aux queries
    direct_aux_queries =
      Enum.map(direct_value_matches, fn match ->
        %{
          type: :aux_query,
          value: match.value,
          category: :other,
          location: match.location
        }
      end)

    # Combine both types of aux queries
    all_aux_queries = helper_aux_queries ++ direct_aux_queries

    # Remove the helper value entities that we've converted to aux queries
    remaining_entities =
      Enum.filter(query_entities, fn entity ->
        entity.type != :helper_value
      end)

    # Return the aux queries and the remaining entities
    {all_aux_queries, remaining_entities}
  end

  def determine_id_queries(query_entities) do
    # Extract entities with category :id and separate by type
    helper_value_entities =
      Enum.filter(query_entities, fn entity ->
        entity.category == :id && entity.type == :helper_value
      end)

    desired_value_entities =
      Enum.filter(query_entities, fn entity ->
        entity.category == :id && entity.type == :desired_value
      end)

    # Get the locations for ID type from the ruleset
    id_locations = SWP.extract_location_for_type("ID")

    # Create id queries by matching desired values with helper values
    id_queries =
      if desired_value_entities != [] && helper_value_entities != [] do
        queries =
          for desired <- desired_value_entities,
              helper <- helper_value_entities do
            %{
              type: :id_query,
              value: helper.value,
              category: :id,
              key: desired.value,
              location: id_locations
            }
          end

        # Only remove entities if we successfully created queries using both types
        used_entities = helper_value_entities ++ desired_value_entities

        remaining_entities =
          Enum.filter(query_entities, fn entity ->
            not Enum.member?(used_entities, entity)
          end)

        {queries, remaining_entities}
      else
        # If we don't have both types, return empty queries and keep all entities
        {[], query_entities}
      end
  end

  def determine_date_queries(query_entities) do
    # Extract entities with category :date and separate by type
    helper_value_entities =
      Enum.filter(query_entities, fn entity ->
        entity.category == :date && entity.type == :helper_value
      end)

    desired_value_entities =
      Enum.filter(query_entities, fn entity ->
        entity.category == :date && entity.type == :desired_value
      end)

    # Get the locations for date type from the ruleset
    date_locations = SWP.extract_location_for_type("date")

    # Create date queries by matching desired values with helper values
    if desired_value_entities != [] && helper_value_entities != [] do
      queries =
        for desired <- desired_value_entities,
            helper <- helper_value_entities do
          %{
            type: :date_query,
            value: helper.value,
            category: :date,
            key: desired.value,
            location: date_locations
          }
        end

      # Only remove entities if we successfully created queries using both types
      used_entities = helper_value_entities ++ desired_value_entities

      remaining_entities =
        Enum.filter(query_entities, fn entity ->
          not Enum.member?(used_entities, entity)
        end)

      {queries, remaining_entities}
    else
      # If we don't have both types, return empty queries and keep all entities
      {[], query_entities}
    end
  end

  def check_for_named_report_id(query_entities) do
    # Find all entities matching our criteria (helper_value, id category, starts with "GA")
    report_id_entities =
      Enum.filter(query_entities, fn entity ->
        entity.type == :helper_value &&
          (entity.category == :id || String.contains?(String.downcase(entity.value), "ga")) &&
          String.starts_with?(entity.value, "GA")
      end)

    # Filter out entities with category :id, type :desired_value, and value "gutachten" (case-insensitive)
    filtered_query_entities =
      Enum.filter(query_entities, fn entity ->
        !(entity.category == :id &&
            entity.type == :desired_value &&
            String.contains?(String.downcase(entity.value), "gutachten"))
      end)

    # If found any, sanitize each ID
    report_ids =
      if length(report_id_entities) > 0 do
        report_id_entities
        |> Enum.map(fn entity -> SWP.sanitize_report_id(entity.value) end)
        # Remove any nil results
        |> Enum.filter(fn id -> id != nil end)
      else
        []
      end

    {report_ids, filtered_query_entities}
  end

  def determine_range_queries(query_entities, amount_indicators) do
    # Extract representations from amount_indicators
    amount_reps =
      amount_indicators
      |> Enum.map(fn %{representation: rep} -> rep end)
      |> Enum.uniq()

    # First check for exact date matches with "==" operator
    {exact_date_entities, remaining_entities, updated_amount_reps} =
      if "==" in amount_reps do
        # Find helper date entities
        date_helper_entities =
          Enum.filter(query_entities, fn entity ->
            entity.type == :helper_value && entity.category == :date
          end)

        # If we have exactly one date entity, create an exact match
        if length(date_helper_entities) == 1 do
          date_entity = List.first(date_helper_entities)

          exact_entity = [
            %{
              type: :range_query,
              operator: "==",
              value: date_entity.value,
              category: :date
            }
          ]

          # Remove the date entity and "==" from further processing
          remaining = Enum.filter(query_entities, fn e -> e != date_entity end)
          updated_reps = Enum.filter(amount_reps, fn rep -> rep != "==" end)

          {exact_entity, remaining, updated_reps}
        else
          {[], query_entities, amount_reps}
        end
      else
        {[], query_entities, amount_reps}
      end

    # Check if we have a range indicator with the updated amount_reps
    has_range =
      "-" in updated_amount_reps ||
        (Enum.any?(updated_amount_reps, fn rep -> rep in [">", ">="] end) &&
           Enum.any?(updated_amount_reps, fn rep -> rep in ["<", "<="] end))

    # Check if we have single-sided inequalities
    has_greater_than = Enum.any?(updated_amount_reps, fn rep -> rep in [">", ">="] end)
    has_less_than = Enum.any?(updated_amount_reps, fn rep -> rep in ["<", "<="] end)

    # Extract helper_value entities for numbers and dates
    number_entities =
      Enum.filter(remaining_entities, fn entity ->
        entity.type == :helper_value && entity.category == :number
      end)

    date_entities =
      Enum.filter(remaining_entities, fn entity ->
        entity.type == :helper_value && entity.category == :date
      end)

    # Look for quantity indicator to determine if we should upgrade number to quantity
    has_quantity =
      Enum.any?(remaining_entities, fn entity ->
        entity.category == :quantity
      end)

    category = if has_quantity, do: :quantity, else: :number

    # Process based on available data for range queries
    range_entities =
      cond do
        # Full range case (both greater than and less than operators)
        length(number_entities) >= 2 && has_range ->
          create_number_range_entities(number_entities, updated_amount_reps, category)

        # Single-sided inequality cases for numbers
        length(number_entities) > 0 && (has_greater_than || has_less_than) ->
          create_single_sided_number_range(number_entities, updated_amount_reps, category)

        # Full range case for dates
        length(date_entities) >= 2 && has_range ->
          create_date_range_entities(date_entities, updated_amount_reps)

        # Single-sided inequality cases for dates (only if no number entities)
        length(date_entities) > 0 && (has_greater_than || has_less_than) ->
          create_single_sided_date_range(date_entities, updated_amount_reps)

        length(amount_reps) == 0 && (length(number_entities) > 0 || length(date_entities) > 0) ->
          # Create exact match entities for all number entities
          number_exactmatch =
            Enum.map(number_entities, fn entity ->
              %{
                type: :range_query,
                operator: "==",
                value: entity.value,
                category: entity.category
              }
            end)

          # Create exact match entities for all date entities
          date_exactmatch =
            Enum.map(date_entities, fn entity ->
              %{type: :range_query, operator: "==", value: entity.value, category: :date}
            end)

          # Combine both lists
          number_exactmatch ++ date_exactmatch

        # Default case: no range entities
        true ->
          []
      end

    # Combine exact date entities with range entities
    all_range_entities = exact_date_entities ++ range_entities

    # Add location information to each range entity
    all_range_entities_with_location =
      Enum.map(all_range_entities, fn entity ->
        location_type =
          case entity.category do
            :number -> "number"
            :quantity -> "quantity"
            :date -> "date"
            _ -> nil
          end

        if location_type do
          Map.put(entity, :location, SWP.extract_location_for_type(location_type))
        else
          entity
        end
      end)

    # Filter out entities that were used in ranges from the original query_entities
    used_values = Enum.map(all_range_entities, fn %{value: value} -> value end)

    # Check if we upgraded from number to quantity
    upgraded_to_quantity =
      category == :quantity &&
        Enum.any?(range_entities, fn entity -> entity.category == :quantity end)

    # Filter out entities:
    # 1. Remove any entity with a value used in range queries
    # 2. If we upgraded to quantity, also remove all quantity entities
    filtered_query_entities =
      Enum.filter(query_entities, fn entity ->
        not_used_in_range = !(entity.value in used_values)
        not_quantity_when_upgraded = !(upgraded_to_quantity && entity.category == :quantity)

        not_used_in_range && not_quantity_when_upgraded
      end)

    {all_range_entities_with_location, filtered_query_entities}
  end

  # Helper function to create number range entities
  defp create_number_range_entities(number_entities, amount_reps, category) do
    # Convert string values to numbers (handles both integers and floats)
    number_values =
      Enum.map(number_entities, fn entity ->
        value = entity.value
        {value, parse_number(value)}
      end)

    # Sort numbers to determine lower and higher values
    sorted_values = Enum.sort_by(number_values, fn {_, num} -> num end)

    # Get appropriate operators
    lower_op = if ">" in amount_reps, do: ">", else: ">="
    upper_op = if "<" in amount_reps, do: "<", else: "<="

    # If we have exactly two numbers, create a simple range
    if length(sorted_values) == 2 do
      [{lower_val_str, _}, {upper_val_str, _}] = sorted_values

      [
        %{type: :range_query, operator: lower_op, value: lower_val_str, category: category},
        %{type: :range_query, operator: upper_op, value: upper_val_str, category: category}
      ]
    else
      # For more than two numbers, create all possible combinations
      combinations =
        for i <- 0..(length(sorted_values) - 2), j <- (i + 1)..(length(sorted_values) - 1) do
          {Enum.at(sorted_values, i), Enum.at(sorted_values, j)}
        end

      # Convert combinations to range entities
      Enum.flat_map(combinations, fn {{lower_val_str, _}, {upper_val_str, _}} ->
        [
          %{type: :range_query, operator: lower_op, value: lower_val_str, category: category},
          %{type: :range_query, operator: upper_op, value: upper_val_str, category: category}
        ]
      end)
    end
  end

  # Helper function to create single-sided number range entities
  defp create_single_sided_number_range(number_entities, amount_reps, category) do
    # Determine the most inclusive operator
    operator =
      cond do
        Enum.member?(amount_reps, ">=") -> ">="
        Enum.member?(amount_reps, ">") -> ">"
        Enum.member?(amount_reps, "<=") -> "<="
        Enum.member?(amount_reps, "<") -> "<"
        true -> nil
      end

    # If we found a valid operator, create range entities for all number entities
    if operator do
      Enum.map(number_entities, fn entity ->
        %{type: :range_query, operator: operator, value: entity.value, category: category}
      end)
    else
      []
    end
  end

  # Helper function to create single-sided date range entities
  defp create_single_sided_date_range(date_entities, amount_reps) do
    # Determine the most inclusive operator
    operator =
      cond do
        Enum.member?(amount_reps, ">=") -> ">="
        Enum.member?(amount_reps, ">") -> ">"
        Enum.member?(amount_reps, "<=") -> "<="
        Enum.member?(amount_reps, "<") -> "<"
        true -> nil
      end

    # If we found a valid operator, create range entities for all date entities
    if operator do
      Enum.map(date_entities, fn entity ->
        %{type: :range_query, operator: operator, value: entity.value, category: :date}
      end)
    else
      []
    end
  end

  # Helper function to parse a number string as either float or integer
  defp parse_number(value) do
    case Float.parse(value) do
      {float_val, ""} ->
        float_val

      {float_val, _rest} ->
        float_val

      :error ->
        # Try as integer as fallback
        case Integer.parse(value) do
          # Convert to float for consistent comparison
          {int_val, _} -> int_val * 1.0
          # Default if parsing fails
          :error -> 0.0
        end
    end
  end

  # Helper function to create date range entities
  defp create_date_range_entities(date_entities, amount_reps) do
    # Sort dates (we'll need to parse them first)
    sorted_dates =
      date_entities
      |> Enum.map(fn entity ->
        {entity.value, parse_date(entity.value)}
      end)
      |> Enum.sort_by(fn {_, date} -> date end)

    # Get appropriate operators
    lower_op = if ">" in amount_reps, do: ">", else: ">="
    upper_op = if "<" in amount_reps, do: "<", else: "<="

    # Create range entities similar to number ranges
    if length(sorted_dates) == 2 do
      [{earlier_date_str, _}, {later_date_str, _}] = sorted_dates

      [
        %{type: :range_query, operator: lower_op, value: earlier_date_str, category: :date},
        %{type: :range_query, operator: upper_op, value: later_date_str, category: :date}
      ]
    else
      # For more than two dates, create all possible combinations
      combinations =
        for i <- 0..(length(sorted_dates) - 2), j <- (i + 1)..(length(sorted_dates) - 1) do
          {Enum.at(sorted_dates, i), Enum.at(sorted_dates, j)}
        end

      # Convert combinations to range entities
      Enum.flat_map(combinations, fn {{earlier_date_str, _}, {later_date_str, _}} ->
        [
          %{type: :range_query, operator: lower_op, value: earlier_date_str, category: :date},
          %{type: :range_query, operator: upper_op, value: later_date_str, category: :date}
        ]
      end)
    end
  end

  # Helper to parse dates from various formats
  defp parse_date(date_str) do
    # Try various date formats and return a Date struct or nil
    # This is a simplified version - in production you'd need more robust parsing
    cond do
      # YYYY-MM-DD
      Regex.match?(~r/^\d{4}-\d{1,2}-\d{1,2}$/, date_str) ->
        [year, month, day] = String.split(date_str, "-") |> Enum.map(&String.to_integer/1)
        Date.new!(year, month, day)

      # DD.MM.YYYY
      Regex.match?(~r/^\d{1,2}\.\d{1,2}\.\d{4}$/, date_str) ->
        [day, month, year] = String.split(date_str, ".") |> Enum.map(&String.to_integer/1)
        Date.new!(year, month, day)

      # Many other formats would need to be handled here

      # Fallback - return a placeholder
      true ->
        # Return the Unix epoch as a fallback
        Date.new!(1970, 1, 1)
    end
  end

  def determine_desired_categories(
        question_indicators,
        query_entities,
        direct_value_matches
      ) do
  end
end
