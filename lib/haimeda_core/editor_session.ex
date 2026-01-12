defmodule HaimedaCore.EditorSession do
  @moduledoc """
  Context for managing editor sessions persistence in MongoDB
  """
  require Logger
  alias HaimedaCore.Repo
  alias HaimedaCoreWeb.ReportsEditor.ContentPersistence

  @collection "editor_sessions"

  # Default values for parameters
  @default_llm_params %{
    "temperature" => 0.0,
    "top_p" => 0.5,
    "top_k" => 60,
    "max_tokens" => 4000,
    "repeat_penalty" => 1.0
  }

  @default_selected_llm "llama3_german_instruct_ft_stage_d"
  @default_verification_degree :moderate_match

  # Mapping of display strings to internal atoms
  @verification_degree_mappings %{
    "Keine Übereinstimmung" => :no_match,
    "Schwache Übereinstimmung" => :weak_match,
    "Mittlere Übereinstimmung" => :moderate_match,
    "Starke Übereinstimmung" => :strong_match,
    "Exakte Übereinstimmung" => :exact_match
  }

  # Mapping of internal atoms to display strings
  @internal_to_display_mapping %{
    no_match: "Keine Übereinstimmung",
    weak_match: "Schwache Übereinstimmung",
    moderate_match: "Mittlere Übereinstimmung",
    strong_match: "Starke Übereinstimmung",
    exact_match: "Exakte Übereinstimmung"
  }

  @doc """
  Save an editor session to MongoDB
  """
  def save_session(report_id, session_data) when is_map(session_data) do
    # Include timestamp for tracking when sessions are updated
    session_with_timestamp =
      Map.put(session_data, "updated_at", DateTime.utc_now() |> DateTime.to_iso8601())

    # Ensure all required fields are present with defaults if missing
    complete_session = ensure_required_fields(session_with_timestamp)

    # Use the report_id as the document ID for easy lookup
    case Repo.find_one(@collection, %{"report_id" => report_id}) do
      nil ->
        # Create new session if it doesn't exist
        Repo.insert_one(@collection, Map.put(complete_session, "report_id", report_id))

      _existing ->
        # Update existing session
        Repo.update_one(
          @collection,
          %{"report_id" => report_id},
          %{"$set" => complete_session}
        )
    end
  end

  # Ensure all required fields are present in the session data
  defp ensure_required_fields(session_data) do
    session_data
    |> Map.put_new("verification_count", 1)
    |> Map.put_new("llm_params", @default_llm_params)
    |> Map.put_new("previous_content_mode", "full_chapters")
    |> Map.put_new("selected_llm", @default_selected_llm)
    |> Map.put_new("verification_degree", @default_verification_degree)
    |> Map.put_new("chat_messages", [])
    |> Map.put_new("logs", [])
    |> Map.put_new("tabs", [])
    |> Map.put_new("active_tab", "new_tab")
    |> Map.put_new("llm_options", [])
    # Flag indicating whether LLM was initialized for this session
    |> Map.put_new("llm_initialized", false)
  end

  @doc """
  Get an editor session for a report
  """
  def get_session(report_id) do
    case Repo.find_one(@collection, %{"report_id" => report_id}) do
      nil ->
        {:error, :not_found}

      session ->
        # Ensure all required fields exist when returning the session
        complete_session = ensure_required_fields(session)
        {:ok, complete_session}
    end
  end

  @doc """
  Delete an editor session
  """
  def delete_session(report_id) do
    Repo.delete_one(@collection, %{"report_id" => report_id})
  end

  @doc """
  Clean up old sessions older than the specified days
  """
  def cleanup_old_sessions(days \\ 30) do
    cutoff_date =
      DateTime.utc_now()
      |> DateTime.add(-days * 24 * 60 * 60, :second)
      |> DateTime.to_iso8601()

    case Repo.delete_many(@collection, %{"updated_at" => %{"$lt" => cutoff_date}}) do
      {:ok, %{deleted_count: count}} ->
        Logger.info("Cleaned up #{count} old editor sessions")
        {:ok, count}

      {:ok, result} ->
        # Handle case where result structure might be different
        count = Map.get(result, :deleted_count, 0)
        Logger.info("Cleaned up #{count} old editor sessions")
        {:ok, count}

      error ->
        Logger.error("Error cleaning up old editor sessions: #{inspect(error)}")
        error
    end
  end

  @doc """
  Prepare session data for storage by cleaning up unnecessary data
  """
  def prepare_session_data(socket) do
    # Extract only the necessary fields from tabs to avoid storing large content
    sanitized_tabs =
      Enum.map(socket.assigns.tabs, fn tab ->
        # Keep ID, label, category, section_id and other metadata,
        # but omit large content fields for storage efficiency
        base_tab = %{
          "id" => tab.id,
          "label" => tab.label,
          "category" => tab.category,
          "section_id" => tab.section_id,
          "read_only" => Map.get(tab, :read_only, false)
        }

        # Add chapter-specific fields if present
        if tab.category == "chapters" do
          base_tab
          |> Map.put("chapter_number", Map.get(tab, :chapter_number, ""))
          |> Map.put("active_meta_info", Map.get(tab, :active_meta_info, %{}))
        else
          base_tab
        end
      end)

    # Trim chat messages if there are too many (keeping only the last 50)
    trimmed_chat_messages =
      socket.assigns.chat_messages
      |> Enum.take(-50)
      |> Enum.map(fn message ->
        # Convert DateTime to ISO8601 string for storage
        timestamp =
          case message.timestamp do
            %DateTime{} -> DateTime.to_iso8601(message.timestamp)
            _ -> message.timestamp
          end

        # Ensure consistent string keys
        %{
          "sender" => message.sender,
          "content" => message.content,
          "timestamp" => timestamp
        }
      end)

    # Trim logs if there are too many (keeping only the last 50)
    trimmed_logs =
      socket.assigns.logs
      |> Enum.take(-50)
      |> Enum.map(fn log ->
        # Always use string keys for MongoDB storage
        %{
          "timestamp" => Map.get(log, :timestamp) || Map.get(log, "timestamp") || "",
          "message" => Map.get(log, :message) || Map.get(log, "message") || "",
          "type" => Map.get(log, :type) || Map.get(log, "type") || ""
        }
      end)

    # Ensure all required fields exist with proper defaults if missing
    # This prevents KeyError when accessing fields
    verification_count = Map.get(socket.assigns, :verification_count, 1)

    llm_params =
      case Map.get(socket.assigns, :llm_params) do
        nil -> @default_llm_params
        params -> params
      end

    # Use previous_content_mode setting when preparing data
    previous_content_mode = Map.get(socket.assigns, :previous_content_mode, "full_chapters")

    # Get selected LLM
    selected_llm = Map.get(socket.assigns, :selected_llm, @default_selected_llm)

    # Get verification degree - handle both atom and string values
    verification_degree =
      Map.get(socket.assigns, :verification_degree, @default_verification_degree)

    # Normalize or convert the verification degree into internal atom value
    internal_verification_degree =
      cond do
        is_atom(verification_degree) ->
          verification_degree

        is_binary(verification_degree) &&
            Map.has_key?(@verification_degree_mappings, verification_degree) ->
          Map.get(
            @verification_degree_mappings,
            verification_degree,
            @default_verification_degree
          )

        true ->
          @default_verification_degree
      end

    # Get llm_options from socket assigns
    llm_options = Map.get(socket.assigns, :llm_options, [])

    # LLM initialization flag
    llm_initialized = Map.get(socket.assigns, :llm_initialized, false)

    # Create the complete session data with all required fields
    %{
      "tabs" => sanitized_tabs,
      "active_tab" => socket.assigns.active_tab,
      "chat_messages" => trimmed_chat_messages,
      "logs" => trimmed_logs,
      "verification_count" => verification_count,
      "llm_params" => llm_params,
      "previous_content_mode" => previous_content_mode,
      "selected_llm" => selected_llm,
      "verification_degree" => internal_verification_degree,
      "llm_options" => llm_options,
      # Include the flag in the session data
      "llm_initialized" => llm_initialized
    }
  end

  @doc """
  Load editor session data for a report
  """
  def load_editor_session(report_id, report, nav_sections) do
    case HaimedaCore.EditorSession.get_session(report_id) do
      {:ok, session} ->
        restored_tabs = process_saved_tabs(session["tabs"], report_id)

        tabs_with_new =
          if Enum.any?(restored_tabs, &(&1.id == "new_tab")) do
            restored_tabs
          else
            restored_tabs ++
              [%{id: "new_tab", label: "+", content: "", category: nil, section_id: nil}]
          end

        active_tab =
          if Enum.any?(tabs_with_new, &(&1.id == session["active_tab"])) do
            session["active_tab"]
          else
            "new_tab"
          end

        tabs_with_content = load_active_tab_content(tabs_with_new, active_tab, report_id)
        chat_messages = process_saved_chat_messages(session["chat_messages"])
        logs = process_saved_logs(session["logs"] || [])
        verification_count = Map.get(session, "verification_count", 1)
        previous_content_mode = Map.get(session, "previous_content_mode", "full_chapters")

        llm_params =
          Map.get(session, "llm_params", %{
            "temperature" => 0.0,
            "top_p" => 0.5,
            "top_k" => 60,
            "max_tokens" => 4000,
            "repeat_penalty" => 1.1
          })

        selected_llm = Map.get(session, "selected_llm", "llama3_german_instruct_ft_stage_d")

        verification_degree = HaimedaCore.EditorSession.get_verification_degree(report_id)

        # Get llm_options from session
        llm_options = Map.get(session, "llm_options", [])

        # Get llm_initialized flag
        llm_initialized = Map.get(session, "llm_initialized", false)
        rag_initialized = Map.get(session, "rag_initialized", false)

        %{
          tabs: tabs_with_content,
          active_tab: active_tab,
          chat_messages: chat_messages,
          logs: logs,
          verification_count: verification_count,
          previous_content_mode: previous_content_mode,
          llm_params: llm_params,
          selected_llm: selected_llm,
          verification_degree: verification_degree,
          llm_options: llm_options,
          llm_initialized: llm_initialized,
          rag_initialized: rag_initialized
        }

      {:error, :not_found} ->
        default_tabs = [%{id: "new_tab", label: "+", content: "", category: nil, section_id: nil}]

        default_chat = [
          %{
            sender: "system",
            content:
              "Hallo! Ich bin Ihr KI-Assistent für die Gutachtenerstellung. Wie kann ich Ihnen helfen?",
            timestamp: DateTime.utc_now()
          }
        ]

        %{
          tabs: default_tabs,
          active_tab: "new_tab",
          chat_messages: default_chat,
          logs: [],
          verification_count: 1,
          previous_content_mode: "full_chapters",
          llm_params: %{
            "temperature" => 0.7,
            "top_p" => 0.9,
            "top_k" => 60,
            "max_tokens" => 4000,
            "repeat_penalty" => 1.1
          },
          selected_llm: "llama3_german_instruct_ft_stage_d",
          verification_degree: :moderate_match,
          llm_options: [],
          llm_initialized: false,
          rag_initialized: false
        }
    end
  end

  defp load_active_tab_content(tabs, active_tab_id, report_id) do
    active_tab = Enum.find(tabs, &(&1.id == active_tab_id))

    if active_tab && active_tab.id != "new_tab" do
      fake_socket = %{assigns: %{report_id: report_id}}

      loaded_tab =
        ContentPersistence.load_content_from_db(
          fake_socket,
          active_tab,
          active_tab.section_id,
          active_tab.category
        )

      loaded_tab = Map.put(loaded_tab, :read_only, false)
      # Ensure formatted_content exists
      loaded_tab = Map.put_new(loaded_tab, :formatted_content, %{})

      Enum.map(tabs, fn tab ->
        if tab.id == active_tab_id, do: loaded_tab, else: tab
      end)
    else
      tabs
    end
  end

  defp process_saved_tabs(saved_tabs, report_id) when is_list(saved_tabs) do
    Enum.map(saved_tabs, fn tab ->
      tab_id = tab["id"]

      if tab_id == "new_tab" do
        %{
          id: "new_tab",
          label: "+",
          content: "",
          category: nil,
          section_id: nil,
          formatted_content: %{},
          read_only: false,
          active_meta_info: %{
            "chapter_number" => "",
            "section_id" => "",
            "category" => ""
          }
        }
      else
        base_tab = %{
          id: tab["id"],
          label: tab["label"],
          category: tab["category"],
          section_id: tab["section_id"],
          content: "",
          read_only: false,
          formatted_content: %{},
          active_meta_info: %{
            "chapter_number" => "",
            "section_id" => "",
            "category" => ""
          }
        }

        case tab["category"] do
          "chapters" ->
            base_tab
            |> Map.put(:chapter_number, tab["chapter_number"] || "")
            |> Map.put(:active_meta_info, tab["active_meta_info"] || %{})
            |> Map.put(:chapter_info, "")

          "parties" ->
            base_tab
            |> Map.put(:person_statements, "[]")
            |> Map.put(:analysis_statements, "[]")

          _ ->
            base_tab
        end
      end
    end)
  end

  defp process_saved_tabs(nil, _),
    do: [
      %{
        id: "new_tab",
        label: "+",
        content: "",
        category: nil,
        section_id: nil,
        formatted_content: %{},
        read_only: false,
        active_meta_info: %{
          "chapter_number" => "",
          "section_id" => "",
          "category" => ""
        }
      }
    ]

  defp process_saved_chat_messages(saved_messages) when is_list(saved_messages) do
    Enum.map(saved_messages, fn message ->
      timestamp =
        case message["timestamp"] do
          timestamp when is_binary(timestamp) ->
            case DateTime.from_iso8601(timestamp) do
              {:ok, datetime, _} -> datetime
              _ -> DateTime.utc_now()
            end

          _ ->
            DateTime.utc_now()
        end

      %{
        sender: message["sender"],
        content: message["content"],
        timestamp: timestamp
      }
    end)
  end

  defp process_saved_chat_messages(_),
    do: [
      %{
        sender: "system",
        content:
          "Hallo! Ich bin Ihr KI-Assistent für die Gutachtenerstellung. Wie kann ich Ihnen helfen?",
        timestamp: DateTime.utc_now()
      }
    ]

  defp process_saved_logs(saved_logs) when is_list(saved_logs) do
    Enum.map(saved_logs, fn log ->
      %{
        timestamp: Map.get(log, "timestamp") || "",
        message: Map.get(log, "message") || "",
        type: Map.get(log, "type") || ""
      }
    end)
  end

  defp process_saved_logs(_), do: []

  @doc """
  Get the verification count for a specific report session
  Default to 1 if not found
  """
  def get_verification_count(report_id) do
    case get_session(report_id) do
      {:ok, session} -> Map.get(session, "verification_count", 1)
      _ -> 1
    end
  end

  @doc """
  Update verification count for a specific report session
  """
  def update_verification_count(report_id, count)
      when is_integer(count) and count >= 1 and count <= 20 do
    case get_session(report_id) do
      {:ok, session} ->
        # Update the verification_count in the existing session
        updated_session = Map.put(session, "verification_count", count)
        # Save the updated session
        save_session(report_id, updated_session)
        {:ok, count}

      {:error, :not_found} ->
        # Create a new session with just the verification_count
        save_session(report_id, %{"verification_count" => count})
        {:ok, count}
    end
  end

  def update_verification_count(_report_id, count) do
    {:error, "Invalid verification count: #{count}. Must be between 1 and 20."}
  end

  @doc """
  Update LLM parameters for a specific report session
  """
  def update_llm_param(report_id, param_name, value)
      when param_name in ["temperature", "top_p", "top_k", "max_tokens", "repeat_penalty"] do
    # Convert value to the appropriate type
    converted_value =
      case param_name do
        "max_tokens" ->
          case Integer.parse("#{value}") do
            {int_val, _} -> int_val
            # default if parsing fails
            :error -> 4000
          end

        "top_k" ->
          case Integer.parse("#{value}") do
            {int_val, _} -> int_val
            # default if parsing fails
            :error -> 60
          end

        _ ->
          case Float.parse("#{value}") do
            {float_val, _} ->
              float_val

            :error ->
              # Default values if parsing fails
              case param_name do
                "temperature" -> 0.7
                "top_p" -> 0.9
                "top_k" -> 60
                "repeat_penalty" -> 1.1
                _ -> 0.0
              end
          end
      end

    # Validate the value is within allowed range
    validated_value =
      case param_name do
        "temperature" -> max(0.0, min(1.0, converted_value))
        "top_p" -> max(0.0, min(1.0, converted_value))
        "top_k" -> max(0, min(100, converted_value))
        "max_tokens" -> max(0, min(10000, converted_value))
        "repeat_penalty" -> max(0.0, min(10.0, converted_value))
        _ -> converted_value
      end

    case get_session(report_id) do
      {:ok, session} ->
        # Get current LLM params or initialize with defaults
        current_params =
          Map.get(session, "llm_params", @default_llm_params)

        # Update the specific parameter
        updated_params = Map.put(current_params, param_name, validated_value)

        # Update the session with the new LLM params
        updated_session = Map.put(session, "llm_params", updated_params)
        save_session(report_id, updated_session)
        {:ok, validated_value}

      {:error, :not_found} ->
        # Create a new session with default LLM params and the updated param
        llm_params = Map.put(@default_llm_params, param_name, validated_value)
        save_session(report_id, %{"llm_params" => llm_params})
        {:ok, validated_value}
    end
  end

  def update_llm_param(_report_id, param_name, _value) do
    {:error, "Invalid LLM parameter: #{param_name}"}
  end

  @doc """
  Update the previous_content_mode for a specific report session
  """
  def update_previous_content_mode(report_id, mode) when mode in ["summaries", "full_chapters"] do
    case get_session(report_id) do
      {:ok, session} ->
        # Update the previous_content_mode in the existing session
        updated_session = Map.put(session, "previous_content_mode", mode)
        save_session(report_id, updated_session)
        {:ok, mode}

      {:error, :not_found} ->
        # Create a new session with just the previous_content_mode
        save_session(report_id, %{"previous_content_mode" => mode})
        {:ok, mode}
    end
  end

  def update_previous_content_mode(_report_id, mode) do
    {:error, "Invalid mode value: #{mode}. Must be 'summaries' or 'full_chapters'."}
  end

  @doc """
  Get the previous_content_mode setting for a specific report session
  Default to 'full_chapters' if not found
  """
  def get_previous_content_mode(report_id) do
    case get_session(report_id) do
      {:ok, session} -> Map.get(session, "previous_content_mode", "full_chapters")
      _ -> "full_chapters"
    end
  end

  @doc """
  Update the use_summaries flag for a specific report session
  """
  def update_use_summaries(report_id, use_summaries) when is_boolean(use_summaries) do
    # Convert boolean to string mode
    mode = if use_summaries, do: "summaries", else: "full_chapters"
    update_previous_content_mode(report_id, mode)
  end

  def update_use_summaries(_report_id, use_summaries) do
    {:error, "Invalid use_summaries value: #{use_summaries}. Must be true or false."}
  end

  @doc """
  Get the use_summaries setting for a specific report session
  Default to false if not found
  """
  def get_use_summaries(report_id) do
    # Convert string mode to boolean
    mode = get_previous_content_mode(report_id)
    mode == "summaries"
  end

  @doc """
  Get the LLM parameters for a specific report session
  Default to standard values if not found
  """
  def get_llm_params(report_id) do
    case get_session(report_id) do
      {:ok, session} -> Map.get(session, "llm_params", @default_llm_params)
      _ -> @default_llm_params
    end
  end

  @doc """
  Update selected LLM
  """
  def update_selected_llm(report_id, llm_name) do
    case get_session(report_id) do
      {:ok, session} ->
        updated_session = Map.put(session, "selected_llm", llm_name)
        save_session(report_id, updated_session)
        {:ok, llm_name}

      {:error, :not_found} ->
        save_session(report_id, %{"selected_llm" => llm_name})
        {:ok, llm_name}
    end
  end

  @doc """
  Get selected LLM
  """
  def get_selected_llm(report_id) do
    case get_session(report_id) do
      {:ok, session} -> Map.get(session, "selected_llm", @default_selected_llm)
      _ -> @default_selected_llm
    end
  end

  @doc """
  Update verification degree
  """
  def update_verification_degree(report_id, degree) do
    valid_degrees = [
      "Keine Übereinstimmung",
      "Schwache Übereinstimmung",
      "Mittlere Übereinstimmung",
      "Starke Übereinstimmung",
      "Exakte Übereinstimmung"
    ]

    if degree in valid_degrees do
      # Convert display value to internal value
      internal_value = Map.get(@verification_degree_mappings, degree, :moderate_match)

      case get_session(report_id) do
        {:ok, session} ->
          # Store the internal atom value directly
          updated_session = Map.put(session, "verification_degree", internal_value)
          save_session(report_id, updated_session)
          {:ok, degree}

        {:error, :not_found} ->
          # Create new session with internal atom value
          save_session(report_id, %{"verification_degree" => internal_value})
          {:ok, degree}
      end
    else
      {:error, "Invalid verification degree: #{degree}"}
    end
  end

  @doc """
  Get verification degree - returns internal atom value
  """
  def get_verification_degree(report_id) do
    case get_session(report_id) do
      {:ok, session} ->
        # Get the stored internal atom value
        internal_value = Map.get(session, "verification_degree", @default_verification_degree)

        # Add debug logging to identify the retrieved value
        Logger.debug("Retrieved verification_degree from DB: #{inspect(internal_value)}")

        # Convert to proper atom value (handles different storage formats)
        normalized_value =
          cond do
            # When value is already an atom
            is_atom(internal_value) ->
              internal_value

            # When value is a string that looks like an atom (":moderate_match")
            is_binary(internal_value) && String.starts_with?(internal_value, ":") ->
              try do
                String.to_existing_atom(String.slice(internal_value, 1..-1))
              rescue
                _ -> @default_verification_degree
              end

            # When value is a string atom name without colon
            is_binary(internal_value) &&
                Enum.any?(Map.keys(@internal_to_display_mapping), fn key ->
                  to_string(key) == internal_value
                end) ->
              try do
                String.to_existing_atom(internal_value)
              rescue
                _ -> @default_verification_degree
              end

            # Legacy case - if a display string was stored, convert to internal value
            is_binary(internal_value) &&
                Map.has_key?(@verification_degree_mappings, internal_value) ->
              Map.get(@verification_degree_mappings, internal_value, @default_verification_degree)

            # Default case - use default value
            true ->
              @default_verification_degree
          end

        Logger.debug("Normalized to atom value: #{inspect(normalized_value)}")
        normalized_value

      _ ->
        @default_verification_degree
    end
  end

  @doc """
  Get verification degree display value for UI
  """
  def get_verification_degree_display(atom_value) when is_atom(atom_value) do
    Map.get(
      @internal_to_display_mapping,
      atom_value,
      Map.get(@internal_to_display_mapping, @default_verification_degree)
    )
  end

  def get_verification_degree_display(other_value) do
    # Handle case where we somehow got a non-atom value
    normalized_value = get_normalized_verification_degree(other_value)

    Map.get(
      @internal_to_display_mapping,
      normalized_value,
      Map.get(@internal_to_display_mapping, @default_verification_degree)
    )
  end

  # Helper to normalize verification degree to atom for legacy data
  defp get_normalized_verification_degree(value) do
    cond do
      is_atom(value) ->
        value

      is_binary(value) && Map.has_key?(@verification_degree_mappings, value) ->
        Map.get(@verification_degree_mappings, value, @default_verification_degree)

      true ->
        @default_verification_degree
    end
  end

  # Helper function to get the list of valid display degrees
  defp valid_degrees do
    [
      "Keine Übereinstimmung",
      "Schwache Übereinstimmung",
      "Mittlere Übereinstimmung",
      "Starke Übereinstimmung",
      "Exakte Übereinstimmung"
    ]
  end

  @doc """
  Set LLM initialization status for a report
  """
  def set_llm_initialized(report_id, initialized \\ true) do
    case get_session(report_id) do
      {:ok, session} ->
        # Update the llm_initialized flag in the existing session
        updated_session = Map.put(session, "llm_initialized", initialized)
        # Save the updated session
        save_session(report_id, updated_session)
        {:ok, initialized}

      {:error, :not_found} ->
        # Create a new session with just the llm_initialized flag
        save_session(report_id, %{"llm_initialized" => initialized})
        {:ok, initialized}
    end
  end

  def set_rag_initialized(report_id, initialized \\ true) do
    case get_session(report_id) do
      {:ok, session} ->
        # Update the rag_initialized flag in the existing session
        updated_session = Map.put(session, "rag_initialized", initialized)
        # Save the updated session
        save_session(report_id, updated_session)
        {:ok, initialized}

      {:error, :not_found} ->
        # Create a new session with just the rag_initialized flag
        save_session(report_id, %{"rag_initialized" => initialized})
        {:ok, initialized}
    end
  end

  @doc """
  Get LLM initialization status for a report
  """
  def get_llm_initialized(report_id) do
    case get_session(report_id) do
      {:ok, session} -> Map.get(session, "llm_initialized", false)
      _ -> false
    end
  end

  @doc """
  Reset LLM initialization status for a report
  This should be called before opening a report to ensure LLM is reinitialized if needed
  """
  def reset_initialization(report_id) do
    case get_session(report_id) do
      {:ok, session} ->
        # Update the llm_initialized flag to false in the existing session
        updated_session = Map.put(session, "llm_initialized", false)
        updated_session = Map.put(updated_session, "rag_initialized", false)
        # Save the updated session
        save_session(report_id, updated_session)
        {:ok, false}

      {:error, :not_found} ->
        # No session found, nothing to reset
        {:ok, false}
    end
  end
end
