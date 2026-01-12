defmodule HaimedaCore.Report do
  @moduledoc """
  The Report context provides functions to handle medical device assessment reports.
  """
  require Logger
  alias HaimedaCore.Repo

  @reports_collection "reports"
  @deleted_reports_collection "deleted_reports"

  @doc """
  Returns a list of reports, sorted by creation date (newest first).
  """
  def list_reports do
    try do
      Mongo.find(Repo.get_conn(), @reports_collection, %{})
      |> Enum.to_list()
      |> Enum.map(&process_report_from_db/1)
      |> Enum.sort_by(
        fn report ->
          # Sort by date if present, fallback to MongoDB _id which includes timestamp
          if Map.has_key?(report, "date"), do: report["date"], else: report["id"]
        end,
        {:desc, DateTime}
      )
    rescue
      e ->
        Logger.error("Failed to list reports: #{inspect(e)}")
        []
    end
  end

  @doc """
  Gets a single report by id.
  """
  def get_report(id) do
    try do
      case Mongo.find_one(Repo.get_conn(), @reports_collection, %{_id: BSON.ObjectId.decode!(id)}) do
        nil ->
          {:error, "Report not found"}

        report ->
          {:ok, process_report_from_db(report)}
      end
    rescue
      e ->
        Logger.error("Failed to get report #{id}: #{inspect(e)}")
        {:error, "Could not retrieve report"}
    end
  end

  @doc """
  Creates a new report with the given attributes.
  """
  def create_report(attrs) do
    report_data = %{
      name: attrs.name,
      date: DateTime.utc_now(),
      general: %{
        basic_info: [],
        device_info: []
      },
      parties: [],
      chapters: []
    }

    try do
      case Mongo.insert_one(Repo.get_conn(), @reports_collection, report_data) do
        {:ok, %{inserted_id: id}} ->
          report = Map.put(report_data, :id, BSON.ObjectId.encode!(id))
          report = Map.put(report, "id", BSON.ObjectId.encode!(id))
          {:ok, report}

        {:error, error} ->
          Logger.error("Failed to create report: #{inspect(error)}")
          {:error, "Database error"}
      end
    rescue
      e ->
        Logger.error("Exception while creating report: #{inspect(e)}")
        {:error, "Unexpected error"}
    end
  end

  @doc """
  Updates a report with the given section data.
  """
  def update_report_section(report_id, section, section_id, data) do
    Logger.info("Updating report section #{section}/#{section_id}")

    try do
      mongo_id = BSON.ObjectId.decode!(report_id)

      # Ensure all data has string keys for MongoDB
      update_data = ensure_string_keys(data)

      case section do
        "general" ->
          Mongo.update_one(
            Repo.get_conn(),
            @reports_collection,
            %{_id: mongo_id},
            %{"$set" => %{"general.#{section_id}" => update_data}}
          )

        "chapters" ->
          if section_item_exists?(report_id, section, section_id) do
            update_fields =
              update_data
              |> Enum.map(fn {key, value} ->
                {"#{section}.$[elem].#{key}", value}
              end)
              |> Enum.into(%{})

            Mongo.update_one(
              Repo.get_conn(),
              @reports_collection,
              %{_id: mongo_id},
              %{"$set" => update_fields},
              array_filters: [%{"elem.id" => section_id}]
            )
          else
            Mongo.update_one(
              Repo.get_conn(),
              @reports_collection,
              %{_id: mongo_id},
              %{"$push" => %{section => update_data}}
            )
          end

        "parties" ->
          if section_item_exists?(report_id, section, section_id) do
            Logger.debug("Party exists - updating existing party")

            update_operation = %{
              "$set" =>
                update_data
                |> Enum.map(fn {key, value} ->
                  {"#{section}.$[elem].#{key}", value}
                end)
                |> Enum.into(%{})
            }

            result =
              Mongo.update_one(
                Repo.get_conn(),
                @reports_collection,
                %{_id: mongo_id},
                update_operation,
                array_filters: [%{"elem.id" => section_id}]
              )

            Logger.debug("MongoDB update result: #{inspect(result)}")
            {:ok, "Party updated successfully"}
          else
            Logger.debug("Party does not exist - adding new party")

            result =
              Mongo.update_one(
                Repo.get_conn(),
                @reports_collection,
                %{_id: mongo_id},
                %{"$push" => %{section => update_data}}
              )

            Logger.debug("MongoDB insert result: #{inspect(result)}")
            {:ok, "Party created successfully"}
          end

        _ ->
          Logger.error("Unknown section type: #{section}")
          {:error, "Unknown section type"}
      end

      {:ok, "Report section updated successfully"}
    rescue
      e ->
        Logger.error("Failed to update report section: #{inspect(e)}")
        {:error, "Database error"}
    end
  end

  # Helper function to ensure all keys in a map are strings for MongoDB
  defp ensure_string_keys(data) when is_map(data) do
    Enum.reduce(data, %{}, fn
      {key, value}, acc when is_atom(key) ->
        Map.put(acc, to_string(key), ensure_string_keys(value))

      {key, value}, acc when is_map(value) ->
        Map.put(acc, key, ensure_string_keys(value))

      {key, value}, acc when is_list(value) ->
        Map.put(acc, key, Enum.map(value, &ensure_string_keys/1))

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end

  defp ensure_string_keys(data) when is_list(data) do
    Enum.map(data, &ensure_string_keys/1)
  end

  defp ensure_string_keys(data), do: data

  @doc """
  Deletes a section item from a report.
  """
  def delete_section_item(report_id, section, section_id) do
    try do
      mongo_id = BSON.ObjectId.decode!(report_id)

      # Pull operation for array items
      update_op = %{
        "$pull" => %{
          "#{section}" => %{"id" => section_id}
        }
      }

      case Mongo.update_one(Repo.get_conn(), @reports_collection, %{_id: mongo_id}, update_op) do
        {:ok, %{matched_count: 1}} ->
          {:ok, "Section item deleted"}

        {:ok, %{matched_count: 0}} ->
          {:error, "Report not found"}

        {:error, error} ->
          Logger.error("Failed to delete section item: #{inspect(error)}")
          {:error, "Database error"}
      end
    rescue
      e ->
        Logger.error("Exception while deleting section item: #{inspect(e)}")
        {:error, "Unexpected error"}
    end
  end

  @doc """
  Deletes a section from a report by its ID and category.

  ## Parameters

    * `report_id`: String representation of the report ObjectId
    * `category`: The category of the section to delete (e.g., "chapters", "parties")
    * `section_id`: The ID of the specific section to delete

  ## Returns

    * `{:ok, updated_report}` on success
    * `{:error, reason}` on failure
  """
  def delete_report_section(report_id, category, section_id) do
    try do
      # Let's use the existing delete_section_item function which is already working
      case delete_section_item(report_id, category, section_id) do
        {:ok, _} ->
          # If the deletion was successful, get the updated report
          get_report(report_id)

        error ->
          error
      end
    rescue
      e ->
        Logger.error("Error deleting section: #{inspect(e)}")
        {:error, "Internal error"}
    end
  end

  @doc """
  Saves a report to the database.
  """
  def save_report(report_id, report_data) do
    Logger.info("Saving report #{report_id}")

    try do
      file_path = get_report_file_path(report_id)

      File.mkdir_p!(Path.dirname(file_path))
      File.write!(file_path, Jason.encode!(report_data, pretty: true))

      {:ok, report_data}
    rescue
      e ->
        Logger.error("Failed to save report: #{inspect(e)}")
        {:error, "Failed to save report: #{inspect(e)}"}
    end
  end

  @doc """
  Returns the file path for a report based on its ID.
  """
  def get_report_file_path(report_id) do
    reports_dir = Application.get_env(:haimeda_core, :reports_dir, "reports")
    Path.join([reports_dir, "#{report_id}.json"])
  end

  @doc """
  Soft-deletes a report by moving it to the deleted_reports collection.
  """
  def soft_delete_report(id) do
    try do
      mongo_id = BSON.ObjectId.decode!(id)

      # Use Repo functions for more reliable handling
      case Repo.find_one(@reports_collection, %{_id: mongo_id}) do
        nil ->
          {:error, "Report not found"}

        report_doc ->
          # First, convert BSON document to a regular map suitable for Mongo
          # This will handle DateTime objects and other special types properly
          processed_doc = process_doc_for_transfer(report_doc)

          # Insert to deleted_reports collection
          case Repo.insert_one(@deleted_reports_collection, processed_doc) do
            {:ok, _} ->
              # If successful, delete from original collection
              case Repo.delete_one(@reports_collection, %{_id: mongo_id}) do
                {:ok, _} ->
                  {:ok, "Report moved to deleted_reports collection"}

                {:error, reason} ->
                  Logger.error("Failed to delete report after copying: #{inspect(reason)}")
                  {:error, "Failed to complete deletion"}
              end

            {:error, reason} ->
              Logger.error("Failed to copy report to deleted collection: #{inspect(reason)}")
              {:error, "Failed to move report to deleted collection"}
          end
      end
    rescue
      e ->
        Logger.error("Exception while deleting report: #{inspect(e)}")
        {:error, "Error processing delete request"}
    end
  end

  # Helper function to process document for transfer between collections
  # This handles all special types like DateTime properly
  defp process_doc_for_transfer(doc) do
    doc
    |> Map.delete(:__struct__)
    |> Enum.reduce(%{}, fn
      {k, %DateTime{} = dt}, acc ->
        Map.put(acc, k, dt)

      {k, %BSON.ObjectId{} = oid}, acc ->
        Map.put(acc, k, oid)

      {k, v}, acc when is_atom(k) ->
        Map.put(acc, to_string(k), process_doc_for_transfer(v))

      {k, v}, acc when is_map(v) ->
        Map.put(acc, k, process_doc_for_transfer(v))

      {k, v}, acc when is_list(v) ->
        Map.put(acc, k, Enum.map(v, &process_element_for_transfer/1))

      {k, v}, acc ->
        Map.put(acc, k, v)
    end)
  end

  # Process individual elements in a list
  defp process_element_for_transfer(element) when is_map(element) do
    process_doc_for_transfer(element)
  end

  defp process_element_for_transfer(element) when is_list(element) do
    Enum.map(element, &process_element_for_transfer/1)
  end

  defp process_element_for_transfer(element) do
    element
  end

  @doc """
  Returns reports that have been soft-deleted.
  """
  def list_deleted_reports do
    try do
      Mongo.find(Repo.get_conn(), @deleted_reports_collection, %{})
      |> Enum.to_list()
      |> Enum.map(&process_report_from_db/1)
    rescue
      e ->
        Logger.error("Failed to list deleted reports: #{inspect(e)}")
        []
    end
  end

  @doc """
  Restores a deleted report back to the active reports collection.
  """
  def restore_report(id) do
    try do
      mongo_id = BSON.ObjectId.decode!(id)
      report = Mongo.find_one(Repo.get_conn(), @deleted_reports_collection, %{_id: mongo_id})

      if report do
        {:ok, _} = Mongo.insert_one(Repo.get_conn(), @reports_collection, report)

        {:ok, _} =
          Mongo.delete_one(Repo.get_conn(), @deleted_reports_collection, %{_id: mongo_id})

        {:ok, "Report restored successfully"}
      else
        {:error, "Deleted report not found"}
      end
    rescue
      e ->
        Logger.error("Failed to restore report: #{inspect(e)}")
        {:error, "Failed to restore report"}
    end
  end

  # Convert string ID to MongoDB ObjectID
  defp string_to_object_id(id) when is_binary(id) do
    BSON.ObjectId.decode!(id)
  rescue
    _ ->
      Logger.error("Invalid ObjectId format: #{id}")
      nil
  end

  defp string_to_object_id(id), do: id

  # Determines the MongoDB update field path based on section and item
  defp determine_update_field(section, section_id) do
    case section do
      "general" ->
        "general.#{section_id}"

      "parties" ->
        "parties.$[item]"

      "chapters" ->
        "chapters.$[item]"

      _ ->
        "#{section}.#{section_id}"
    end
  end

  # Checks if a section item exists in a report
  defp section_item_exists?(report_id, section, section_id) do
    try do
      mongo_id = BSON.ObjectId.decode!(report_id)

      query = %{
        "_id" => mongo_id,
        "#{section}" => %{"$elemMatch" => %{"id" => section_id}}
      }

      case Mongo.find_one(Repo.get_conn(), @reports_collection, query) do
        nil -> false
        _ -> true
      end
    rescue
      _ -> false
    end
  end

  # Process report from MongoDB to Elixir structure
  defp process_report_from_db(report) do
    # Convert MongoDB _id to string id
    id =
      case Map.get(report, "_id") do
        %BSON.ObjectId{} = oid -> BSON.ObjectId.encode!(oid)
        id when is_binary(id) -> id
        _ -> nil
      end

    # Create map with string keys and remove MongoDB-specific fields
    processed_report =
      report
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.drop(["_id"])
      |> Map.put("id", id)
      |> maybe_convert_date()

    # Make name consistently accessible
    if Map.has_key?(processed_report, "name") do
      Map.put(processed_report, :name, processed_report["name"])
    else
      processed_report
    end
  end

  # Convert MongoDB DateTime to Elixir DateTime if present
  defp maybe_convert_date(report) do
    case Map.get(report, "date") do
      %DateTime{} = date ->
        report

      date when is_map(date) ->
        # Handle MongoDB date format which might be a map with specific keys
        if Map.has_key?(date, "$date") do
          # MongoDB returns ISO dates in a specific format
          case DateTime.from_iso8601(date["$date"]) do
            {:ok, datetime, _} -> Map.put(report, "date", datetime)
            _ -> report
          end
        else
          report
        end

      _ ->
        report
    end
  end

  @doc """
  Store the current report_id in the process dictionary.
  This is used for context in the editor.
  """
  def set_current_report_id(report_id) do
    Process.put(:current_report_id, report_id)
  end

  @doc """
  Get the current report_id from the process dictionary.
  """
  def get_current_report_id do
    Process.get(:current_report_id)
  end

  @doc """
  Get the current report data based on the current report_id.
  """
  def get_current_report_context do
    case get_current_report_id() do
      nil -> {:error, "No current report set"}
      report_id -> get_report(report_id)
    end
  end
end
