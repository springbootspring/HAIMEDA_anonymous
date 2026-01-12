defmodule LLMService do
  @moduledoc """
  A service module for interacting with Language Learning Models.
  Provides an interface to the PromptBuilder functionality.
  """

  require Logger
  alias LLMService.PromptBuilder
  alias OllamaService
  alias LangChain.Message
  alias HaimedaCore.GeneralHelperFunctions, as: GHF

  # Default LLM parameters, used when no specific parameters are provided or a missing or wrong parameter is given.
  @default_parameters %{
    temperature: 0.1,
    top_p: 0.4,
    top_k: 60,
    max_tokens: 4096,
    repeat_penalty: 1.2
  }

  # Available models
  @available_models [
    "llama3_german_instruct",
    "llama3_german_instruct_ft_stage1",
    "llama3_german_instruct_ft_stage1_q8_0",
    "llama3.2:3b-instruct-fp16",
    "leo_mistral_german",
    "leo_llama_german_13b_q8",
    "llama3_german_instruct_ft_stage_d",
    "nomic-embed-text",
    "all-minilm",
    "jina-embeddings-v2",
    "llama3_german_v3",
    "llama3_german_V1-B"
  ]

  @doc """
  Initialize an Ollama client.
  """
  def init_client(ollama_server_url \\ nil) do
    case ollama_server_url do
      nil ->
        Ollama.init()

      ollama_server_url ->
        Ollama.init(ollama_server_url)
    end
  end

  @doc """
  Reset the LLM context by unloading and preloading the model.
  """
  def reset_llm_context(client, model) do
    unload_result = Ollama.unload(client, model: model)

    case unload_result do
      {:ok, _response} ->
        IO.puts("Successfully unloaded model: #{model}")

        case Ollama.preload(client, model: model) do
          {:ok, _} ->
            IO.puts("Successfully preloaded model: #{model}")
            :ok

          {:error, reason} ->
            IO.puts("Warning: Failed to preload LLM model: #{inspect(reason)}")
            :error
        end

      {:error, reason} ->
        IO.puts("Warning: Failed to unload LLM model: #{inspect(reason)}")

        case Ollama.preload(client, model: model) do
          {:ok, _} ->
            IO.puts("Successfully preloaded model: #{model}")
            :ok

          {:error, preload_reason} ->
            IO.puts("Warning: Failed to preload LLM model: #{inspect(preload_reason)}")
            :error
        end
    end
  end

  @doc """
  Process a request with an LLM.

  @doc \"""
  Process a request with the LLM using a message set.
  """
  def process_request(client, remote, message_set, model, parameters \\ %{})
      when is_list(message_set) do
    # Validate model - skip validation for remote servers
    validated_model = if remote, do: model, else: verify_model_existence(model)

    IO.inspect(validated_model, label: "Using Model")
    merged_params = %{options: Map.merge(@default_parameters, parameters)}

    IO.inspect(merged_params, label: "Merged Parameters")
    # Process with retries
    process_with_retries(client, message_set, validated_model, merged_params, 3)
  end

  def verify_model_existence(model) do
    case OllamaService.pull_model_if_not_available(model) do
      {:ok, model_name} ->
        IO.puts("Using Model: \"#{model_name}\"")
        model_name

      {:error, :model_not_available} ->
        IO.puts("\nModel #{model} is not available.")

        most_similar =
          Enum.reduce(@available_models, {"", 0}, fn available_model, {best_match, best_score} ->
            similarity =
              String.jaro_distance(String.downcase(model), String.downcase(available_model))

            if similarity > best_score,
              do: {available_model, similarity},
              else: {best_match, best_score}
          end)

        {similar_model, _score} = most_similar
        IO.puts("Using similar model instead: #{similar_model}")
        similar_model
    end
  end

  @doc """
  Send a simple query to the LLM and get a response.
  """
  def query(query, model, remote_config, parameters \\ %{}, system_prompt \\ nil) do
    messages =
      if system_prompt do
        [
          %Message{role: "system", content: system_prompt},
          %Message{role: "user", content: query}
        ]
      else
        [
          %Message{role: "user", content: query}
        ]
      end

    # Count tokens for logging
    token_info = PromptBuilder.count_words_and_tokens(messages)

    IO.puts(
      "\nWord count: #{token_info.word_count}, Estimated tokens: #{token_info.estimated_tokens}"
    )

    {ollama_server_url, remote} =
      case remote_config.use_remote_ollama_models do
        true ->
          # Use remote Ollama models
          Logger.info("Using remote Ollama models")
          {Map.get(remote_config, :ollama_server_url, nil), true}

        false ->
          # Use local models
          Logger.info("Using local models")
          {nil, false}
      end

    client = get_ollama_client(ollama_server_url)
    # IO.inspect(client, label: "Ollama Client")
    process_request(client, remote, messages, model, parameters)
  end

  @doc """
  Use a predefined prompt from a JSON prompt file to query the LLM.

  @doc \"""
  Query the LLM using a prompt template from a JSON file.
  """
  def query_with_prompt(
        prompt_file,
        prompt_key,
        variables,
        model,
        system_prompt_key \\ nil,
        parameters \\ %{}
      ) do
    client = get_ollama_client()

    # Create user message
    user_message = PromptBuilder.create_user_message(prompt_file, prompt_key, variables)

    messages =
      if system_prompt_key do
        system_message =
          PromptBuilder.create_system_message(prompt_file, system_prompt_key, variables)

        if system_message, do: [system_message, user_message], else: [user_message]
      else
        [user_message]
      end

    # Count tokens for logging
    token_info = PromptBuilder.count_words_and_tokens(messages)

    IO.puts(
      "\nWord count: #{token_info.word_count}, Estimated tokens: #{token_info.estimated_tokens}"
    )

    process_request(client, messages, model, parameters)
  end

  # Private function to process with retries and timeout
  defp process_with_retries(client, message_set, model, parameters, attempts_left)
       when attempts_left > 0 do
    # Convert the message set to the format expected by Ollama
    ollama_messages =
      Enum.map(message_set, fn msg ->
        %{
          role: msg.role,
          content: msg.content
        }
      end)

    IO.inspect(ollama_messages, label: "Messages for Ollama")
    IO.inspect(parameters, label: "Parameters for Ollama")

    {task, timeout} =
      if GHF.get_remote_config().use_remote_ollama_models do
        {Task.async(fn ->
           make_direct_ollama_request(client, model, ollama_messages, parameters.options)
         end), 90_000}
      else
        {Task.async(fn ->
           Ollama.chat(client,
             model: model,
             messages: ollama_messages,
             options: parameters.options
           )
         end), 60_000}
      end

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {:ok, response}} ->
        # Successful response within timeout
        response["message"]["content"]

      {:ok, {:error, reason}} ->
        # Error occurred but within timeout
        IO.puts("LLM processing error: #{inspect(reason)}. Attempts left: #{attempts_left - 1}")
        # Add a delay before retrying to avoid rapid retry cycles
        # :timer.sleep(5_000)
        process_with_retries(client, message_set, model, parameters, attempts_left - 1)

      nil ->
        # Timeout occurred (task was shut down)
        IO.puts("LLM processing timeout. Attempts left: #{attempts_left - 1}")
        process_with_retries(client, message_set, model, parameters, attempts_left - 1)

      {:exit, reason} ->
        # Handle task exit explicitly
        IO.puts("LLM task exited: #{inspect(reason)}. Attempts left: #{attempts_left - 1}")
        :timer.sleep(5_000)
        process_with_retries(client, message_set, model, parameters, attempts_left - 1)

      _ ->
        # Any other unexpected result
        IO.puts("Unexpected error in LLM processing. Attempts left: #{attempts_left - 1}")
        :timer.sleep(5_000)
        process_with_retries(client, message_set, model, parameters, attempts_left - 1)
    end
  end

  defp process_with_retries(_client, _message_set, _model, _parameters, 0) do
    IO.puts("Maximum LLM processing attempts reached. Returning error placeholder.")
    "ERROR IN PROCESSING"
  end

  @doc """
  Generate embeddings from content using the specified model
  """
  # Header function declaration with default value
  def generate_embeddings(content, model_name \\ "nomic-embed-text")

  # Implementation for binary content
  def generate_embeddings(content, model_name) when is_binary(content) do
    # Use module attribute for client to avoid recreating for each call
    client = get_ollama_client()

    case Ollama.embeddings(client, model: model_name, prompt: content) do
      {:ok, %{"embedding" => embedding}} ->
        # Return the embedding vector directly, not wrapped in {:ok, embedding}
        embedding

      {:error, reason} ->
        Logger.error("Failed to generate embedding: #{inspect(reason)}")
        # Return empty vector on error for graceful handling
        []
    end
  end

  # Implementation for list content
  def generate_embeddings(content_list, model_name) when is_list(content_list) do
    Enum.map(content_list, &generate_embeddings(&1, model_name))
  end

  # Accepts optional ollama_server_url, uses it if provided, else uses default.
  defp get_ollama_client(ollama_server_url \\ nil) do
    case Process.get({:ollama_client, ollama_server_url}) do
      nil ->
        client = init_client(ollama_server_url)
        Process.put({:ollama_client, ollama_server_url}, client)
        client

      existing_client ->
        existing_client
    end
  end

  @doc """
  Parse LLM response into list items based on newline patterns.
  """
  def parse_response_to_list_items(response) when is_binary(response) do
    items = Regex.split(~r/\n\s*(?=[A-Z]\.|[0-9]+\.)/, response, trim: true)

    items
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn item ->
      cond do
        # If item already starts with letter/number and period, keep as is
        Regex.match?(~r/^[A-Z]\.|^[0-9]+\./, item) -> item
        # Otherwise, it's likely a continuation or separate point
        true -> item
      end
    end)
    |> Enum.reject(fn item -> item == "" end)
  end

  @doc """
  Constructs a prompt using a template and variables by delegating to PromptBuilder.

  @doc \"""
  Constructs a prompt using a template and variables from a JSON file.
  """
  def construct_prompt(prompt_file, template_key, variables \\ %{}) do
    PromptBuilder.construct_prompt(prompt_file, template_key, variables)
  end

  @doc """
  Normalize llm parameters: string keys -> atom keys.
  """
  def normalize_llm_params(params) when is_map(params) do
    params
    |> Enum.reduce(%{}, fn
      {k, v}, acc when is_binary(k) ->
        atom_key =
          try do
            String.to_existing_atom(k)
          rescue
            _ -> String.to_atom(k)
          end

        Map.put(acc, atom_key, v)

      _, acc ->
        acc
    end)
  end

  def verify_and_integrate_local_models(models, overwrite) do
    # Format the default parameters as Modelfile directives

    IO.inspect(overwrite, label: "Overwrite")
    # Integrate each model in the list
    results =
      Enum.map(models, fn model_path ->
        case OllamaService.integrate_gguf_in_ollama(model_path, overwrite, @default_parameters) do
          {:ok, message} ->
            IO.puts("Successfully integrated model: #{model_path}")
            {:ok, model_path}

          {:error, reason} ->
            IO.puts("Failed to integrate model #{model_path}: #{inspect(reason)}")
            {:error, model_path, reason}
        end
      end)

    # Check if all models were integrated successfully
    if Enum.all?(results, fn result -> match?({:ok, _}, result) end) do
      {:ok, "All models integrated successfully"}
    else
      failed_models = Enum.filter(results, fn result -> match?({:error, _, _}, result) end)
      failure_count = length(failed_models)
      {:error, "Failed to integrate #{failure_count} models"}
    end
  end

  def count_words_and_tokens(messages) do
    PromptBuilder.count_words_and_tokens(messages)
  end

  def count_words_and_tokens_records(records, type) do
    case type do
      :vector ->
        PromptBuilder.count_words_and_tokens_vector(records)

      :mdb ->
        PromptBuilder.count_words_and_tokens_mdb(records)
    end
  end

  # Make direct HTTP request to Ollama API
  defp make_direct_ollama_request(client, model, messages, options) do
    base_url =
      case client do
        %{req: %{options: %{base_url: url}}} -> url
        _ -> "http://localhost:11434"
      end

    url = "#{base_url}/api/chat"

    body = %{
      model: model,
      messages: messages,
      stream: false,
      options: options
    }

    headers = [
      {"Content-Type", "application/json"},
      {"Accept", "application/json"}
    ]

    case HTTPoison.post(url, Jason.encode!(body), headers, timeout: 90_000, recv_timeout: 90_000) do
      {:ok, %HTTPoison.Response{status_code: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, decoded} ->
            # Format response to match Ollama library format
            {:ok, %{"message" => %{"content" => decoded["message"]["content"]}}}

          {:error, _} ->
            {:error, "Failed to decode response"}
        end

      {:ok, %HTTPoison.Response{status_code: status_code, body: error_body}} ->
        {:error, "HTTP #{status_code}: #{error_body}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end
end
