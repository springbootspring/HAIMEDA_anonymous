defmodule RIM.VectorMaintenance do
  require Logger
  alias HaimedaCore.Repo
  alias LLMService
  alias RIM.VectorPersistence

  @rag_collection "RAG"
  @vectors_collection "vectors"
  @supported_extensions [".md", ".txt", ".json", ".docx", ".docm"]

  @doc """
  Synchronize vector database with file system when tracking is enabled.

  ## Parameters
  - parent_dir: The parent directory containing report subdirectories
  - subcollections: Map of subcollection names to file patterns
  - embedding_model: The embedding model to use for vector generation
  - chunking_subcollections: List of subcollections that should use chunking strategies
  """
  def synchronize_vector_database(
        parent_dir,
        subcollections,
        embedding_model,
        chunking_subcollections \\ []
      ) do
    Logger.info("Starting vector database synchronization for #{parent_dir}")

    # Get current file metadata from the file system
    current_files = scan_rag_directories(parent_dir, subcollections)

    # Get previously tracked files from the database
    tracked_files = get_tracked_files()

    # Identify files with missing vectors
    files_with_missing_vectors =
      tracked_files
      |> Enum.filter(fn file ->
        {:error, :no_vectors_found} == check_missing_vectors(file, chunking_subcollections)
      end)

    # Add files with missing vectors to the changed files list for regeneration
    missing_vector_paths = Enum.map(files_with_missing_vectors, & &1.file_path)
    Logger.info("Found #{length(files_with_missing_vectors)} files with missing vectors")

    # Identify changed, new, and deleted files
    changed_files = identify_changed_files(current_files, tracked_files)

    # Add files with missing vectors to changed files list if they still exist
    changed_files =
      Enum.concat(
        changed_files,
        Enum.filter(files_with_missing_vectors, fn file ->
          file.file_path in Enum.map(current_files, & &1.file_path)
        end)
      )
      |> Enum.uniq_by(& &1.file_path)

    new_files = identify_new_files(current_files, tracked_files)
    deleted_files = identify_deleted_files(current_files, tracked_files)

    # Log what we found
    Logger.info(
      "Found #{length(changed_files)} changed files, #{length(new_files)} new files, and #{length(deleted_files)} deleted files"
    )

    # Update vectors for changed and new files
    if length(changed_files) + length(new_files) > 0 do
      generate_vectors_for_files(
        parent_dir,
        changed_files ++ new_files,
        embedding_model,
        chunking_subcollections
      )
    end

    # Remove vectors for deleted files
    if length(deleted_files) > 0 do
      remove_vectors_for_files(deleted_files)
    end

    # Update tracking information for all current files
    update_file_tracking(current_files, chunking_subcollections)

    {:ok, "Vector database synchronized successfully"}
  end

  @doc """
  Scan directories for RAG files based on subcollection configuration

  ## Parameters
  - parent_dir: Parent directory path
  - subcollections: Map of subcollection names to file patterns

  ## Returns
  - List of file metadata maps
  """
  def scan_rag_directories(parent_dir, subcollections) do
    Logger.debug("Scanning RAG directories in #{parent_dir}")

    # Get all subdirectories (report IDs)
    report_dirs =
      case File.ls(parent_dir) do
        {:ok, entries} ->
          entries
          |> Enum.filter(fn entry ->
            path = Path.join(parent_dir, entry)
            File.dir?(path)
          end)
          |> Enum.map(fn dir -> Path.join(parent_dir, dir) end)

        {:error, reason} ->
          Logger.error("Failed to list directories in #{parent_dir}: #{reason}")
          []
      end

    # For each report directory, scan for the file patterns defined in subcollections
    Enum.flat_map(report_dirs, fn report_dir ->
      report_id = Path.basename(report_dir)

      Enum.flat_map(subcollections, fn subcoll_item ->
        {subcoll_name, file_pattern} = extract_subcoll_data(subcoll_item)

        if VectorPersistence.is_directory_pattern?(file_pattern) do
          # Handle wildcard patterns like "single_chapters/*.md"
          {dir_part, file_pattern_glob} = VectorPersistence.split_directory_pattern(file_pattern)
          dir_path = Path.join(report_dir, dir_part)

          if File.dir?(dir_path) do
            case File.ls(dir_path) do
              {:ok, files} ->
                # Filter files matching the pattern
                matching_files =
                  VectorPersistence.filter_files_by_pattern(files, file_pattern_glob)

                # Filter out heading-only files
                Enum.flat_map(matching_files, fn file ->
                  file_path = Path.join(dir_path, file)

                  # Check if file should be processed (not heading-only)
                  case File.read(file_path) do
                    {:ok, content} ->
                      # Use the token estimation function to exclude heading-only files
                      token_count = VectorPersistence.estimate_token_length(content)

                      if token_count >= 20 do
                        [get_file_metadata(file_path, subcoll_name, report_id)]
                      else
                        # Logger.info("Skipping heading-only file during scan: #{file_path}")
                        []
                      end

                    {:error, _} ->
                      []
                  end
                end)

              {:error, _} ->
                []
            end
          else
            []
          end
        else
          # Handle single files (existing behavior)
          file_path = Path.join(report_dir, file_pattern)

          if File.exists?(file_path) do
            [get_file_metadata(file_path, subcoll_name, report_id)]
          else
            []
          end
        end
      end)
    end)
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

  # Handle string keys too
  defp extract_subcoll_data({subcoll_name, filename}) when is_binary(subcoll_name) do
    {subcoll_name, filename}
  end

  @doc """
  Get metadata for a specific file

  ## Parameters
  - file_path: Path to the file
  - subcollection: Name of the subcollection
  - report_id: ID of the report

  ## Returns
  - Map with file metadata
  """
  def get_file_metadata(file_path, subcollection, report_id) do
    case File.stat(file_path, time: :posix) do
      {:ok, %{mtime: mtime, size: size}} ->
        %{
          file_path: file_path,
          # Convert to milliseconds for consistency with MongoDB
          last_modified: mtime * 1000,
          file_size: size,
          subcollection: subcollection,
          report_id: report_id
        }

      {:error, reason} ->
        Logger.error("Failed to get stats for #{file_path}: #{reason}")
        nil
    end
  end

  @doc """
  Get list of tracked files from the database

  ## Returns
  - List of file tracking records
  """
  def get_tracked_files do
    try do
      # Get file tracking from the RAG collection
      Repo.find_one(@rag_collection, %{})
      |> case do
        nil ->
          []

        doc ->
          # Extract file_tracking from the RAG document
          file_tracking = Map.get(doc, "file_tracking", [])

          # Convert to the format expected by other functions
          Enum.map(file_tracking, fn entry ->
            %{
              file_path: entry["file_path"],
              last_modified: entry["last_modified"],
              file_size: entry["file_size"],
              subcollection: entry["subcollection"],
              last_embedding_generated: entry["last_embedding_generated"],
              report_id:
                Map.get(
                  entry,
                  "report_id",
                  entry["file_path"] |> Path.dirname() |> Path.basename()
                )
            }
          end)
      end
    rescue
      e ->
        Logger.error("Failed to retrieve tracked files: #{inspect(e)}")
        []
    end
  end

  @doc """
  Identify files that have changed since last tracking

  ## Parameters
  - current_files: List of current file metadata from file system
  - tracked_files: List of tracked file metadata from database

  ## Returns
  - List of changed file metadata
  """
  def identify_changed_files(current_files, tracked_files) do
    Enum.filter(current_files, fn %{file_path: path, last_modified: mod_time, file_size: size} ->
      case Enum.find(tracked_files, fn t -> t.file_path == path end) do
        # Not a change but a new file
        nil ->
          false

        tracked ->
          # File is changed if modification time or size has changed
          tracked.last_modified != mod_time || tracked.file_size != size
      end
    end)
  end

  @doc """
  Identify new files not yet in tracking database

  ## Parameters
  - current_files: List of current file metadata from file system
  - tracked_files: List of tracked file metadata from database

  ## Returns
  - List of new file metadata
  """
  def identify_new_files(current_files, tracked_files) do
    tracked_paths = Enum.map(tracked_files, & &1.file_path)

    Enum.filter(current_files, fn %{file_path: path} ->
      path not in tracked_paths
    end)
  end

  @doc """
  Identify files that have been deleted from the file system

  ## Parameters
  - current_files: List of current file metadata from file system
  - tracked_files: List of tracked file metadata from database

  ## Returns
  - List of deleted file metadata
  """
  def identify_deleted_files(current_files, tracked_files) do
    current_paths = Enum.map(current_files, & &1.file_path)

    Enum.filter(tracked_files, fn %{file_path: path} ->
      path not in current_paths
    end)
  end

  @doc """
  Generate vector embeddings for a list of files

  ## Parameters
  - parent_dir: Parent directory for RAG files
  - files: List of file metadata for processing
  - embedding_model: Model to use for embedding generation
  - chunking_subcollections: List of subcollections that should use chunking strategies

  ## Returns
  - Number of successfully processed files
  """
  def generate_vectors_for_files(
        parent_dir,
        files,
        embedding_model,
        chunking_subcollections \\ []
      ) do
    Logger.info("Generating vectors for #{length(files)} files")

    results =
      Enum.map(files, fn file ->
        generate_vector_for_file(parent_dir, file, embedding_model, chunking_subcollections)
      end)

    success_count = Enum.count(results, fn res -> elem(res, 0) == :ok end)
    Logger.info("Successfully generated vectors for #{success_count}/#{length(files)} files")

    success_count
  end

  @doc """
  Generate a vector embedding for a single file

  ## Parameters
  - parent_dir: Parent directory for RAG files
  - file: File metadata
  - embedding_model: Model to use for embedding generation
  - chunking_subcollections: List of subcollections that should use chunking strategies

  ## Returns
  - {:ok, file_path} on success
  - {:error, reason} on failure
  """
  def generate_vector_for_file(parent_dir, file, embedding_model, chunking_subcollections \\ []) do
    file_path = file.file_path

    if File.exists?(file_path) do
      # Check if this is a file with very small content (heading-only)
      case File.read(file_path) do
        {:ok, content} ->
          token_count = VectorPersistence.estimate_token_length(content)

          if token_count < 20 do
            # Logger.info("Skipping heading-only file during vector generation: #{file_path}")
            {:ok, "Skipped heading-only file"}
          else
            # Extract chapter name if this is a chapter file
            chapter_name =
              if String.contains?(file_path, "single_chapters") do
                VectorPersistence.extract_chapter_name(Path.basename(file_path))
              else
                nil
              end

            # Determine chapter type if applicable
            chapter_type =
              if chapter_name do
                VectorPersistence.determine_chapter_type(chapter_name, content)
              else
                nil
              end

            # Check if this subcollection requires file_per_chunk processing
            subcoll_name = file.subcollection

            use_file_per_chunk =
              Enum.any?(chunking_subcollections, fn chunk_config ->
                case chunk_config do
                  %{} -> Map.get(chunk_config, subcoll_name) == ":file_per_chunk"
                  _ -> false
                end
              end)

            # Calculate file hash
            file_hash = VectorPersistence.calculate_file_hash(file_path)

            # Handle based on chunking strategy
            if use_file_per_chunk && String.contains?(file_path, "single_chapters") do
              # Process with file-per-chunk strategy similar to VectorPersistence
              report_id = file.report_id || Path.basename(Path.dirname(Path.dirname(file_path)))

              # Read the list of files in the directory
              dir_path = Path.dirname(file_path)

              # Handle using appropriate chunking strategy from VectorPersistence
              case File.ls(dir_path) do
                {:ok, files} ->
                  # Get all *.md files
                  matching_files = VectorPersistence.filter_files_by_pattern(files, "*.md")

                  # Determine chapter order
                  ordered_chapters = VectorPersistence.determine_chapter_order(matching_files)

                  # Find position for this specific file
                  position =
                    ordered_chapters
                    |> Enum.find(fn {pos, filename} ->
                      filename == Path.basename(file_path)
                    end)
                    |> case do
                      {pos, _} -> pos
                      # Default if ordering can't be determined
                      nil -> 1
                    end

                  # Generate vector for this file with sequential position
                  vector = LLMService.generate_embeddings(content, embedding_model)

                  # Create document with proper chapter metadata
                  document = %{
                    "parent_directory" => parent_dir,
                    "subcollection" => file.subcollection,
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
                    {:ok, _} ->
                      # Update file tracking entry
                      VectorPersistence.create_file_tracking_entry(
                        parent_dir,
                        file_path,
                        file.subcollection
                      )

                      {:ok, file_path}

                    {:error, reason} ->
                      Logger.error("Failed to store vector: #{inspect(reason)}")
                      {:error, "Database error"}
                  end

                {:error, reason} ->
                  Logger.error("Failed to list directory for ordered chunking: #{reason}")
                  {:error, "Directory listing failed"}
              end
            else
              # Generate vector embedding
              vector = LLMService.generate_embeddings(content, embedding_model)

              # Create or update vector entry
              subcollection = file.subcollection
              report_id = file.report_id || Path.basename(Path.dirname(file_path))

              VectorPersistence.create_vector_entry(
                parent_dir,
                report_id,
                subcollection,
                file_path,
                file_hash,
                content,
                vector,
                chapter_type
              )

              # Update file tracking entry
              VectorPersistence.create_file_tracking_entry(parent_dir, file_path, subcollection)

              {:ok, file_path}
            end
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

  @doc """
  Remove vectors for deleted files

  ## Parameters
  - files: List of file metadata for deleted files

  ## Returns
  - Number of successfully removed vector entries
  """
  def remove_vectors_for_files(files) do
    Logger.info("Removing vectors for #{length(files)} deleted files")

    results =
      Enum.map(files, fn file ->
        remove_vector_for_file(file)
      end)

    success_count = Enum.count(results, fn res -> elem(res, 0) == :ok end)
    Logger.info("Successfully removed vectors for #{success_count}/#{length(files)} files")

    success_count
  end

  @doc """
  Remove vector for a single deleted file

  ## Parameters
  - file: File metadata for deleted file

  ## Returns
  - {:ok, file_path} on success
  - {:error, reason} on failure
  """
  def remove_vector_for_file(file) do
    file_path = file.file_path
    subcollection = file.subcollection
    parent_dir = Path.dirname(Path.dirname(file_path))

    try do
      # Delete from separate vectors collection
      Repo.delete_many(@vectors_collection, %{
        "parent_directory" => parent_dir,
        "subcollection" => subcollection,
        "report_id" => Path.basename(Path.dirname(file_path))
      })

      # Delete from file tracking in RAG collection
      update_tracking = %{
        "$pull" => %{
          "file_tracking" => %{"file_path" => file_path}
        }
      }

      Repo.update_one(@rag_collection, %{"parent_directory" => parent_dir}, update_tracking)

      {:ok, file_path}
    rescue
      e ->
        Logger.error("Failed to remove vector for #{file_path}: #{inspect(e)}")
        {:error, "Database error"}
    end
  end

  @doc """
  Update file tracking information for all current files

  ## Parameters
  - files: List of current file metadata
  - chunking_subcollections: List of subcollections that use chunking strategies

  ## Returns
  - Number of successfully updated tracking entries
  """
  def update_file_tracking(files, chunking_subcollections \\ []) do
    Logger.info("Updating tracking information for #{length(files)} files")

    results =
      Enum.map(files, fn file ->
        update_file_tracking_entry(file, chunking_subcollections)
      end)

    success_count = Enum.count(results, fn res -> elem(res, 0) == :ok end)
    Logger.info("Successfully updated tracking for #{success_count}/#{length(files)} files")

    success_count
  end

  @doc """
  Update tracking information for a single file

  ## Parameters
  - file: File metadata
  - chunking_subcollections: List of subcollections that use chunking strategies

  ## Returns
  - {:ok, file_path} on success
  - {:error, reason} on failure
  """
  def update_file_tracking_entry(file, chunking_subcollections \\ []) do
    file_path = file.file_path
    parent_dir = Path.dirname(Path.dirname(file_path))
    report_id = file.report_id || Path.basename(Path.dirname(file_path))

    entry = %{
      "file_path" => file_path,
      "last_modified" => file.last_modified,
      "file_size" => file.file_size,
      "last_embedding_generated" => DateTime.utc_now() |> DateTime.to_unix(:millisecond),
      "subcollection" => file.subcollection,
      "report_id" => report_id
    }

    try do
      # Check if entry already exists in the file_tracking subdocument array
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

      # Check if this is a file_per_chunk subcollection
      subcoll_name = file.subcollection

      is_chunking_subcoll =
        Enum.any?(chunking_subcollections, fn chunk_config ->
          case chunk_config do
            %{} -> Map.get(chunk_config, subcoll_name) == ":file_per_chunk"
            _ -> false
          end
        end)

      # Only verify vectors for non-chunked subcollections or at collection level for chunked ones
      if is_chunking_subcoll && String.contains?(file_path, "single_chapters") do
        # For file_per_chunk, we only need to verify at the collection level, not per file
        :ok
      else
        # For regular files, check if vectors exist
        result = VectorPersistence.verify_vectors_exist(parent_dir, report_id, file.subcollection)

        # Log warning if no vectors found but continue processing
        if match?({:error, :no_vectors_found}, result) do
          Logger.warning("No vectors found for #{file_path} in report_id #{report_id}")
        end
      end

      {:ok, file_path}
    rescue
      e ->
        Logger.error("Failed to update tracking for #{file_path}: #{inspect(e)}")
        {:error, "Database error"}
    end
  end

  @doc """
  Check if a file's vectors are missing based on tracking info
  """
  def check_missing_vectors(file, chunking_subcollections \\ []) do
    parent_dir = Path.dirname(Path.dirname(file.file_path))
    report_id = file.report_id || Path.basename(Path.dirname(file.file_path))

    # Check if this is a file_per_chunk subcollection
    subcoll_name = file.subcollection

    is_chunking_subcoll =
      Enum.any?(chunking_subcollections, fn chunk_config ->
        case chunk_config do
          %{} -> Map.get(chunk_config, subcoll_name) == ":file_per_chunk"
          _ -> false
        end
      end)

    if is_chunking_subcoll && String.contains?(file.file_path, "single_chapters") do
      # For file_per_chunk strategy files, check at collection level
      {:ok, :vectors_exist}
    else
      # For regular files, check normally
      VectorPersistence.verify_vectors_exist(parent_dir, report_id, file.subcollection)
    end
  end
end
