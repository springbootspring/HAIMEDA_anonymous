defmodule RIM.ResponseGenerator do
  def generate_reponse_from_query_results(query_results) do
    if query_results == nil do
      {:error, :no_results}
    else
      # Extract components from query_results
      status = Map.get(query_results, :status)
      mdb_results = Map.get(query_results, :mdb_results)
      vector_results = Map.get(query_results, :vector_results)

      # Calculate counts for mdb_results
      count_mdb_results =
        if is_map(mdb_results) do
          # Sum the length of each list in the map
          Enum.reduce(mdb_results, 0, fn {_table, records}, acc ->
            acc + length(records)
          end)
        else
          0
        end

      # Calculate counts for vector_results
      count_vector_results =
        if is_list(vector_results), do: length(vector_results), else: 0

      case status do
        :mdb_results when is_map(mdb_results) and map_size(mdb_results) > 0 ->
          # Only MDB results are available
          {:ok,
           %{
             status: :mdb_results,
             mdb_results: mdb_results,
             vector_results: nil,
             count_mdb_results: count_mdb_results,
             count_vector_results: 0
           }}

        :vector_results when is_list(vector_results) and length(vector_results) > 0 ->
          # Only vector results are available
          processed_vector = process_vector_results(vector_results)

          {:ok,
           %{
             status: :vector_results,
             mdb_results: nil,
             vector_results: processed_vector,
             count_mdb_results: 0,
             count_vector_results: count_vector_results
           }}

        :combined_results
        when is_map(mdb_results) and map_size(mdb_results) > 0 and
               (is_list(vector_results) and length(vector_results) > 0) ->
          # Both MDB and vector results are available
          processed_vector = process_vector_results(vector_results)

          {:ok,
           %{
             status: :combined_results,
             mdb_results: mdb_results,
             vector_results: processed_vector,
             count_mdb_results: count_mdb_results,
             count_vector_results: count_vector_results
           }}

        :too_many_results ->
          # Too many results, cannot process
          {:error, :too_many_results}

        _ ->
          # Unrecognized status or empty results
          {:error, :no_results}
      end
    end
  end

  def process_vector_results(vector_results) do
    # Group by report_id, handling nil values
    grouped_by_report =
      vector_results
      |> Enum.group_by(fn result -> Map.get(result, "report_id") end)

    # Remove nil key if present (could happen if some entries lack report_id)
    grouped_by_report = Map.delete(grouped_by_report, nil)

    # Order groups by minimum rank (the best/lowest rank in each group)
    ordered_reports =
      grouped_by_report
      |> Enum.map(fn {report_id, entries} ->
        # Find minimum rank in this group, defaulting to 999999 if missing
        min_rank =
          entries
          |> Enum.map(fn entry -> Map.get(entry, "rank", 999_999) end)
          # Default if empty list
          |> Enum.min(fn -> 999_999 end)

        # Sort entries by position, defaulting to 999999 if missing
        sorted_entries =
          Enum.sort_by(entries, fn entry -> Map.get(entry, "position", 999_999) end)

        {report_id, sorted_entries, min_rank}
      end)
      |> Enum.sort_by(fn {_, _, min_rank} -> min_rank end)

    # Create a simplified structure with only required fields
    ordered_results =
      ordered_reports
      |> Enum.map(fn {report_id, sorted_entries, _} ->
        # Map each entry to only include text, position, and chapter_name
        filtered_entries =
          Enum.map(sorted_entries, fn entry ->
            %{
              "text" => Map.get(entry, "text", ""),
              "position" => Map.get(entry, "position"),
              "chapter_name" => Map.get(entry, "chapter_name"),
              "report_id" => Map.get(entry, "report_id"),
              "rank" => Map.get(entry, "rank")
            }
          end)

        # Return simplified map structure per report
        %{
          report_id: report_id,
          content: filtered_entries
        }
      end)

    ordered_results
  end

  def process_mdb_results(mdb_results) do
    # Process each map in the list to remove empty string values
    processed_results =
      Enum.map(mdb_results, fn result_map ->
        # Filter out key-value pairs where the value is an empty string
        Enum.filter(result_map, fn {_key, value} ->
          value != ""
        end)
        # Convert back to a map
        |> Enum.into(%{})
      end)

    processed_results
  end
end
