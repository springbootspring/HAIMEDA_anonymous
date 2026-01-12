defmodule RIM.VectorPersistence do
  require Logger
  alias HaimedaCore.Repo
  alias LLMService
  alias OllamaService

  alias RIM.{VectorMaintenance}

  # Use separate collection for vectors, but keep file_tracking in RAG
  @rag_collection "RAG"
  @vectors_collection "vectors"
  @supported_extensions [".md", ".txt", ".json", ".docx", ".docm"]
  @chunk_size 2000
  @chunk_overlap 200

  @doc """
  Extract vector data based on flexible matching fields

  ## Parameters
  - matching_fields: Map of field name to list of possible values
                    e.g. %{"subcollection" => ["report_vectors", "meta_vectors"],
                          "chapter_type" => ["regular_chapter"],
                          "report_id" => ["report1", "report2"]}

  ## Returns
  - {:ok, documents} with matching vector entries
  - {:ok, []} if no matches found
  """
  def extract_vectors_data(matching_fields) do
    # Build dynamic query from matching_fields
    query = build_query_from_matching_fields(matching_fields)

    # Find all matching documents in the vectors collection
    case Repo.get_conn()
         |> Mongo.find(@vectors_collection, query)
         |> Enum.to_list() do
      [] ->
        # No matching documents found
        {:ok, []}

      documents ->
        # Convert BSON ObjectIds to strings for proper JSON serialization
        formatted_documents =
          Enum.map(documents, fn doc ->
            Map.update(doc, "_id", nil, fn id ->
              BSON.ObjectId.encode!(id)
            end)
          end)

        {:ok, formatted_documents}
    end
  end

  @doc """
  Extract similar vector data based on matching fields and embedded user request,
  limiting results to approximately 20,000 characters of text content.

  ## Parameters
  - matching_fields: Map of field name to list of possible values
  - embedded_user_request: Vector embedding of the user request

  ## Returns
  - {:ok, documents} with similar vector entries, sorted by similarity
  - {:ok, []} if no matches found
  """
  def extract_similar_vectors_data(matching_fields, embedded_user_request, rag_config) do
    # Build dynamic query from matching_fields
    query = build_query_from_matching_fields(matching_fields)
    # Maximum total characters to return
    max_chars = rag_config.max_rag_context_chars || 10_000

    # Retrieve all matching documents
    case Repo.get_conn()
         |> Mongo.find(@vectors_collection, query)
         |> Enum.to_list() do
      [] ->
        # No matching documents found
        {:ok, []}

      documents ->
        # Calculate similarity for each document
        results =
          documents
          |> Enum.map(fn doc ->
            similarity = calculate_similarity(embedded_user_request, Map.get(doc, "vector", []))
            # Add the similarity score to the document
            Map.put(doc, "similarity", similarity)
          end)
          # Sort by similarity in descending order (highest first)
          |> Enum.sort_by(fn doc -> doc["similarity"] end, :desc)
          # Add rank field based on position in sorted list
          |> Enum.with_index(1)
          |> Enum.map(fn {doc, index} ->
            Map.put(doc, "rank", index)
          end)
          # Limit results based on total character count (up to 20,000 chars)
          |> limit_by_character_count(max_chars)
          # Convert BSON ObjectIds to strings for proper JSON serialization
          |> Enum.map(fn doc ->
            Map.update(doc, "_id", nil, fn id ->
              BSON.ObjectId.encode!(id)
            end)
          end)

        {:ok, results}
    end
  end

  @doc """
  Limits a list of documents based on cumulative character count of their text fields.
  Always returns at least one document (if input list is not empty).

  ## Parameters
  - documents: List of documents with "text" field
  - max_chars: Maximum total characters to include

  ## Returns
  - Limited list of documents
  """
  defp limit_by_character_count(documents, max_chars) do
    # Always return at least one document if available
    if Enum.empty?(documents) do
      []
    else
      # Use reduce_while to accumulate documents until we hit the character limit
      {result, _} =
        Enum.reduce_while(documents, {[], 0}, fn doc, {acc, total_chars} ->
          text = Map.get(doc, "text", "")
          text_length = String.length(text)
          new_total = total_chars + text_length

          cond do
            # Always include at least one document even if it exceeds the limit
            Enum.empty?(acc) ->
              {:cont, {[doc | acc], new_total}}

            # Stop when we exceed the maximum character limit
            new_total > max_chars ->
              {:halt, {acc, total_chars}}

            # Otherwise keep accumulating
            true ->
              {:cont, {[doc | acc], new_total}}
          end
        end)

      # Reverse to maintain original sort order (highest similarity first)
      Enum.reverse(result)
    end
  end

  @doc """
  Build a MongoDB query from matching fields map

  ## Parameters
  - matching_fields: Map where keys are field names and values are lists of possible values

  ## Returns
  - MongoDB query map
  """
  defp build_query_from_matching_fields(matching_fields) do
    Enum.reduce(matching_fields, %{}, fn {field, values}, query ->
      case values do
        # Single value
        value when not is_list(value) ->
          Map.put(query, field, value)

        # Empty list - don't add constraint
        [] ->
          query

        # List with single value - use direct equality
        [single_value] ->
          Map.put(query, field, single_value)

        # List with multiple values - use $in operator
        _ ->
          Map.put(query, field, %{"$in" => values})
      end
    end)
  end

  def embed_string(string, rag_config \\ nil) do
    # Generate embedding for the string using the specified model
    embedding_model =
      case rag_config do
        nil ->
          Process.get(:embedding_model, "nomic-embed-text")

        _ ->
          Map.get(rag_config, :embedding_model, "nomic-embed-text")
      end

    LLMService.generate_embeddings(string, embedding_model)
  end

  @doc """
  Verifies if vectors exist for all files in the specified directories.
  Creates new vectors for any missing or updated files.
  """
  def verify_existence_of_vectors(rag_config) do
    only_vector_db = Map.get(rag_config, :only_vector_db, false)
    parent_dir = Map.get(rag_config, :parent_path)
    subcollections = Map.get(rag_config, :vector_subcollections, [])
    enable_tracking = Map.get(rag_config, :enable_tracking_changed_files, false)
    embedding_model = Map.get(rag_config, :embedding_model, "nomic-embed-text")
    chunking_subcollections = Map.get(rag_config, :chunking_subcollections, [])

    # Store chunking_subcollections in process dictionary for access in subfunctions
    Process.put(:chunking_subcollections, chunking_subcollections)

    # check model availability
    case OllamaService.pull_model_if_not_available(embedding_model) do
      {:ok, model_name} ->
        Process.put(:embedding_model, model_name)
        model_name

      {:error, :model_not_avilable} ->
        Logger.error("Model #{embedding_model} is not available.")
        {:error, :embedding_model_not_available}
    end

    case only_vector_db do
      true ->
        # Check if vectors collection exists and is not empty
        conn = Repo.get_conn()
        # Try to find at least one document in the vectors collection
        case Mongo.find(conn, @vectors_collection, %{}) |> Enum.take(1) do
          [] ->
            Logger.error("Vectors collection is empty or does not exist.")
            {:error, :vectors_collection_empty}

          [_doc | _] ->
            Logger.info("Vectors collection exists and is not empty.")
            {:ok, "Vectors collection exists"}
        end

      false ->
        if !File.dir?(parent_dir) do
          Logger.error("Parent directory for RAG files does not exist: #{parent_dir}")
          {:error, :invalid_directory}
        else
          # Check if parent_dir exists in RAG collection
          case check_parent_dir_in_db(parent_dir) do
            {:ok, true} ->
              Logger.info("Parent directory #{parent_dir} already exists in database")

              # Verify subcollections exist
              verify_subcollections(parent_dir, subcollections)

              # If tracking enabled, synchronize with file system
              if enable_tracking do
                VectorMaintenance.synchronize_vector_database(
                  parent_dir,
                  subcollections,
                  embedding_model,
                  chunking_subcollections
                )
              end

              {:ok, "Vector collections verified"}

            {:ok, false} ->
              # Parent directory doesn't exist, create all structures
              Logger.info("Creating new vector collections for #{parent_dir}")

              # Create parent directory entry in RAG collection
              create_parent_dir_entry(parent_dir)

              # Create subcollections
              create_subcollections(parent_dir, subcollections)

              # Process all subfolders and files
              process_parent_dir(parent_dir, subcollections, embedding_model)

              {:ok, "Vector collections created"}

            {:error, reason} ->
              Logger.error("Error checking parent directory in database: #{reason}")
              {:error, reason}
          end
        end
    end
  end

  @doc """
  Checks if the parent directory exists in the RAG collection
  """
  def check_parent_dir_in_db(parent_dir) do
    query = %{"parent_directory" => parent_dir}

    case Repo.find_one(@rag_collection, query) do
      nil -> {:ok, false}
      _entry -> {:ok, true}
    end
  rescue
    e ->
      Logger.error("Database error checking parent directory: #{inspect(e)}")
      {:error, "Database error"}
  end

  @doc """
  Creates an entry for the parent directory in the RAG collection
  with nested subcollection for file_tracking only (vectors go to separate collection)
  """
  def create_parent_dir_entry(parent_dir) do
    entry = %{
      "parent_directory" => parent_dir,
      "created_at" => DateTime.utc_now(),
      "last_updated" => DateTime.utc_now(),
      # Will hold file tracking data
      "file_tracking" => []
    }

    case Repo.insert_one(@rag_collection, entry) do
      {:ok, result} ->
        Logger.info("Created parent directory entry for #{parent_dir}")
        {:ok, BSON.ObjectId.encode!(result.inserted_id)}

      {:error, error} ->
        Logger.error("Failed to create parent directory entry: #{inspect(error)}")
        {:error, "Failed to create parent directory entry"}
    end
  end

  @doc """
  Verifies that all required subcollections exist in the database
  """
  def verify_subcollections(parent_dir, subcollections) do
    # Get existing subcollections for the parent directory
    query = %{"parent_directory" => parent_dir}

    case Repo.find_one(@rag_collection, query) do
      nil ->
        # Should not happen as we already checked, but handle it anyway
        create_parent_dir_entry(parent_dir)
        create_subcollections(parent_dir, subcollections)

      entry ->
        # Check if all required subcollections exist
        existing_subcollections = Map.get(entry, "subcollections", [])

        missing_subcollections =
          subcollections
          |> Enum.filter(fn subcoll_item ->
            {subcoll_name, _} = extract_subcoll_data(subcoll_item)

            !Enum.any?(existing_subcollections, fn existing ->
              existing == subcoll_name || existing["name"] == subcoll_name
            end)
          end)

        unless Enum.empty?(missing_subcollections) do
          Logger.info(
            "Creating missing subcollections: #{inspect(Enum.map(missing_subcollections, fn subcoll_item ->
              {name, _} = extract_subcoll_data(subcoll_item)
              name
            end))}"
          )

          create_subcollections(parent_dir, missing_subcollections)
        end
    end
  end

  @doc """
  Creates subcollection entries for the parent directory
  """
  def create_subcollections(parent_dir, subcollections) do
    # Generate subcollection entries
    subcoll_entries =
      subcollections
      |> Enum.map(fn subcoll_item ->
        # Handle both formats: map or tuple
        {subcoll_name, filename} = extract_subcoll_data(subcoll_item)

        %{
          "name" => subcoll_name,
          "filename_pattern" => filename,
          "created_at" => DateTime.utc_now()
        }
      end)

    # Update the parent directory entry with the subcollections
    query = %{"parent_directory" => parent_dir}

    update = %{
      "$set" => %{"subcollections" => subcoll_entries, "last_updated" => DateTime.utc_now()}
    }

    case Repo.update_one(@rag_collection, query, update) do
      {:ok, %{matched_count: 1}} ->
        Logger.info("Created subcollections for #{parent_dir}")
        {:ok, "Subcollections created"}

      {:ok, %{matched_count: 0}} ->
        # Create parent entry first since it doesn't exist
        create_parent_dir_entry(parent_dir)
        # Try again
        Repo.update_one(@rag_collection, query, update)
        {:ok, "Parent and subcollections created"}

      {:error, error} ->
        Logger.error("Failed to create subcollections: #{inspect(error)}")
        {:error, "Failed to create subcollections"}
    end
  end

  # Helper function to extract subcollection name and filename from different formats
  defp extract_subcoll_data(subcoll_item) when is_map(subcoll_item) do
    # Extract the single key-value pair from the map
    [{subcoll_name, filename}] = Map.to_list(subcoll_item)
    {subcoll_name, filename}
  end

  defp extract_subcoll_data({subcoll_name, filename}) do
    # If it's already a tuple, just return it
    {subcoll_name, filename}
  end

  defp extract_subcoll_data({subcoll_name, filename}) when is_binary(subcoll_name) do
    {subcoll_name, filename}
  end

  @doc """
  Process all subfolders in the parent directory to create vector embeddings
  """
  def process_parent_dir(parent_dir, subcollections, embedding_model) do
    # Get chunking_subcollections from rag_config passed to verify_existence_of_vectors
    chunking_subcollections = Process.get(:chunking_subcollections, [])

    # Get all subfolders in the parent directory (report_ids)
    case File.ls(parent_dir) do
      {:ok, entries} ->
        # Filter to only include directories
        subfolders =
          entries
          |> Enum.filter(fn entry ->
            path = Path.join(parent_dir, entry)
            File.dir?(path)
          end)

        # Process each subfolder
        results =
          subfolders
          |> Enum.map(fn subfolder ->
            process_subfolder(
              parent_dir,
              subfolder,
              subcollections,
              embedding_model,
              chunking_subcollections
            )
          end)

        success_count = Enum.count(results, fn res -> elem(res, 0) == :ok end)
        Logger.info("Processed #{success_count}/#{length(subfolders)} subfolders successfully")

        {:ok, "Parent directory processed"}

      {:error, reason} ->
        Logger.error("Failed to list parent directory contents: #{reason}")
        {:error, "Failed to read parent directory"}
    end
  end

  @doc """
  Process a single subfolder (report_id) to create vector embeddings for its files
  """
  def process_subfolder(
        parent_dir,
        subfolder,
        subcollections,
        embedding_model,
        chunking_subcollections
      ) do
    subfolder_path = Path.join(parent_dir, subfolder)
    Logger.info("Processing subfolder: #{subfolder}")

    # Process each subcollection for this subfolder
    results =
      subcollections
      |> Enum.map(fn subcoll_item ->
        {subcoll_name, filename} = extract_subcoll_data(subcoll_item)

        if is_directory_pattern?(filename) do
          # Handle directory pattern (contains wildcard)
          process_directory_pattern(
            parent_dir,
            subfolder,
            subfolder_path,
            subcoll_name,
            filename,
            embedding_model,
            chunking_subcollections
          )
        else
          # Handle single file (existing behavior)
          process_subcollection_file(
            parent_dir,
            subfolder,
            subfolder_path,
            subcoll_name,
            filename,
            embedding_model,
            chunking_subcollections
          )
        end
      end)

    success = Enum.all?(results, fn res -> elem(res, 0) == :ok end)

    if success do
      {:ok, "Subfolder #{subfolder} processed successfully"}
    else
      failures = Enum.filter(results, fn res -> elem(res, 0) == :error end)
      failure_reasons = Enum.map(failures, fn {:error, reason} -> reason end)
      {:error, "Failed to process subfolder #{subfolder}: #{inspect(failure_reasons)}"}
    end
  end

  @doc """
  Process a directory pattern (like "single_chapters/*.md") to create vectors for multiple files
  """
  def process_directory_pattern(
        parent_dir,
        subfolder,
        subfolder_path,
        subcoll_name,
        pattern,
        embedding_model,
        chunking_subcollections
      ) do
    # Extract directory and file pattern
    {dir_part, file_pattern} = split_directory_pattern(pattern)
    dir_path = Path.join(subfolder_path, dir_part)

    # Check if we should use file-per-chunk strategy for this subcollection
    use_file_per_chunk =
      Enum.any?(chunking_subcollections, fn chunk_config ->
        case chunk_config do
          %{^subcoll_name => ":file_per_chunk"} -> true
          _ -> false
        end
      end)

    if use_file_per_chunk do
      # Use the file-per-chunk strategy
      process_with_subchapter_chunking(
        parent_dir,
        subfolder,
        subcoll_name,
        dir_path,
        file_pattern,
        embedding_model
      )
    else
      if File.dir?(dir_path) do
        # Get all files matching the pattern
        case File.ls(dir_path) do
          {:ok, files} ->
            # Filter files matching the pattern
            matching_files = filter_files_by_pattern(files, file_pattern)

            # Process each matching file
            results =
              matching_files
              |> Enum.map(fn file ->
                file_path = Path.join(dir_path, file)
                chapter_name = extract_chapter_name(file)

                # Read file content to determine chapter type
                case File.read(file_path) do
                  {:ok, content} ->
                    chapter_type = determine_chapter_type(chapter_name, content)

                    if chapter_type == "technical" do
                      IO.inspect(chapter_type, label: "Chapter Type")
                    end

                    # Only process if not heading_only
                    if chapter_type != "heading_only" do
                      # Is this a file that should be chunked?
                      should_chunk =
                        Enum.any?(chunking_subcollections, fn pattern ->
                          pattern_matches_file?(pattern, subcoll_name, file)
                        end)

                      # Process the chapter file
                      process_chapter_file(
                        parent_dir,
                        subfolder,
                        subcoll_name,
                        file_path,
                        content,
                        embedding_model,
                        should_chunk,
                        chapter_name,
                        chapter_type
                      )
                    else
                      Logger.info("Skipping heading-only chapter: #{file_path}")
                      {:ok, "Skipped heading-only chapter"}
                    end

                  {:error, reason} ->
                    Logger.error("Failed to read content from #{file_path}: #{reason}")
                    {:error, "Failed to read file content"}
                end
              end)

            # Check if all files were processed successfully
            if Enum.all?(results, fn res -> elem(res, 0) == :ok end) do
              {:ok, "All chapter files processed successfully"}
            else
              failures = Enum.filter(results, fn res -> elem(res, 0) == :error end)
              failure_reasons = Enum.map(failures, fn {:error, reason} -> reason end)
              {:error, "Failed to process some chapter files: #{inspect(failure_reasons)}"}
            end

          {:error, reason} ->
            Logger.error("Failed to list directory contents of #{dir_path}: #{reason}")
            {:error, "Failed to read directory"}
        end
      else
        Logger.warning("Directory #{dir_path} does not exist")
        {:error, "Directory not found"}
      end
    end
  end

  @doc """
  Process directory patterns that use the :file_per_chunk strategy,
  ensuring proper chapter ordering and sequential position tracking
  """
  def process_with_subchapter_chunking(
        parent_dir,
        report_id,
        subcollection,
        dir_path,
        file_pattern,
        embedding_model
      ) do
    # Check if directory exists
    if File.dir?(dir_path) do
      # Get all files matching the pattern
      case File.ls(dir_path) do
        {:ok, files} ->
          # Filter files matching the pattern
          matching_files = filter_files_by_pattern(files, file_pattern)

          # Determine the proper chapter order
          ordered_chapters = determine_chapter_order(matching_files)

          # First pass: detect heading-only chapters to filter out
          heading_only_chapters =
            Enum.reduce(ordered_chapters, [], fn {_, filename}, acc ->
              file_path = Path.join(dir_path, filename)

              case File.read(file_path) do
                {:ok, content} ->
                  chapter_type = determine_chapter_type(filename, content)

                  if chapter_type == "heading_only" do
                    [filename | acc]
                  else
                    acc
                  end

                _ ->
                  acc
              end
            end)

          # Create a filtered ordered chapters map without heading-only chapters
          filtered_chapters =
            ordered_chapters
            |> Enum.reject(fn {_, filename} -> filename in heading_only_chapters end)
            |> Enum.sort_by(fn {position, _} -> position end)

          # Process each chapter with a sequential position
          results =
            filtered_chapters
            # Assign sequential positions starting from 1
            |> Enum.with_index(1)
            |> Enum.map(fn {{_, filename}, position} ->
              file_path = Path.join(dir_path, filename)
              chapter_name = extract_chapter_name(filename)

              # Read file content
              case File.read(file_path) do
                {:ok, content} ->
                  # Generate embedding for this file
                  vector = LLMService.generate_embeddings(content, embedding_model)
                  chapter_type = determine_chapter_type(filename, content)
                  # Store as a vector entry with sequential position
                  document = %{
                    "parent_directory" => parent_dir,
                    "subcollection" => subcollection,
                    "report_id" => report_id,
                    "chunk_id" => "#{report_id}_chunk_#{position}",
                    "vector" => vector,
                    "text" => content,
                    "chapter_name" => chapter_name,
                    "chapter_type" => chapter_type,
                    "position" => position,
                    "created_at" => DateTime.utc_now()
                  }

                  # Store in vectors collection
                  case Repo.insert_one(@vectors_collection, document) do
                    {:ok, _result} ->
                      # Create file tracking entry for individual file (not just directory)
                      create_file_tracking_entry(parent_dir, file_path, subcollection)

                      Logger.info(
                        "Created chunk #{position} for report #{report_id}, chapter #{chapter_name}"
                      )

                      {:ok, "Vector created for chapter #{chapter_name}"}

                    {:error, error} ->
                      Logger.error(
                        "Failed to store vector for chapter #{chapter_name}: #{inspect(error)}"
                      )

                      {:error, "Database error"}
                  end

                {:error, reason} ->
                  Logger.error("Failed to read content from #{file_path}: #{reason}")
                  {:error, "Failed to read file content"}
              end
            end)

          # Log heading only chapters that were skipped
          if length(heading_only_chapters) > 0 do
            Logger.info("Skipped #{length(heading_only_chapters)} heading-only chapters")
          end

          # Check if all chapters were processed successfully
          if Enum.all?(results, fn res -> match?({:ok, _}, res) end) do
            {:ok, "All chapter files processed successfully"}
          else
            failures = Enum.filter(results, fn res -> match?({:error, _}, res) end)
            failure_reasons = Enum.map(failures, fn {:error, reason} -> reason end)
            {:error, "Failed to process some chapter files: #{inspect(failure_reasons)}"}
          end

        {:error, reason} ->
          Logger.error("Failed to list directory contents of #{dir_path}: #{reason}")
          {:error, "Failed to read directory"}
      end
    else
      Logger.warning("Directory #{dir_path} does not exist")
      {:error, "Directory not found"}
    end
  end

  @doc """
  Process a specific file for a subcollection within a subfolder
  """
  def process_subcollection_file(
        parent_dir,
        subfolder,
        subfolder_path,
        subcoll_name,
        filename,
        embedding_model,
        chunking_subcollections \\ []
      ) do
    file_path = Path.join(subfolder_path, filename)

    if File.exists?(file_path) do
      # Read file content
      case read_file_content(file_path) do
        {:ok, content} ->
          # Check if this subcollection requires chunking
          if subcoll_name in chunking_subcollections do
            process_with_chunking(
              parent_dir,
              subfolder,
              subcoll_name,
              file_path,
              content,
              embedding_model
            )
          else
            process_without_chunking(
              parent_dir,
              subfolder,
              subcoll_name,
              file_path,
              content,
              embedding_model
            )
          end

        {:error, reason} ->
          Logger.error("Failed to read content from #{file_path}: #{reason}")
          {:error, "Failed to read file content"}
      end
    else
      Logger.warning("File #{file_path} does not exist")
      {:error, "File not found"}
    end
  end

  # Process a file that needs chunking
  defp process_with_chunking(
         parent_dir,
         report_id,
         subcollection,
         file_path,
         content,
         embedding_model
       ) do
    # Create chunks from the content
    chunks = create_content_chunks(content)
    Logger.info("Created #{length(chunks)} chunks for #{file_path}")

    # Process each chunk
    results =
      chunks
      |> Enum.with_index(1)
      |> Enum.map(fn {chunk_content, index} ->
        # Generate embedding for this chunk
        vector = LLMService.generate_embeddings(chunk_content, embedding_model)

        # Store the chunk in separate vectors collection
        document = %{
          "parent_directory" => parent_dir,
          "subcollection" => subcollection,
          "report_id" => report_id,
          "chunk_id" => "#{report_id}_chunk#{index}",
          "vector" => vector,
          "text" => chunk_content,
          "position" => index,
          "created_at" => DateTime.utc_now()
        }

        Repo.insert_one(@vectors_collection, document)
      end)

    # Create file tracking entry
    create_file_tracking_entry(parent_dir, file_path, subcollection)

    # Check if all chunks were created successfully
    if Enum.all?(results, fn res -> match?({:ok, _}, res) end) do
      {:ok, "Created #{length(chunks)} chunks for #{file_path}"}
    else
      {:error, "Failed to create some chunks"}
    end
  end

  # Process a file without chunking
  defp process_without_chunking(
         parent_dir,
         report_id,
         subcollection,
         file_path,
         content,
         embedding_model
       ) do
    # Generate vector embedding for the entire content
    vector = LLMService.generate_embeddings(content, embedding_model)

    # Create a single vector entry
    document =
      if String.contains?(subcollection, "meta") do
        # For meta_vectors (assuming content is parseable as JSON)
        metadata =
          case Jason.decode(content) do
            {:ok, parsed} -> parsed
            _ -> %{"raw_content" => content}
          end

        %{
          "parent_directory" => parent_dir,
          "subcollection" => subcollection,
          "report_id" => report_id,
          "vector" => vector,
          "metadata" => metadata,
          "text" => content,
          "created_at" => DateTime.utc_now()
        }
      else
        # For any other non-chunked vector (including report_vectors)
        %{
          "parent_directory" => parent_dir,
          "subcollection" => subcollection,
          "report_id" => report_id,
          "vector" => vector,
          "text" => content,
          "created_at" => DateTime.utc_now()
        }
      end

    # Store in vectors collection
    case Repo.insert_one(@vectors_collection, document) do
      {:ok, result} ->
        # Create file tracking entry
        create_file_tracking_entry(parent_dir, file_path, subcollection)
        {:ok, "Vector created for #{file_path}"}

      {:error, error} ->
        Logger.error("Failed to store vector: #{inspect(error)}")
        {:error, "Database error"}
    end
  end

  @doc """
  Create content chunks from text based on chunk size and overlap settings,
  preserving sentence boundaries.
  """
  def create_content_chunks(content) do
    content_length = String.length(content)

    # Handle empty or short content
    if content_length <= @chunk_size do
      [content]
    else
      # Start with an empty list of chunks and first position
      {chunks, _} =
        create_chunks_recursively(content, content_length, [], 0)

      # If chunks were created successfully, return them in order
      chunks
    end
  end

  # Recursive helper to create chunks while preserving sentence boundaries
  defp create_chunks_recursively(content, content_length, chunks, start_pos) do
    # If we've processed the entire content or are very close to the end, we're done
    if start_pos >= content_length - 10 do
      {Enum.reverse(chunks), start_pos}
    else
      # Find a good endpoint (after a sentence) for this chunk
      end_pos = find_sentence_boundary_end(content, start_pos, @chunk_size)

      # Extract the chunk text
      chunk = String.slice(content, start_pos, end_pos - start_pos)

      # Calculate where the next chunk should start (respecting sentence boundaries)
      next_start_pos = find_next_chunk_start(content, end_pos, @chunk_overlap)

      # Check if remaining text would create a very small final chunk
      remaining_length = content_length - next_start_pos

      if remaining_length > 0 && remaining_length < @chunk_overlap do
        # If the remaining text is shorter than the overlap,
        # include it in the current chunk instead of creating a new one
        final_chunk = String.slice(content, start_pos, content_length - start_pos)
        {[final_chunk | chunks], content_length}
      else
        # Continue creating chunks
        create_chunks_recursively(
          content,
          content_length,
          [chunk | chunks],
          next_start_pos
        )
      end
    end
  end

  # Find a sentence boundary (ending with ".") near the target end position
  defp find_sentence_boundary_end(content, start_pos, max_length) do
    # Calculate the maximum possible endpoint
    max_end = min(start_pos + max_length, String.length(content))

    # Get the potential chunk text
    potential_chunk = String.slice(content, start_pos, max_length)

    # Find the last period in this potential chunk using custom implementation
    case find_last_index_of(potential_chunk, ".") do
      nil ->
        # If no period found, just use the maximum length
        max_end

      last_dot_index ->
        # Found a period - use it as the end point (add 1 to include the period)
        start_pos + last_dot_index + 1
    end
  end

  # Custom implementation to find the last index of a substring
  defp find_last_index_of(string, substring) do
    reversed_string = String.reverse(string)
    reversed_substring = String.reverse(substring)

    case :binary.match(reversed_string, reversed_substring) do
      {position, _} -> String.length(string) - position - String.length(substring)
      :nomatch -> nil
    end
  end

  @doc """
  Create a vector entry in the separate vectors collection
  """
  def create_vector_entry(
        parent_dir,
        report_id,
        subcollection,
        file_path,
        file_hash,
        content,
        vector,
        chapter_type \\ nil
      ) do
    # Structure depends on subcollection type
    vector_doc =
      if String.contains?(subcollection, "meta") do
        # For meta_vectors
        %{
          "parent_directory" => parent_dir,
          "subcollection" => subcollection,
          "report_id" => report_id,
          "vector" => vector,
          "metadata" =>
            case Jason.decode(content) do
              {:ok, parsed} -> parsed
              _ -> %{"raw_content" => content}
            end,
          "text" => content,
          "content_hash" => file_hash,
          "created_at" => DateTime.utc_now()
        }
      else
        # For any other non-chunked vector (including report_vectors)
        %{
          "parent_directory" => parent_dir,
          "subcollection" => subcollection,
          "report_id" => report_id,
          "vector" => vector,
          "text" => content,
          "content_hash" => file_hash,
          "created_at" => DateTime.utc_now()
        }
      end

    # Insert into separate vectors collection
    case Repo.insert_one(@vectors_collection, vector_doc) do
      {:ok, %{inserted_id: id}} ->
        {:ok, BSON.ObjectId.encode!(id)}

      {:error, error} ->
        Logger.error("Failed to store vector: #{inspect(error)}")
        {:error, "Database error"}
    end
  end

  @doc """
  Create a file tracking entry as a subdocument in the RAG collection
  """
  def create_file_tracking_entry(parent_dir, file_path, subcollection) do
    # Extract report_id from the file path
    # For files in special directories like "single_chapters", we need to get the parent of the parent directory
    report_id =
      if String.contains?(file_path, "single_chapters") do
        # Extract the parent of the "single_chapters" directory (the actual report ID)
        parts = Path.split(file_path)
        idx = Enum.find_index(parts, &(&1 == "single_chapters"))

        if idx && idx > 0 do
          Enum.at(parts, idx - 1)
        else
          Path.dirname(file_path) |> Path.basename()
        end
      else
        # Regular case - use parent directory name
        Path.dirname(file_path) |> Path.basename()
      end

    # Get file stats
    case File.stat(file_path, time: :posix) do
      {:ok, %{mtime: mtime, size: size}} ->
        entry = %{
          "file_path" => file_path,
          "last_modified" => mtime * 1000,
          "file_size" => size,
          "last_embedding_generated" => DateTime.utc_now() |> DateTime.to_unix(:millisecond),
          "subcollection" => subcollection,
          # Add report_id to tracking info
          "report_id" => report_id
        }

        # Check if entry already exists
        query = %{
          "parent_directory" => parent_dir,
          "file_tracking" => %{
            "$elemMatch" => %{"file_path" => file_path}
          }
        }

        case Repo.find_one(@rag_collection, query) do
          nil ->
            # Create new entry
            Repo.update_one(
              @rag_collection,
              %{"parent_directory" => parent_dir},
              %{"$push" => %{"file_tracking" => entry}}
            )

          _ ->
            # Update existing entry
            Repo.update_one(
              @rag_collection,
              %{
                "parent_directory" => parent_dir,
                "file_tracking.file_path" => file_path
              },
              %{"$set" => %{"file_tracking.$" => entry}}
            )
        end

        # Verify that vectors exist for this file - use the correct report_id
        verify_vectors_exist(parent_dir, report_id, subcollection)

        {:ok, "File tracking entry created/updated"}

      {:error, reason} ->
        Logger.error("Failed to get file stats for #{file_path}: #{reason}")
        {:error, "Failed to get file stats"}
    end
  end

  @doc """
  Verify that vectors exist in the vectors collection for a specific report_id and subcollection
  """
  def verify_vectors_exist(parent_dir, report_id, subcollection) do
    # Handle directory pattern subcollections (those containing wildcard patterns)
    # by only checking for the subcollection name
    query = %{
      "parent_directory" => parent_dir,
      "report_id" => report_id,
      "subcollection" => subcollection
    }

    # Check if any vectors exist for this report_id and subcollection
    case Repo.find_one(@vectors_collection, query) do
      nil ->
        Logger.warning(
          "No vectors found for report_id #{report_id} in subcollection #{subcollection}"
        )

        {:error, :no_vectors_found}

      _ ->
        # Vectors exist
        {:ok, :vectors_exist}
    end
  end

  @doc """
  Calculate a hash of a file's content
  """
  def calculate_file_hash(file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

      {:error, reason} ->
        Logger.error("Failed to read file #{file_path}: #{reason}")
        nil
    end
  end

  @doc """
  Read and clean content from a file based on its type
  """
  def read_file_content(file_path) do
    extension = String.downcase(Path.extname(file_path))

    case extension do
      ".md" -> read_markdown_file(file_path)
      ".txt" -> read_text_file(file_path)
      ".json" -> read_json_file(file_path)
      ".docx" -> read_docx_file(file_path)
      ".docm" -> read_docx_file(file_path)
      _ -> {:error, "Unsupported file type: #{extension}"}
    end
  end

  # Helper functions to read different file types
  defp read_text_file(file_path) do
    File.read(file_path)
  end

  defp read_markdown_file(file_path) do
    # For markdown, we just read the raw content for now
    File.read(file_path)
  end

  defp read_json_file(file_path) do
    with {:ok, content} <- File.read(file_path),
         {:ok, json} <- Jason.decode(content) do
      # Normalize JSON content by removing quotes, braces, and replacing newlines
      normalized_content = normalize_json_content(json)
      {:ok, normalized_content}
    else
      {:error, reason} -> {:error, "JSON parsing error: #{inspect(reason)}"}
    end
  end

  @doc """
  Normalize JSON content by converting it to plain text format
  """
  def normalize_json_content(json) when is_map(json) do
    json
    |> Enum.map(fn {key, value} ->
      "#{key}: #{normalize_json_value(value)}"
    end)
    |> Enum.join("\n")
  end

  defp normalize_json_value(value) when is_binary(value) do
    # Replace newlines with spaces in string values
    String.replace(value, "\n", " ")
  end

  defp normalize_json_value(value) when is_map(value) do
    # Handle nested maps
    normalize_json_content(value)
  end

  defp normalize_json_value(value) when is_list(value) do
    # Handle lists by joining elements with commas
    value
    |> Enum.map(&normalize_json_value/1)
    |> Enum.join(", ")
  end

  defp normalize_json_value(value) do
    # Convert any other value to string
    to_string(value)
  end

  defp read_docx_file(file_path) do
    # DOCX extraction not implemented
    {:error, "DOCX file support not implemented yet"}
  end

  @doc """
  Retrieve vectors for a query using similarity search from the separate vectors collection
  """
  def retrieve_vectors(rag_config, query, subcollection \\ nil, limit \\ 5) do
    # Generate embedding for the query
    query_vector = LLMService.generate_embeddings(query, rag_config.embedding_model)

    # Construct MongoDB query for vectors collection
    base_query = %{"parent_directory" => rag_config.parent_path}

    # Add subcollection filter if specified
    query_with_subcollection =
      if subcollection do
        Map.put(base_query, "subcollection", subcollection)
      else
        base_query
      end

    # Retrieve documents and calculate similarities
    documents =
      Mongo.find(Repo.get_conn(), @vectors_collection, query_with_subcollection)
      |> Enum.to_list()
      |> Enum.map(fn doc ->
        similarity = calculate_similarity(query_vector, Map.get(doc, "vector", []))
        Map.put(doc, "similarity", similarity)
      end)
      |> Enum.sort_by(fn doc -> doc["similarity"] end, :desc)
      |> Enum.take(limit)

    {:ok, documents}
  end

  # Calculate cosine similarity between two vectors
  defp calculate_similarity(vec1, vec2) when length(vec1) == length(vec2) do
    # Cosine similarity implementation
    dot_product = Enum.zip(vec1, vec2) |> Enum.map(fn {a, b} -> a * b end) |> Enum.sum()

    magnitude1 = :math.sqrt(Enum.sum(Enum.map(vec1, fn x -> x * x end)))
    magnitude2 = :math.sqrt(Enum.sum(Enum.map(vec2, fn x -> x * x end)))

    if magnitude1 > 0 and magnitude2 > 0 do
      dot_product / (magnitude1 * magnitude2)
    else
      0.0
    end
  end

  # Handle vector length mismatch
  defp calculate_similarity(_, _), do: 0.0

  @doc """
  Determines the type of chapter based on its content.
  Returns "heading_only" if the content is very short, otherwise "regular_chapter".
  """
  def determine_chapter_type(chapter_name, chapter_content) do
    token_length = estimate_token_length(chapter_content)

    # If content is very short (less than 20 tokens), it's likely just a heading

    if token_length < 20 do
      "heading_only"
    else
      determine_title_type(chapter_name)
    end
  end

  @doc """
  Estimates the token length of content based on character count.
  Uses a rough approximation of 3.5 characters per token.
  """
  def estimate_token_length(content) do
    char_count = String.length(content)
    trunc(Float.ceil(char_count / 3.5, 1))
  end

  @doc """
  Extracts chapter name from a filename (removing the .md extension)
  """
  def extract_chapter_name(filename) do
    filename
    |> Path.basename(".md")
  end

  @doc """
  Checks if a filename pattern is a directory pattern (contains wildcard)
  """
  def is_directory_pattern?(filename) do
    String.contains?(filename, "*")
  end

  def determine_title_type(title) do
    case IIV.classify_filename(title) do
      "Technische_Daten" -> "technical"
      _ -> "regular_chapter"
    end
  rescue
    e ->
      Logger.error("Error determining chapter type: #{inspect(e)}")
      # Default type in case of errors
      "regular_chapter"
  end

  @doc """
  Split a directory pattern into directory part and file pattern
  Example: "single_chapters/*.md" -> {"single_chapters", "*.md"}
  """
  def split_directory_pattern(pattern) do
    parts = String.split(pattern, "/")
    file_pattern = List.last(parts)

    # Fix for negative steps issue - use proper range syntax
    dir_part =
      if length(parts) > 1 do
        parts
        |> Enum.slice(0..(length(parts) - 2))
        |> Enum.join("/")
      else
        ""
      end

    {dir_part, file_pattern}
  end

  @doc """
  Filter files based on a pattern (e.g., "*.md")
  """
  def filter_files_by_pattern(files, pattern) do
    # Convert the glob pattern to a regex
    regex = pattern_to_regex(pattern)

    # Filter files matching the regex
    Enum.filter(files, fn file ->
      Regex.match?(regex, file)
    end)
  end

  @doc """
  Convert a glob pattern to a regex
  """
  def pattern_to_regex(pattern) do
    # Replace * with regex .*
    regex_str =
      pattern
      |> String.replace(".", "\\.")
      |> String.replace("*", ".*")

    # Compile the regex
    ~r/^#{regex_str}$/
  end

  @doc """
  Check if a file matches a pattern from chunking_subcollections
  """
  def pattern_matches_file?(pattern, subcollection, filename) do
    cond do
      # Match for exact subcollection name
      pattern == subcollection ->
        true

      # Match for map with subcollection as key (new format)
      is_map(pattern) && Map.has_key?(pattern, subcollection) ->
        true

      # Match for old string format with wildcards
      is_binary(pattern) && String.contains?(pattern, "/*") ->
        [subcoll_part, file_pattern] = String.split(pattern, "/*", parts: 2)
        subcoll_part == subcollection && String.ends_with?(filename, file_pattern)

      true ->
        false
    end
  end

  # Fixed find_next_chunk_start to handle multiple regex matches
  defp find_next_chunk_start(content, end_pos, overlap) do
    # Start at overlap position
    ideal_start = max(0, end_pos - overlap)

    # Look much further ahead for long technical sentences (4x overlap)
    content_after_ideal = String.slice(content, ideal_start, overlap * 4)

    case Regex.run(~r/\.\s+([A-Z])/, content_after_ideal, return: :index) do
      [{match_start, _}] ->
        # Found a sentence boundary - start after the period and space
        ideal_start + match_start + 2

      nil ->
        # No sentence boundary found within extended window
        # Look for other logical breaks like semicolons or bullet points
        alternative_breaks =
          [
            Regex.run(~r/;\s+/, content_after_ideal, return: :index),
            Regex.run(~r/:\s+/, content_after_ideal, return: :index),
            Regex.run(~r/\n\s*[-•]\s+/, content_after_ideal, return: :index)
          ]
          |> Enum.reject(&is_nil/1)
          # Fix for CaseClauseError - handle potential list of position tuples
          |> Enum.map(fn
            [{pos, _}] ->
              pos

            matches when is_list(matches) ->
              {pos, _} = List.first(matches)
              pos
          end)

        if Enum.empty?(alternative_breaks) do
          # If absolutely no break found, use ideal_start
          ideal_start
        else
          # Use the earliest alternative break
          ideal_start + Enum.min(alternative_breaks) + 1
        end
    end
  end

  @doc """
  Process a single chapter file for vector creation
  """
  def process_chapter_file(
        parent_dir,
        report_id,
        subcollection,
        file_path,
        content,
        embedding_model,
        should_chunk,
        chapter_name,
        chapter_type
      ) do
    # Generate vector embedding
    if should_chunk do
      # Process with chunking (use existing chunking logic but add chapter metadata)
      chunks = create_content_chunks(content)
      Logger.info("Created #{length(chunks)} chunks for chapter #{chapter_name}")

      # Process each chunk
      results =
        chunks
        |> Enum.with_index(1)
        |> Enum.map(fn {chunk_content, index} ->
          # Generate embedding for this chunk
          vector = LLMService.generate_embeddings(chunk_content, embedding_model)

          # Store the chunk with chapter metadata
          document = %{
            "parent_directory" => parent_dir,
            "subcollection" => subcollection,
            "report_id" => report_id,
            "chunk_id" => "#{report_id}_#{chapter_name}_chunk#{index}",
            "vector" => vector,
            "text" => chunk_content,
            "position" => index,
            "chapter_name" => chapter_name,
            "chapter_type" => chapter_type,
            "created_at" => DateTime.utc_now()
          }

          Repo.insert_one(@vectors_collection, document)
        end)

      # Create file tracking entry
      create_file_tracking_entry(parent_dir, file_path, subcollection)

      # Check if all chunks were created successfully
      if Enum.all?(results, fn res -> match?({:ok, _}, res) end) do
        {:ok, "Created vectors for chapter #{chapter_name}"}
      else
        {:error, "Failed to create some chunks for chapter #{chapter_name}"}
      end
    else
      # Process without chunking - embed the entire chapter
      vector = LLMService.generate_embeddings(content, embedding_model)

      # Create a single vector entry with chapter metadata
      document = %{
        "parent_directory" => parent_dir,
        "subcollection" => subcollection,
        "report_id" => report_id,
        "chunk_id" => "#{report_id}_#{chapter_name}_chunk1",
        "vector" => vector,
        "text" => content,
        "position" => 1,
        "chapter_name" => chapter_name,
        "chapter_type" => chapter_type,
        "created_at" => DateTime.utc_now()
      }

      # Store in vectors collection
      case Repo.insert_one(@vectors_collection, document) do
        {:ok, _result} ->
          # Create file tracking entry
          create_file_tracking_entry(parent_dir, file_path, subcollection)
          {:ok, "Vector created for chapter #{chapter_name}"}

        {:error, error} ->
          Logger.error("Failed to store vector for chapter #{chapter_name}: #{inspect(error)}")
          {:error, "Database error"}
      end
    end
  end

  @doc """
  Determines the proper order of chapter files based on their filenames.

  Example:
  Input: ["1. Vorwort.md", "2.2.1 Chapter.md", "2. Geräte.md", "2.1 Gut.md"]
  Output: %{1 => "1. Vorwort.md", 2 => "2. Geräte.md", 3 => "2.1 Gut.md", 4 => "2.2.1 Chapter.md"}
  """
  def determine_chapter_order(chapter_files) do
    # Extract numbering and create tuples of [original filename, parsed numbers]
    files_with_numbers =
      chapter_files
      |> Enum.map(fn filename ->
        # Extract number prefix (e.g., "1.", "2.2.1")
        number_parts =
          case Regex.run(~r/^(\d+(\.\d+)*)/, filename) do
            [prefix | _] ->
              # Split the prefix into individual numbers and convert to integers
              prefix
              |> String.trim_trailing(" ")
              |> String.split(".")
              |> Enum.map(fn part ->
                case Integer.parse(String.trim(part)) do
                  {num, _} -> num
                  :error -> 0
                end
              end)

            nil ->
              # If no number prefix found, use a large number to place at the end
              [9999]
          end

        {filename, number_parts}
      end)

    # Sort the files based on their numeric parts
    sorted_files =
      files_with_numbers
      |> Enum.sort_by(
        fn {_, numbers} -> numbers end,
        fn a, b ->
          # Compare number arrays element by element
          compare_number_arrays(a, b)
        end
      )
      |> Enum.map(fn {filename, _} -> filename end)

    # Create the final map with sequential positions
    sorted_files
    |> Enum.with_index(1)
    |> Enum.into(%{}, fn {filename, index} -> {index, filename} end)
  end

  # Helper function to compare arrays of numbers element by element
  defp compare_number_arrays(a, b) do
    # Zip the arrays for comparison
    pairs = Enum.zip(a, b)

    # Find the first pair that differs
    Enum.reduce_while(pairs, :eq, fn {a_val, b_val}, _acc ->
      cond do
        a_val < b_val -> {:halt, true}
        a_val > b_val -> {:halt, false}
        a_val == b_val -> {:cont, :eq}
      end
    end)
    |> case do
      # If all common elements are equal, shorter array comes first
      :eq ->
        length(a) <= length(b)

      result ->
        result
    end
  end
end
