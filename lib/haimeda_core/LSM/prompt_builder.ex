defmodule LLMService.PromptBuilder do
  @moduledoc """
  This module handles the creation of prompts for LLMs, requested by other specialized modules.
  """

  alias LangChain.Message
  alias LangChain.PromptTemplate

  @doc """
  Extracts content from a JSON prompt file based on the provided key.
  """
  def extract_prompt_element(prompt_file, key) do
    try do
      case File.read(prompt_file) do
        {:ok, elements_json} ->
          case Jason.decode(elements_json) do
            {:ok, elements} ->
              Map.get(elements, key)

            {:error, reason} ->
              IO.puts(
                "Error decoding prompt elements JSON from #{prompt_file}: #{inspect(reason)}"
              )

              nil
          end

        {:error, reason} ->
          IO.puts("Error reading prompt file at #{prompt_file}: #{inspect(reason)}")
          nil
      end
    rescue
      e ->
        IO.puts("Exception while extracting prompt element: #{inspect(e)}")
        nil
    end
  end

  @doc """
  Constructs a prompt using a template and variables.
  """
  def construct_prompt(prompt_file, template_key, variables \\ %{}) do
    template_content = extract_prompt_element(prompt_file, template_key)

    case template_content do
      nil ->
        {:error, "Template not found"}

      content when is_binary(content) ->
        case PromptTemplate.from_template(content) do
          {:ok, template} ->
            try do
              PromptTemplate.format(template, variables)
            rescue
              e ->
                IO.puts("Error formatting template: #{inspect(e)}")
                {:error, "Error formatting template"}
            end

          {:error, reason} ->
            {:error, "Error creating template: #{inspect(reason)}"}
        end

      _ ->
        {:error, "Invalid template format"}
    end
  end

  @doc """
  Creates a system message from a prompt template.
  """
  def create_system_message(prompt_file, system_prompt_key, variables \\ %{}) do
    case construct_prompt(prompt_file, system_prompt_key, variables) do
      {:ok, content} ->
        %Message{role: "system", content: content}

      _ ->
        nil
    end
  end

  @doc """
  Creates a user message from a prompt template.
  """
  def create_user_message(prompt_file, user_prompt_key, variables \\ %{}) do
    case construct_prompt(prompt_file, user_prompt_key, variables) do
      {:ok, content} ->
        %Message{role: "user", content: content}

      _ ->
        nil
    end
  end

  @doc """
  Counts words and estimates tokens in a message or text.
  """
  def count_words_and_tokens(text) when is_binary(text) do
    # Split by whitespace to count words
    words = text |> String.split(~r/\s+/, trim: true)
    word_count = length(words)

    # Count characters that likely become separate tokens
    special_chars =
      text
      |> String.graphemes()
      |> Enum.count(&(&1 =~ ~r/[.,;:!?()[\]{}""„"—–\-\/@#$%^&*=+]|[0-9]/))

    # Estimate tokens from words (using an average factor for German)
    base_token_estimate =
      words
      |> Enum.map(fn word ->
        cond do
          String.length(word) <= 1 -> 1
          String.length(word) <= 4 -> 1.1
          String.length(word) <= 8 -> 1.5
          String.length(word) <= 15 -> String.length(word) / 4.2
          String.length(word) > 15 -> String.length(word) / 4.5
        end
      end)
      |> Enum.sum()
      |> round()

    # Add special character tokens to the base estimate
    estimated_tokens = base_token_estimate + special_chars

    %{
      word_count: word_count,
      estimated_tokens: estimated_tokens
    }
  end

  # Handle Message structs list
  def count_words_and_tokens(messages) when is_list(messages) do
    # Extract content from each message and concatenate
    combined_text =
      messages
      |> Enum.map(fn
        %LangChain.Message{content: content} when is_binary(content) -> content
        %{content: content} when is_binary(content) -> content
        _ -> ""
      end)
      |> Enum.join(" ")

    # Process the combined text
    count_words_and_tokens(combined_text)
  end

  # Handle non-binary input
  def count_words_and_tokens(nil), do: %{word_count: 0, estimated_tokens: 0}
  def count_words_and_tokens(_), do: %{word_count: 0, estimated_tokens: 0}

  def count_words_and_tokens_mdb(records) do
    if is_nil(records) do
      %{word_count: 0, estimated_tokens: 0, char_count: 0}
    else
      records_string = stringify_mdb_records(records)
      words_and_tokens = count_words_and_tokens(records_string)

      %{
        word_count: words_and_tokens.word_count,
        estimated_tokens: words_and_tokens.estimated_tokens,
        char_count: String.length(records_string)
      }
    end
  end

  # Helper function to convert MDB records to string with proper handling of nested structures
  defp stringify_mdb_records(records) do
    cond do
      is_map(records) ->
        # Process a map of tables to rows
        Enum.map(records, fn {table, rows} ->
          table_str = "#{table}: "

          rows_str =
            if is_list(rows) do
              # Handle list of rows (common case)
              Enum.map_join(rows, "\n", fn row -> stringify_mdb_row(row) end)
            else
              # Handle non-list values (edge case)
              stringify_mdb_row(rows)
            end

          "#{table_str}#{rows_str}"
        end)
        |> Enum.join("\n\n")

      is_list(records) ->
        # Process a list of records directly
        Enum.map_join(records, "\n", &stringify_mdb_row/1)

      true ->
        # Fallback for other types
        inspect(records)
    end
  end

  # Helper to stringify a single row/record
  defp stringify_mdb_row(row) do
    cond do
      is_map(row) ->
        # Convert map to "key: value" pairs
        Enum.map_join(row, ", ", fn {k, v} -> "#{k}: #{inspect(v)}" end)

      is_tuple(row) and tuple_size(row) == 2 ->
        # Handle key-value tuples
        {k, v} = row
        "#{k}: #{inspect(v)}"

      true ->
        # Any other value
        inspect(row)
    end
  end

  def count_words_and_tokens_vector(records) do
    if is_nil(records) do
      %{word_count: 0, estimated_tokens: 0, char_count: 0}
    else
      # Extract "text" and "chapter_name" values from each record and combine
      combined_text =
        Enum.map(records, fn record ->
          text = Map.get(record, "text", "")
          chapter_name = Map.get(record, "chapter_name", "")
          "#{chapter_name}\n#{text}"
        end)
        |> Enum.join("\n")

      # Get word and token counts
      words_and_tokens = count_words_and_tokens(combined_text)

      # Return the metrics with character count added
      %{
        word_count: words_and_tokens.word_count,
        estimated_tokens: words_and_tokens.estimated_tokens,
        char_count: String.length(combined_text)
      }
    end
  end
end
