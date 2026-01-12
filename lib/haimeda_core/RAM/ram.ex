defmodule RAM do
  alias LLMService
  alias RAM.PromptBuilder
  alias RAM.PromptBuilderHelpers, as: PBH
  alias HaimedaCore.GeneralHelperFunctions, as: GHF

  @llm_model "llama3_german_instruct_base"
  @llm_parameters %{
    temperature: 0.0,
    top_p: 0.5,
    top_k: 40,
    max_tokens: 4096,
    repeat_penalty: 1.2
  }

  def create_chapter(model_params, input_info) do
    prompt_key = "chapter_creation"

    chapter_num = input_info.chapter_num
    chapter_title = input_info.title
    meta_data = input_info.meta_data
    chapter_info = input_info.chapter_info
    previous_content = input_info.previous_content
    previous_content_mode = input_info.previous_content_mode

    # get raw from UI (string keys), normalize to atoms, then merge into defaults
    raw_llm_params = Map.get(model_params, :llm_params, %{})
    llm_params = Map.merge(@llm_parameters, raw_llm_params)
    model = Map.get(model_params, :selected_llm, @llm_model)

    IO.inspect(chapter_num, label: "Chapter Number")
    IO.inspect(chapter_title, label: "Chapter Title")
    IO.inspect(meta_data, label: "Meta Data")
    IO.inspect(chapter_info, label: "Chapter Info")
    IO.inspect(previous_content, label: "Previous content")
    IO.inspect(llm_params, label: "LLM Parameters")
    IO.inspect(model, label: "Model")

    chapter_creation_prompt =
      cond do
        previous_content != %{} ->
          PromptBuilder.create_prompt(prompt_key, input_info, previous_content_mode)

        true ->
          PromptBuilder.create_prompt(prompt_key, input_info, nil)
      end

    system_prompt = PBH.extract_prompt_element(prompt_key, "system_prompt")

    IO.inspect(chapter_creation_prompt, label: "Chapter Creation Prompt")

    # Call the LLM with the constructed prompt with retry logic
    response = query_with_retry(chapter_creation_prompt, model, llm_params, system_prompt)
    IO.inspect(response, label: "LLM Response")

    # Return the response
    response
  end

  def user_request_with_context(rag_config, user_request, context) do
    raw_llm_params = Map.get(rag_config, :llm_params, %{})
    llm_params = Map.merge(@llm_parameters, raw_llm_params)
    model = Map.get(rag_config, :selected_llm, @llm_model)

    input_info = %{
      user_request: user_request,
      result_type: context.status,
      mdb_results: context.mdb_results,
      vector_results: context.vector_results
    }

    prompt_key = "user_request"
    prompt = PromptBuilder.create_prompt(prompt_key, input_info, :with_context)
    IO.inspect(prompt, label: "Prompt", limit: :infinity)
    system_prompt = PBH.extract_prompt_element(prompt_key, "system_prompt")

    response = query_with_retry(prompt, model, llm_params, system_prompt)
    IO.inspect(response, label: "LLM Response")
    response
  end

  def user_request_without_context(rag_config, user_request) do
    raw_llm_params = Map.get(rag_config, :llm_params, %{})
    llm_params = Map.merge(@llm_parameters, raw_llm_params)
    model = Map.get(rag_config, :selected_llm, @llm_model)

    IO.inspect(model, label: "Selected LLM")

    input_info = %{
      user_request: user_request,
      context: nil
    }

    prompt_key = "user_request"
    prompt = PromptBuilder.create_prompt(prompt_key, input_info, :no_context)
    IO.inspect(prompt, label: "Prompt")
    system_prompt = PBH.extract_prompt_element(prompt_key, "system_prompt")

    response = query_with_retry(prompt, model, llm_params, system_prompt)
    IO.inspect(response, label: "LLM Response")
    response
  end

  def optimize_text(model_params, textarea_content) do
    raw_llm_params = Map.get(model_params, :llm_params, %{})
    llm_params = Map.merge(@llm_parameters, raw_llm_params)
    model = Map.get(model_params, :selected_llm, @llm_model)

    IO.inspect(llm_params, label: "Model Parameters")
    IO.inspect(model, label: "Model")

    prompt_key = "text_optimization"
    prompt = PromptBuilder.create_prompt(prompt_key, textarea_content, nil)
    IO.inspect(prompt, label: "Prompt")
    system_prompt = PBH.extract_prompt_element(prompt_key, "system_prompt")

    response = query_with_retry(prompt, model, llm_params, system_prompt)
    IO.inspect(response, label: "LLM Response")
    response
  end

  def revise_text(model_params, input_info) do
    raw_llm_params = Map.get(model_params, :llm_params, %{})
    llm_params = Map.merge(@llm_parameters, raw_llm_params)
    model = Map.get(model_params, :selected_llm, @llm_model)
    IO.inspect(llm_params, label: "Model Parameters")
    IO.inspect(model, label: "Model")

    prompt_key = "text_revision"

    prompt = PromptBuilder.create_prompt(prompt_key, input_info, nil)
    IO.inspect(prompt, label: "Prompt")
    system_prompt = PBH.extract_prompt_element(prompt_key, "system_prompt")

    response = query_with_retry(prompt, model, llm_params, system_prompt)
    IO.inspect(response, label: "LLM Response")
    response
  end

  def summarize_text(model_params, content) do
    raw_llm_params = Map.get(model_params, :llm_params, %{})
    llm_params = Map.merge(@llm_parameters, raw_llm_params)
    model = Map.get(model_params, :selected_llm, @llm_model)
    IO.inspect(llm_params, label: "Model Parameters")
    IO.inspect(model, label: "Model")

    prompt_key = "text_summarization"
    prompt = PromptBuilder.create_prompt(prompt_key, content, nil)
    IO.inspect(prompt, label: "Prompt")
    system_prompt = PBH.extract_prompt_element(prompt_key, "system_prompt")
    response = query_with_retry(prompt, model, llm_params, system_prompt)
    IO.inspect(response, label: "LLM Response")
    response
  end

  def verify_LLM_response_quality(response) do
    # Check for BEISPIEL in uppercase - this covers all BEISPIEL variations
    contains_beispiel = String.contains?(response, "BEISPIEL")

    # List of specific fragments that indicate a malformed response
    unwanted_fragments = [
      "INST",
      "TEXT BEGINN",
      "OPTIMIERTER TEXT BEGINN",
      "ZUSAMMENFASSUNG BEGINN",
      "ÜBERARBEITETER TEXT BEGINN",
      "FEHLENDE INFORMATIONEN BEGINN",
      "FEHLENDE INFORMATIONEN ENDE",
      "VORHERIGE INHALTE",
      "ENDE VORHERIGE INHALTE",
      "KAPITELZUSAMMENFASSUNG",
      "ZUSAMMENFASSUNG VON KAPITEL",
      "ZUSAMMENFASSUNG VORHERIGE INHALTE",
      "ENDE ZUSAMMENFASSUNG VORHERIGE INHALTE",
      "KAPITELINHALTE",
      "ENDE KAPITELINHALTE",
      "METADATEN",
      "ENDE METADATEN"
    ]

    # Check if any unwanted fragment exists in the response
    # For each fragment, check both [fragment] and [/fragment] versions
    contains_unwanted_fragment =
      contains_beispiel ||
        Enum.any?(unwanted_fragments, fn fragment ->
          String.contains?(response, "[#{fragment}]") ||
            String.contains?(response, "[/#{fragment}]")
        end)

    # Return false if any unwanted fragment is found
    !contains_unwanted_fragment
  end

  # Wrapper for LLMService.query with retry logic
  defp query_with_retry(prompt, model, llm_params, system_prompt, max_retries \\ 2) do
    do_query_with_retry(prompt, model, llm_params, system_prompt, max_retries, 0)
  end

  defp do_query_with_retry(_prompt, _model, _llm_params, _system_prompt, max_retries, attempt)
       when attempt > max_retries do
    # We've exhausted all retry attempts, return empty string
    ""
  end

  defp do_query_with_retry(prompt, model, llm_params, system_prompt, max_retries, attempt) do
    # get remote config
    remote_config = GHF.get_remote_config()
    IO.inspect(remote_config, label: "Remote Config")
    # Make the query
    response = LLMService.query(prompt, model, remote_config, llm_params, system_prompt)

    IO.inspect(response, label: "RAW LLM Response Attempt #{attempt + 1}")
    # Verify the response quality
    if verify_LLM_response_quality(response) do
      # Response is good, sanitize and return it
      sanitize_response(response)
    else
      # Response has issues, retry
      IO.puts("LLM response quality check failed. Retrying (#{attempt + 1}/#{max_retries})...")
      do_query_with_retry(prompt, model, llm_params, system_prompt, max_retries, attempt + 1)
    end
  end

  def sanitize_response(response) do
    # Remove noisy bracket-only lines and common header/footer tokens
    lines = String.split(response, "\n")

    filtered_lines =
      lines
      |> Enum.reject(fn line ->
        (Enum.at(lines, 0) == line && String.starts_with?(line, "Kapitel")) ||
          String.match?(line, ~r/^\s*\[.*\]\s*$/) ||
          String.match?(line, ~r/^\s*\[.*\]/) ||
          String.match?(line, ~r/\[.*\]\s*$/) ||
          String.contains?(line, "OPTIMIERT") ||
          String.contains?(line, "ÜBERARBEITET") ||
          String.contains?(line, "ZUSAMMENFASSUNG") ||
          String.contains?(line, "TEXT") ||
          String.contains?(line, "INHALT") ||
          String.contains?(line, "KAPITEL") ||
          String.contains?(line, "ANTWORT") ||
          String.contains?(line, "KONTEXT")
      end)

    cleaned_response =
      filtered_lines
      |> Enum.join("\n")
      |> String.trim()
      |> unescape_symbols()
      |> remove_special_cases()
  end

  defp remove_special_cases(text) do
    text
    |> String.replace(~r/[A-Z]\.\s/, "")
  end

  # Unescape common escaped symbols in the response
  defp unescape_symbols(text) do
    text
    |> String.replace("\\\"", "")
    |> String.replace("\\\\", "\\")
    |> String.replace("\\n", "\n")
    |> String.replace("\\t", "\t")
  end
end
