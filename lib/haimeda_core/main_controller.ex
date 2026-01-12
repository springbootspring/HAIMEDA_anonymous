defmodule HaimedaCore.MainController do
  @moduledoc """
  Main controller for all AI and non-AI modules, the GUI, and the interactions between them and the user.
  """
  alias RAM
  alias RIM
  alias IIV
  alias LLMService
  alias HaimedaCore.FeedbackModule
  alias HaimedaCore.GeneralHelperFunctions, as: GHF
  alias HaimedaCore.PerformanceMonitor
  require Logger

  # Define path directly to the config directory in the project root
  @path_application_properties Path.join([
                                 File.cwd!(),
                                 "config",
                                 "application_properties.yaml"
                               ])

  @doc """
  Creates chapter content using AI based on the provided title, metadata, and chapter info.

  Parameters:
  input_info = %{
        chapter_num: chapter_num,
        title: chapter_title,
        meta_data: meta_data,
        chapter_info: chapter_info,
        previous_chapters: previous_chapters
      }

  Now sends updates directly to the editor process rather than returning a value.
  Returns :ok or {:error, reason} without messages for display.
  """
  def initiate_chapter_creation_with_AI(target_pid, input_info, verifier_config, model_params) do
    Logger.info("Generating chapter content for: #{input_info.title}")
    show_perf = GHF.get_performance_output_setting()

    case PerformanceMonitor.track_execution("IIV", "pre_process_input_to_LLM", show_perf, fn ->
           IIV.pre_process_input_to_LLM(input_info)
         end) do
      {:ok, {parsed_terms, feedback}} = iiv_result ->
        Logger.info(
          "Results of the symbolic verifier: \n#{GHF.format_inspection_result(parsed_terms)}"
        )

        # Send feedback to feedback module
        {has_red_feedback, status_message, parsed_feedback} =
          FeedbackModule.process_iiv_feedback(iiv_result)

        # Send the feedback to the UI
        status_type = if has_red_feedback, do: "error", else: "ai"

        FeedbackModule.send_feedback_to_ui(
          target_pid,
          status_message,
          parsed_feedback,
          status_type
        )

        # Proceed with chapter creation if no critical issues
        if not has_red_feedback do
          # Generate the text content

          number_runs = Map.get(verifier_config, :verification_count, 1)

          results =
            1..number_runs
            |> Enum.reduce([], fn run_count, acc ->
              # Create chapter with performance tracking
              result =
                PerformanceMonitor.track_execution("RAM", "create_chapter", show_perf, fn ->
                  RAM.create_chapter(
                    model_params,
                    input_info
                  )
                end)

              send(target_pid, {:update_textarea_field_new_version, result, "writable"})

              [result | acc]
            end)
            |> Enum.reverse()

          # Send LLM message about completion
          FeedbackModule.send_chat_message(
            target_pid,
            "Ich habe Kapitelinhalte für Sie erstellt. Die Verifikation durch den Post-Processor steht noch aus...",
            "system"
          )

          # Just log success and return :ok
          Logger.info("Chapter content generated successfully for #{input_info.title}")

          # Start post-processor with performance tracking
          start_postprocessor(target_pid, input_info, results, :auto, verifier_config)

          :ok
        else
          # Just log the error and return error tuple
          Logger.error(
            "Chapter creation failed due to verification errors for #{input_info.title}"
          )

          {:error, :verification_failed}
        end

      {:error, reason} ->
        Logger.error("Failed to verify input for chapter creation: #{reason}")

        set_textarea_mode(target_pid, "read-only")

        FeedbackModule.send_status_message(
          target_pid,
          "Fehler bei der Verifikation: #{reason}",
          "error"
        )

        # Send error message to chat
        FeedbackModule.send_chat_message(
          target_pid,
          "Bei der Verifikation ist ein Fehler aufgetreten: #{reason}",
          "symbolic_ai"
        )

        # Send error message directly to the editor
        error_msg = "Fehler bei der Verifikation: #{reason}"
        send(target_pid, {:update_textarea_field, error_msg, "writable"})

        # Return error tuple with the reason
        {:error, reason}
    end
  end

  @doc """
  Post-processes the existing content in the textarea field.
  This is used when manually triggering the verification process.

  Parameters:
  - input_info: Map containing chapter metadata (same structure as for chapter creation)
  - textarea: Current content of the textarea field
  - target_pid: PID of the process to send updates to

  Returns :ok
  """
  def start_postprocessor(target_pid, input_info, output_content, mode, verifier_config) do
    show_perf = GHF.get_performance_output_setting()

    # Send initial status message
    FeedbackModule.send_status_message(
      target_pid,
      "Post-Processor: Verifikation des Kapitelinhalts gestartet",
      "info"
    )

    # Post-process the output with performance tracking
    case PerformanceMonitor.track_execution("IIV", "post_process_content", show_perf, fn ->
           IIV.post_process_content(input_info, output_content, mode, verifier_config)
         end) do
      {:ok, :auto_results, ordered_results} ->
        # Extract all scores from ordered results
        all_scores =
          ordered_results
          |> Enum.map(fn {rank, {scores, _content, run_number}} ->
            {rank, run_number, scores}
          end)

        # Format the scores for display and send feedback messages
        formatted_scores = format_multiple_verification_scores(all_scores)

        # Send a status message about the verification runs
        FeedbackModule.send_status_message(
          target_pid,
          "Post-Processor: #{length(Map.keys(ordered_results))} Verifikationsläufe erfolgreich durchgeführt",
          "success"
        )

        # Send a chat message with all the scores
        FeedbackModule.send_chat_message(
          target_pid,
          "Ich habe #{length(Map.keys(ordered_results))} Verifikationsläufe durchgeführt. Hier sind die Ergebnisse:\n\n#{formatted_scores}",
          "hybrid_ai"
        )

        # Transform the ordered_results to only include content and run_number
        content_only_results =
          ordered_results
          |> Enum.map(fn {rank, {_scores, content, run_number}} ->
            {rank, {content, run_number}}
          end)
          |> Map.new()

        # Send the multiple versions to the editor
        send(target_pid, {:update_textarea_multiple_versions, content_only_results, "writable"})

        :ok

      {:ok, scores, post_processed_content} ->
        # Process the verification results
        {status_message, chat_message} = FeedbackModule.process_postprocessor_result(scores)

        combined_chat_message =
          chat_message <>
            "\n" <> "Der verifizierte Inhalt steht Ihnen nun im Textfeld zur Verfügung."

        # If the post-processed result is different, update the output_content

        send(
          target_pid,
          {:update_textarea_field_correction_mode, post_processed_content, "writable"}
        )

        # Send success messages
        FeedbackModule.send_status_message(target_pid, status_message, "success")
        FeedbackModule.send_chat_message(target_pid, combined_chat_message, "hybrid_ai")

        # Log the successful verification
        Logger.info("Chapter content verified successfully for #{input_info.title}")

        # Set textarea back to writable mode
        set_textarea_mode(target_pid, "writable")

        # Set loading to false
        send(target_pid, {:loading, false})
        :ok

      {:error, :no_input_entities} ->
        # No input content to verify
        FeedbackModule.send_status_message(
          target_pid,
          "Post-Processor: Verifikation nicht möglich",
          "error"
        )

        FeedbackModule.send_chat_message(
          target_pid,
          "Es wurden keine Inhalte im Eingabebereich gefunden, die eine Verifikation ermöglichen.",
          "hybrid_ai"
        )

        # Set textarea back to writable mode
        set_textarea_mode(target_pid, "writable")

        # Set loading to false
        send(target_pid, {:loading, false})
        {:error, :no_input_entities}

      {:error, :no_output_entities} ->
        # No output content to verify
        FeedbackModule.send_status_message(
          target_pid,
          "Post-Processor: Verifikation nicht möglich",
          "error"
        )

        FeedbackModule.send_chat_message(
          target_pid,
          "Es wurden keine Inhalte im Ausgabebereich gefunden, die eine Verifikation ermöglichen.",
          "hybrid_ai"
        )

        # Set textarea back to writable mode
        set_textarea_mode(target_pid, "writable")

        # Set loading to false
        send(target_pid, {:loading, false})
        {:error, :no_output_entities}

      {:error, message} when is_binary(message) ->
        # Set textarea back to writable mode
        set_textarea_mode(target_pid, "writable")

        # Add error message directly to status log
        FeedbackModule.send_status_message(
          target_pid,
          "Post-Processor: #{message}",
          "error"
        )

        # Send error message to chat
        FeedbackModule.send_chat_message(
          target_pid,
          "Die Verifikation des Kapitels ist fehlgeschlagen: #{message}",
          "hybrid_ai"
        )

        # Log the error
        Logger.error("Post-processing failed: #{message}")

        # Set loading to false
        send(target_pid, {:loading, false})
        {:error, message}

      {:error, cause} when is_atom(cause) ->
        # Set textarea back to writable mode
        set_textarea_mode(target_pid, "writable")

        # Handle verification error
        error_message =
          "Post-Processor: Verifikation des Kapitelinhalts fehlgeschlagen: #{inspect(cause)}"

        # Add error message to status log
        FeedbackModule.send_status_message(
          target_pid,
          error_message,
          "error"
        )

        # Send error message to chat
        FeedbackModule.send_chat_message(
          target_pid,
          "Die Verifikation des Kapitels ist fehlgeschlagen. Details im Status-Log.",
          "hybrid_ai"
        )

        # Log the error
        Logger.error("Post-processing failed: #{inspect(cause)}")

        # Set loading to false
        send(target_pid, {:loading, false})
        {:error, cause}

      {:error, :output_correction_error, scores, original_content} ->
        # Process the verification results to get formatted scores
        {verification_status, scores_message} =
          FeedbackModule.process_postprocessor_result(scores)

        # Update the textarea with the original content (since correction failed)
        send(target_pid, {:update_textarea_field, original_content, "writable"})

        # Send success message for verification
        FeedbackModule.send_status_message(
          target_pid,
          # This will be the success message for verification
          verification_status,
          "success"
        )

        # Send error message for correction failure
        FeedbackModule.send_status_message(
          target_pid,
          "Post-Processor: Fehler bei der Korrektur des Textes",
          "error"
        )

        # Send chat message with the scores and correction error
        correction_error_message =
          scores_message <>
            "\nDie automatische Korrektur des Textes ist fehlgeschlagen. Der Originaltext wurde beibehalten."

        FeedbackModule.send_chat_message(
          target_pid,
          correction_error_message,
          "hybrid_ai"
        )

        # Set textarea back to writable mode
        set_textarea_mode(target_pid, "writable")

        # Set loading to false
        send(target_pid, {:loading, false})

        # Return partial success (verification succeeded but correction failed)
        {:error, :output_correction_error}
    end
  end

  def create_summary(target_pid, content) do
    model_params = extract_model_params_from_yaml("Text_Summarization")
    show_perf = GHF.get_performance_output_setting()

    PerformanceMonitor.track_execution("RAM", "summarize_text", show_perf, fn ->
      RAM.summarize_text(model_params, content)
    end)
  end

  def revise_text_with_changes(target_pid, input_info) do
    show_perf = GHF.get_performance_output_setting()

    # Send initial status message
    FeedbackModule.send_status_message(
      target_pid,
      "Revision des Textes gestartet",
      "info"
    )

    verifier_config = input_info.verifier_config
    model_params = extract_model_params_from_yaml("Text_Revision")

    # Process the text with the LLM and performance tracking
    result =
      PerformanceMonitor.track_execution("RAM", "revise_text", show_perf, fn ->
        RAM.revise_text(model_params, input_info)
      end)

    start_postprocessor(target_pid, input_info, result, :manual, verifier_config)

    # Send success message
    FeedbackModule.send_status_message(
      target_pid,
      "Textrevision abgeschlossen",
      "success"
    )

    :ok
  end

  def optimize_text(target_pid, textarea_content) do
    show_perf = GHF.get_performance_output_setting()

    # Send initial status message
    model_params = extract_model_params_from_yaml("Text_Optimization")

    # Process the text with the LLM and performance tracking
    result =
      PerformanceMonitor.track_execution("RAM", "optimize_text", show_perf, fn ->
        RAM.optimize_text(model_params, textarea_content)
      end)

    # Send the optimized text to the editor
    send(target_pid, {:update_textarea_field, result, "writable"})

    # Send success message
    FeedbackModule.send_status_message(
      target_pid,
      "Textoptimierung abgeschlossen",
      "success"
    )

    FeedbackModule.send_chat_message(
      target_pid,
      "Ich habe den Text optimiert. Sie können die Änderungen im Editor sehen.",
      "system"
    )

    :ok
  end

  @doc """
  Takes a map of chapters with their versions and content,
  generates summaries for each, and returns a map with the same structure
  but with added summary field.

  Structure:
  %{
    "chapter_id" => %{
      version_number => %{
        plain_content: "...",
        chapter_id: "...",
        summary: "..." (added after processing)
      }
    }
  }
  """
  def summarize_chapters(target_pid, chapters_map) do
    show_perf = GHF.get_performance_output_setting()

    # Count total chapters for progress updates
    total_versions = count_total_versions(chapters_map)
    current_version = 0

    # Create a nested map with summaries
    result =
      Enum.reduce(chapters_map, %{}, fn {chapter_id, versions}, chapter_acc ->
        updated_versions =
          Enum.reduce(versions, %{}, fn {version_number, version_data}, version_acc ->
            # Extract content to summarize
            content = Map.get(version_data, :plain_content, "")

            # Update progress
            current_version = current_version + 1

            if rem(current_version, 5) == 0 || current_version == total_versions do
              progress_percent = Float.round(current_version / total_versions * 100, 1)

              FeedbackModule.send_status_message(
                target_pid,
                "Kapitelzusammenfassung: #{current_version}/#{total_versions} (#{progress_percent}%)",
                "info"
              )
            end

            # Generate summary with performance tracking
            summary =
              PerformanceMonitor.track_execution("RAM", "summarize_text", show_perf, fn ->
                create_summary(target_pid, content)
              end)

            # Add summary to the version data
            updated_version_data = Map.put(version_data, :summary, summary)

            # Add to version accumulator
            Map.put(version_acc, version_number, updated_version_data)
          end)

        # Add to chapter accumulator
        Map.put(chapter_acc, chapter_id, updated_versions)
      end)

    # Send completion message
    FeedbackModule.send_status_message(
      target_pid,
      "Zusammenfassung der Kapitel abgeschlossen (#{total_versions} Versionen verarbeitet)",
      "success"
    )

    FeedbackModule.send_chat_message(
      target_pid,
      "Ich habe Zusammenfassungen für #{total_versions} Kapitelversionen erstellt. Diese werden für die Kontext-Generierung verwendet.",
      "system"
    )

    # Return the updated map with summaries
    result
  end

  def handle_user_request(target_pid, request) do
    show_perf = GHF.get_performance_output_setting()
    rag_config = extract_RAG_config_from_yaml()

    rim_results =
      PerformanceMonitor.track_execution("RIM", "process_user_request", show_perf, fn ->
        RIM.process_user_request(target_pid, rag_config, request)
      end)

    case rim_results do
      {:error, :query_processing_failed} ->
        # Handle query processing failure
        FeedbackModule.send_status_message(
          target_pid,
          "Fehler bei der Verarbeitung der Anfrage: #{inspect(rim_results)}",
          "error"
        )

      {:error, :no_results} ->
        # Handle no results found
        FeedbackModule.send_status_message(
          target_pid,
          "RIM: Für die Anfrage wurden keine Ergebnisse in den lokalen Daten gefunden",
          "error"
        )

        FeedbackModule.set_loading_message(target_pid, :ai_answer)

        rag_config = Map.put(rag_config, :selected_llm, rag_config[:model_name_general])

        response =
          PerformanceMonitor.track_execution(
            "RAM",
            "user_request_without_context",
            show_perf,
            fn ->
              RAM.user_request_without_context(rag_config, request)
            end
          )

        FeedbackModule.send_chat_message(
          target_pid,
          response,
          "hybrid_ai"
        )

      {:error, :too_many_results} ->
        # Handle too many results found
        FeedbackModule.send_status_message(
          target_pid,
          "RIM: Zu viele Ergebnisse gefunden, die Anfrage kann nicht verarbeitet werden",
          "error"
        )

        FeedbackModule.send_chat_message(
          target_pid,
          "Die Suche ergab mehr Treffer in den lokalen Daten, als ich verarbeiten kann. Können Sie die Anfrage bitte konkretisieren?",
          "hybrid_ai"
        )

        FeedbackModule.set_loading_message(target_pid, :ai_answer)

        rag_config = Map.put(rag_config, :selected_llm, rag_config[:model_name_general])

        response =
          PerformanceMonitor.track_execution(
            "RAM",
            "user_request_without_context",
            show_perf,
            fn ->
              RAM.user_request_without_context(rag_config, request)
            end
          )

        FeedbackModule.send_chat_message(
          target_pid,
          response,
          "hybrid_ai"
        )

      {:ok, results} ->
        # Send the response to RAM
        count_vector_results = Integer.to_string(results.count_vector_results)
        count_mdb_results = Integer.to_string(results.count_mdb_results)
        FeedbackModule.set_loading_message(target_pid, :ai_answer)

        FeedbackModule.send_status_message(
          target_pid,
          "#{count_vector_results} Ergebnisse in Vektor-Datenbank gefunden\n#{count_mdb_results} Ergebnisse in Access-Datenbank gefunden",
          "info"
        )

        selected_llm =
          case count_vector_results do
            "0" -> rag_config[:model_name_general]
            _ -> rag_config[:model_name_rag]
          end

        IO.inspect(selected_llm, label: "Selected LLM for response")

        rag_config =
          Map.put(rag_config, :selected_llm, selected_llm)

        IO.inspect(rag_config, label: "RAG Configuration for Response")

        response =
          PerformanceMonitor.track_execution("RAM", "user_request_with_context", show_perf, fn ->
            RAM.user_request_with_context(rag_config, request, results)
          end)

        FeedbackModule.send_chat_message(
          target_pid,
          response,
          "hybrid_ai"
        )
    end
  end

  def initialize_system do
    # initialize general system settings

    show_performance_outputs = get_application_properties(["General", "show_performance_outputs"])
    verbose_console_output = get_application_properties(["General", "verbose_console_output"])
    local_OS = get_application_properties(["General", "local_OS"])

    auto_quantized_models =
      get_application_properties(["LLMs", "auto_switch_to_quantized_models"])

    disable_hybrid_postprocessing =
      get_application_properties(["IIVM", "disable_hybrid_postprocessing"])

    use_remote_ollama_models =
      get_application_properties(["LLMs", "use_remote_ollama_models"])

    ollama_server_url =
      if use_remote_ollama_models do
        get_application_properties(["LLMs", "ollama_server_url"])
      else
        nil
      end

    remote_config = %{
      use_remote_ollama_models: use_remote_ollama_models,
      ollama_server_url: ollama_server_url
    }

    # Save variables to process memory (Application environment)
    Application.put_env(:haimeda_core, :show_performance_outputs, show_performance_outputs)
    Application.put_env(:haimeda_core, :verbose_console_output, verbose_console_output)
    Application.put_env(:haimeda_core, :auto_quantized_models, auto_quantized_models)

    Application.put_env(
      :haimeda_core,
      :disable_hybrid_postprocessing,
      disable_hybrid_postprocessing
    )

    Application.put_env(:haimeda_core, :remote_config, remote_config)
    Application.put_env(:haimeda_core, :local_OS, local_OS)
  end

  def initialize_RIM(target_pid) do
    show_perf = GHF.get_performance_output_setting()

    # Get the RAG configuration from application_properties.yaml
    rag_config = extract_RAG_config_from_yaml()
    IO.inspect(rag_config, label: "RAG Configuration")

    FeedbackModule.send_status_message(
      target_pid,
      "Lokale Datenbank für RAG wird initialisiert und verifiziert",
      "info"
    )

    # Check if the RAG configuration is valid
    if rag_config do
      # Initialize the RIM with the RAG configuration and performance tracking
      case PerformanceMonitor.track_execution("RIM", "initialize_RAG_processor", show_perf, fn ->
             RIM.initialize_RAG_processor(target_pid, rag_config)
           end) do
        {:ok, _msg} ->
          {:ok, :success}

        {:error, reason} ->
          {:error, reason}
      end
    else
      Logger.error("Failed to initialize RIM: Invalid RAG configuration")
      {:error, :invalid_rag_config}
    end
  end

  def extract_RAG_config_from_yaml do
    # Get the RAG configuration from application_properties.yaml
    case get_application_properties(["RAG"]) do
      nil ->
        Logger.error("Could not find RAG configuration")
        nil

      config when is_list(config) ->
        # Extract all relevant config fields from the configuration
        # Read both model name fields
        model_name_general = get_config_value(config, "model_name_general")
        model_name_rag = get_config_value(config, "model_name_rag")
        # Fallback to old field name for backward compatibility
        model_name =
          get_config_value(config, "model_name") || get_config_value(config, "RAG_model")

        raw_params = get_config_value(config, "model_params")
        embedding_model = get_config_value(config, "embedding_model")

        only_vector_db = get_config_value(config, "only_use_existing_vector_db")
        # Extract path to parent folder for RAG files
        parent_path = get_config_value(config, "path_to_parent_folder_for_RAG_files")

        raw_mdb_files_path = get_config_value(config, "mdb_files_path")

        # Resolve mdb_files_path with environment variables
        local_OS = Application.get_env(:haimeda_core, :local_OS)

        mdb_files_path =
          case local_OS do
            "LX" ->
              resolve_path_with_env_vars(raw_mdb_files_path, "HOME")

            "Win" ->
              resolve_path_with_env_vars(raw_mdb_files_path, "USERPROFILE")

            _ ->
              raw_mdb_files_path
          end

        # Extract new fields
        enable_tracking = get_config_value(config, "enable_tracking_changed_files")
        combine_mdb_and_vector = get_config_value(config, "combine_mdb_and_vector_results")

        # Extract vector subcollections (now with key-value structure)
        vector_subcollections = get_config_value(config, "vector_subcollections") || []

        max_rag_context_chars =
          get_config_value(config, "maximum_rag_context_characters") || 15000

        if raw_params do
          # Build the RAG config map with all fields
          %{
            # Keep for backward compatibility
            selected_llm: model_name || model_name_general,
            # Add new model name fields
            model_name_general: model_name_general || model_name,
            model_name_rag: model_name_rag || model_name,
            llm_params: %{
              temperature: get_param_value(raw_params, "temperature"),
              top_p: get_param_value(raw_params, "top_p"),
              top_k: get_param_value(raw_params, "top_k"),
              max_tokens: get_param_value(raw_params, "max_tokens"),
              repeat_penalty: get_param_value(raw_params, "repeat_penalty")
            },
            mdb_files_path: mdb_files_path,
            only_vector_db: only_vector_db,
            parent_path: parent_path,
            vector_subcollections: vector_subcollections,
            embedding_model: embedding_model,
            enable_tracking_changed_files: enable_tracking,
            combine_mdb_and_vector_results: combine_mdb_and_vector,
            chunking_subcollections: get_config_value(config, "chunking_subcollections"),
            max_rag_context_chars: max_rag_context_chars
          }
        else
          Logger.error("Missing model_params in RAG configuration")
          nil
        end
    end
  end

  def extract_model_params_from_yaml(task) do
    # Get the task-specific configuration from application_properties.yaml
    case get_application_properties(["LLM_Config", task]) do
      nil ->
        Logger.error("Could not find LLM configuration for task: #{task}")
        nil

      config when is_list(config) ->
        # Extract model_name and model_params from the configuration
        model_name = get_config_value(config, "model_name")
        raw_params = get_config_value(config, "model_params")

        if model_name && raw_params do
          # Build the model_params map
          %{
            selected_llm: model_name,
            llm_params: %{
              temperature: get_param_value(raw_params, "temperature"),
              top_p: get_param_value(raw_params, "top_p"),
              top_k: get_param_value(raw_params, "top_k"),
              max_tokens: get_param_value(raw_params, "max_tokens"),
              repeat_penalty: get_param_value(raw_params, "repeat_penalty")
            }
          }
        else
          Logger.error("Missing model_name or model_params for task: #{task}")
          nil
        end

      config when is_map(config) ->
        # Extract model_name and model_params directly from the map
        model_name = Map.get(config, "model_name")
        raw_params = Map.get(config, "model_params")

        if model_name && raw_params do
          # Build the model_params map
          %{
            selected_llm: model_name,
            llm_params: %{
              temperature: get_param_value(raw_params, "temperature"),
              top_p: get_param_value(raw_params, "top_p"),
              top_k: get_param_value(raw_params, "top_k"),
              max_tokens: get_param_value(raw_params, "max_tokens"),
              # Note: renamed from repetition_penalty
              repeat_penalty: get_param_value(raw_params, "repetition_penalty")
            }
          }
        else
          Logger.error("Missing model_name or model_params for task: #{task}")
          nil
        end
    end
  end

  # Helper function to extract values from configuration lists
  defp get_config_value(config_list, key) when is_list(config_list) do
    Enum.find_value(config_list, fn
      item when is_map(item) -> Map.get(item, key)
      {^key, value} -> value
      _ -> nil
    end)
  end

  # Helper function to extract parameter values, handling both list and map formats
  defp get_param_value(params, key) when is_list(params) do
    get_config_value(params, key)
  end

  defp get_param_value(params, key) when is_map(params) do
    Map.get(params, key)
  end

  defp get_param_value(_, _), do: nil

  @doc """
  Sets the read-only state of a textarea without changing its content.
  This allows controlling whether users can edit the content.

  Parameters:
  - target_pid: PID of the process to send the update to
  - mode: "read-only" or "writable"

  Returns :ok
  """
  def set_textarea_mode(target_pid, mode) when mode in ["read-only", "writable"] do
    # Simply send a message to update the mode without changing content
    send(target_pid, {:set_textarea_mode, mode})
    :ok
  end

  # Helper to count total versions across all chapters
  defp count_total_versions(chapters_map) do
    Enum.reduce(chapters_map, 0, fn {_chapter_number, versions}, acc ->
      acc + map_size(versions)
    end)
  end

  def verify_llm_integration_ollama(target_pid) do
    use_remote =
      Map.get(
        Application.get_env(:haimeda_core, :remote_config),
        :use_remote_ollama_models,
        false
      )

    if use_remote do
      Logger.info("Skipping local LLM integration, using remote Ollama models.")

      FeedbackModule.send_status_message(
        target_pid,
        "Lokale LLM-Integration übersprungen, da Remote-Modelle verwendet werden.",
        "info"
      )

      remote_models = get_application_properties(["LLMs", "remote_models"])
      IO.inspect(remote_models, label: "Remote Models Path")

      %{
        model_paths: remote_models
      }
    else
      path_models = get_application_properties(["LLMs", "path_to_local_LLM_models"])
      local_OS = Application.get_env(:haimeda_core, :local_OS)

      # Resolve path with environment variables
      resolved_path_models =
        case local_OS do
          "LX" ->
            resolve_path_with_env_vars(path_models, "HOME")

          "Win" ->
            resolve_path_with_env_vars(path_models, "USERPROFILE")
        end

      overwrite_existing_models =
        get_application_properties(["LLMs", "overwrite_existing_ollama_models_with_same_name"])

      # Scan directory for .gguf files
      model_paths_list =
        if resolved_path_models && File.dir?(resolved_path_models) do
          resolved_path_models
          |> File.ls!()
          |> Enum.filter(fn file -> String.ends_with?(file, ".gguf") end)
          |> Enum.map(fn file -> Path.join(resolved_path_models, file) end)
        else
          Logger.warning("Model directory not found or invalid: #{resolved_path_models}")
          []
        end

      FeedbackModule.send_status_message(
        target_pid,
        "Integration lokaler LLM Modelle in Ollama gestartet",
        "info"
      )

      LLMService.verify_and_integrate_local_models(
        model_paths_list,
        overwrite_existing_models
      )

      # Return the necessary data for integration
      %{
        model_paths: model_paths_list
      }
    end
  end

  def generate_small_sample_text(run_num) do
    case run_num do
      2 -> "Gemäß schriftlichem Auftrag des Bayerischer Versicherungsverbands."
      1 -> "vom 21.04.2017"
      3 -> "Bayerischer Versicherungsverband und andere und so weiter"
    end
  end

  def generate_sample_text() do
    """
    Gemäß schriftlichem Auftrag des Bayerischer Versicherungsverband vom 21.04.2017, ist zu dem nachfolgend näher beschriebenen Schaden an einem Flexibles Endoskop ein Gutachten mit den folgenden Untersuchungspunkten zu erstatten:

    beschädigtes Objekt (BF-1T180) mit technischen Daten vom 12.12.2019,

    Schadenursache/-auswirkungen,

    beschädigte Teile (Nummer: 839203),

    Reparaturmöglichkeiten/-kosten (23298,00 EUR),

    Neu- und Zeitwert des Objektes,

    verschleißbedingte Abzüge,

    Anzahl separater Akutschäden,

    ggf. vorliegende Obliegenheitsverletzungen.

    Das schadhafte Gerät wurde für eine abschließende Begutachtung, zur Feststellung der Schadenursache und der Schadenhöhe durch den Versicherungsnehmer, zur Verfügung gestellt.
    """
  end

  defp get_application_properties(key) when is_binary(key) do
    # Handle single string key for backward compatibility
    get_application_properties([key])
  end

  defp get_application_properties(keys) when is_list(keys) do
    try do
      # Read the YAML file
      case YamlElixir.read_from_file(@path_application_properties) do
        {:ok, config} ->
          # Navigate through nested structure using the keys
          get_nested_value(config, keys)

        {:error, reason} ->
          Logger.error("Failed to read application properties: #{inspect(reason)}")
          nil
      end
    rescue
      e ->
        Logger.error("Exception while accessing application properties: #{inspect(e)}")
        nil
    end
  end

  # Helper function to navigate through nested structures
  defp get_nested_value(data, []), do: data

  defp get_nested_value(data, [key | rest]) when is_map(data) do
    # Direct map access
    value = Map.get(data, key)
    get_nested_value(value, rest)
  end

  defp get_nested_value(data, [key | rest]) when is_list(data) do
    # Handle list of maps (like in the YAML structure)
    case find_in_list(data, key) do
      nil -> nil
      value -> get_nested_value(value, rest)
    end
  end

  defp get_nested_value(_, _), do: nil

  # Helper to find a key in a list of maps
  defp find_in_list(list, key) when is_list(list) do
    # First try to find an item where the key directly exists
    found_item =
      Enum.find(list, fn
        item when is_map(item) -> Map.has_key?(item, key)
        _ -> false
      end)

    cond do
      # If we found a map with the key, return its value
      found_item && is_map(found_item) ->
        Map.get(found_item, key)

      # If the first item is a map and has this structure, try to find in all items
      length(list) > 0 && is_map(hd(list)) ->
        # Combine all maps in the list
        Enum.reduce(list, %{}, fn
          item, acc when is_map(item) -> Map.merge(acc, item)
          _, acc -> acc
        end)
        |> Map.get(key)

      true ->
        nil
    end
  end

  defp find_in_list(_, _), do: nil

  # Helper function to resolve paths containing environment variables
  # Automatically detects and replaces environment variables with OS-appropriate ones
  defp resolve_path_with_env_vars(path, target_env_var) when is_binary(path) do
    # First check if the path contains the target environment variable
    target_pattern = "${#{target_env_var}}"

    if String.contains?(path, target_pattern) do
      case System.get_env(target_env_var) do
        nil ->
          Logger.warning(
            "Environment variable #{target_env_var} not found, using path as-is: #{path}"
          )

          path

        env_value ->
          resolved_path = String.replace(path, target_pattern, env_value)
          Logger.info("Resolved path: #{path} -> #{resolved_path}")
          resolved_path
      end
    else
      # Check for cross-platform environment variable conversion
      resolve_cross_platform_env_vars(path, target_env_var)
    end
  end

  # Helper function to resolve and convert environment variables across platforms
  defp resolve_cross_platform_env_vars(path, target_env_var) when is_binary(path) do
    # Define cross-platform mappings
    cross_platform_mappings = %{
      # If we need HOME but find USERPROFILE (Windows to Linux)
      "HOME" => [{"${USERPROFILE}", "USERPROFILE"}, {"${HOME}", "HOME"}],
      # If we need USERPROFILE but find HOME (Linux to Windows)
      "USERPROFILE" => [{"${HOME}", "HOME"}, {"${USERPROFILE}", "USERPROFILE"}]
    }

    patterns_to_check = Map.get(cross_platform_mappings, target_env_var, [])

    Enum.reduce(patterns_to_check, path, fn {pattern, source_env_var}, acc_path ->
      if String.contains?(acc_path, pattern) do
        # Try to get the target environment variable first
        case System.get_env(target_env_var) do
          nil ->
            # Fallback to the source environment variable
            case System.get_env(source_env_var) do
              nil ->
                Logger.warning(
                  "Neither #{target_env_var} nor #{source_env_var} environment variables found, keeping pattern: #{pattern}"
                )

                acc_path

              source_value ->
                resolved = String.replace(acc_path, pattern, source_value)

                Logger.info(
                  "Cross-platform resolved path: #{acc_path} -> #{resolved} (used #{source_env_var} instead of #{target_env_var})"
                )

                resolved
            end

          target_value ->
            resolved = String.replace(acc_path, pattern, target_value)

            Logger.info(
              "Resolved path: #{acc_path} -> #{resolved} (converted #{source_env_var} pattern to #{target_env_var})"
            )

            resolved
        end
      else
        acc_path
      end
    end)
  end

  defp resolve_path_with_env_vars(path, _env_var_name) do
    # Handle nil or non-string paths
    path
  end

  # Helper function to generate a text section from metadata
  defp generate_metadata_section(meta_data) when map_size(meta_data) == 0,
    do: "Keine Metadaten verfügbar."

  defp generate_metadata_section(meta_data) do
    meta_data
    |> Enum.map(fn {key, value} -> "- **#{key}**: #{value}" end)
    |> Enum.join("\n")
  end

  # Add a helper function to format multiple verification scores
  defp format_multiple_verification_scores(all_scores) do
    all_scores
    |> Enum.sort_by(fn {rank, _run_number, _scores} -> rank end)
    |> Enum.map(fn {rank, run_number, scores} ->
      {_status_message, chat_message} = FeedbackModule.process_postprocessor_result(scores)

      """
      === Ergebnis Rang #{rank} (Lauf #{run_number}) ===
      #{chat_message}
      """
    end)
    |> Enum.join("\n\n")
  end
end
