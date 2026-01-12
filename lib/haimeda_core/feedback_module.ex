defmodule HaimedaCore.FeedbackModule do
  @moduledoc """
  Module for handling and processing feedback from various system components.
  """

  def process_postprocessor_result(scores) do
    # Format percentages with one decimal place
    formatted_scores = %{
      input_coverage: format_percentage(scores.input_coverage_percentage),
      output_coverage: format_percentage(scores.output_coverage_percentage),
      overall_coverage: format_percentage(scores.overall_coverage_percentage),
      input_score: format_decimal(scores.input_weighted_content_score),
      output_score: format_decimal(scores.output_weighted_content_score),
      overall_score: format_decimal(scores.overall_weighted_content_score)
    }

    # Create a status message for the verification result
    status_message = "Post-Processor: Verifikation des Kapitelinhalts erfolgreich abgeschlossen"

    # Create a detailed chat message with the formatted scores
    chat_message = """
    Ich habe den Kapitelinhalt verifiziert. Hier ist das Ergebnis:

    • Abdeckung der Eingabeinhalte: #{formatted_scores.input_coverage}%
    • Abdeckung der Ausgabeinhalte: #{formatted_scores.output_coverage}%
    • Gesamtabdeckung: #{formatted_scores.overall_coverage}%

    • Gewichtete Bewertung der Eingabeinhalte: #{formatted_scores.input_score}/10
    • Gewichtete Bewertung der Ausgabeinhalte: #{formatted_scores.output_score}/10
    • Gesamtbewertung: #{formatted_scores.overall_score}/10

    """

    {status_message, chat_message}
  end

  # Helper function to format percentage with one decimal place
  defp format_percentage(value) when is_float(value) do
    :erlang.float_to_binary(value, decimals: 1)
  end

  defp format_percentage(value) when is_integer(value) do
    "#{value}.0"
  end

  # Helper function to format decimal with one decimal place
  defp format_decimal(value) when is_float(value) do
    :erlang.float_to_binary(value, decimals: 1)
  end

  defp format_decimal(value) when is_integer(value) do
    "#{value}.0"
  end

  @doc """
  Process feedback from IIV pre-processing and send it to the appropriate channels.

  Returns a tuple {has_red_feedback, status_message, parsed_feedback} where:
  - has_red_feedback: boolean indicating if there's any critical (red) feedback
  - status_message: message for status log
  - parsed_feedback: list of feedback messages with their colors for live chat
  """

  def process_iiv_feedback({:ok, {_condition_strings, feedback_messages}}) do
    # Extract feedback message-color pairs
    parsed_feedback = parse_feedback_messages(feedback_messages)

    # Check if any feedback has "red" as color
    has_red_feedback = Enum.any?(parsed_feedback, fn {_message, color} -> color == "red" end)

    # Determine status message based on presence of red feedback
    status_message =
      if has_red_feedback do
        "Pre-Processor: Essenzielle Details zur automatischen Kapitelerstellung fehlen"
      else
        "Pre-Processor: Starte Kapitelerstellung mit LLM"
      end

    {has_red_feedback, status_message, parsed_feedback}
  end

  def process_iiv_feedback(_), do: {true, "Fehler bei der Vorverarbeitung aufgetreten", []}

  @doc """
  Parses the feedback messages from IIV format into a more usable format.
  Returns a list of {message, color} tuples.
  """
  def parse_feedback_messages(feedback_messages) do
    feedback_messages
    |> Enum.chunk_every(2)
    |> Enum.filter(fn chunk -> length(chunk) == 2 end)
    |> Enum.map(fn [message, color] -> {message, color} end)
  end

  @doc """
  Sends feedback to the LiveView process for display in status log and live chat.
  """
  def send_feedback_to_ui(pid, status_message, feedback_items, type \\ "info") when is_pid(pid) do
    # Send status message to status log
    send_status_message(pid, status_message, type)

    # Only send feedback to chat if there are items
    if length(feedback_items) > 0 do
      # Format the feedback items with an introduction and properly formatted list with HTML
      introduction = "<strong>Ergebnisse des Pre-Processors:</strong>"
      formatted_items = format_feedback_as_html_list(feedback_items)

      # Combine with proper spacing for better readability
      complete_message = "#{introduction}<br><br>#{formatted_items}"

      # Send as a single symbolic_ai message
      send_chat_message(pid, complete_message, "symbolic_ai")
    end
  end

  @doc """
  Formats feedback items as an HTML list with proper color styling
  """
  def format_feedback_as_html_list(feedback_items) do
    items_html =
      feedback_items
      |> Enum.map(fn {message, color} ->
        # Map feedback colors to proper HTML colors
        html_color =
          case color do
            # Bright red
            "red" -> "#ff4d4d"
            # Bright orange
            "orange" -> "#ff9933"
            # Bright yellow
            "yellow" -> "#ffcc00"
            # Bright green
            "green" -> "#66cc66"
            # Default gray
            _ -> "#808080"
          end

        # Return a list item with colored text
        "<li style=\"color: #{html_color}; margin-bottom: 8px;\">#{message}</li>"
      end)
      |> Enum.join("\n")

    "<ul style=\"padding-left: 20px; list-style-type: disc;\">\n#{items_html}\n</ul>"
  end

  @doc """
  Formats feedback items as a simple text-based list (for non-HTML contexts)
  """
  def format_feedback_as_list(feedback_items) do
    feedback_items
    |> Enum.map(fn {message, color} ->
      "- #{message}"
    end)
    |> Enum.join("\n")
  end

  @doc """
  Utility function to send a single status log message
  """
  def send_status_message(pid, message, type \\ "info") when is_pid(pid) do
    send(pid, {:add_log, %{message: message, type: type, timestamp: DateTime.utc_now()}})
  end

  @doc """
  Utility function to send a chat message
  """
  # Valid senders: "system", "user", "symbolic_ai", "sub-symbolic_ai", "hybrid_ai"
  def send_chat_message(pid, content, sender \\ "system") when is_pid(pid) do
    send(
      pid,
      {:add_chat_message,
       %{
         sender: sender,
         content: content,
         timestamp: DateTime.utc_now()
       }}
    )
  end

  def set_loading_message(pid, message) do
    send(pid, {:loading_message, message})
  end
end
