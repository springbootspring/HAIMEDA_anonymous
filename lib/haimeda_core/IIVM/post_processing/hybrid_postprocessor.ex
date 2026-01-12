defmodule PostProcessing.HybridPostProcessor do
  @moduledoc """
  The HybridPostProcessor module is responsible for post-processing the output of the AI model.
  It combines symbolic reasoning with sub-symbolic AI to ensure the generated content is coherent and meets the required standards.
  """

  alias PostProcessing.{
    SymbolicEntityConstructor,
    VerificationStateManager,
    VerificationSupervisor,
    HybridVerificationEngine
  }

  require Logger

  @doc """
  Post-processes the output from the AI model using both symbolic and sub-symbolic methods.
  Parameters:
  input = %{
        output_num: output_num,
        title: output_title,
        meta_data: meta_data,
        output_info: output_info,
        previous_outputs: previous_outputs
      }
  """
  def post_process_llm_output(
        device_and_basic_meta_data,
        chapter_info,
        previous_content,
        parties_statements,
        llm_outputs,
        verifier_config
      ) do
    # 1. Initialize the Agents of the VerificationStateManager
    if Process.whereis(PostProcessing.VerificationSupervisor) do
      case DynamicSupervisor.start_child(
             VerificationSupervisor,
             {VerificationStateManager,
              [llm_output: llm_outputs, max_runs: verifier_config.verification_count]}
           ) do
        {:ok, pid} ->
          try do
            number_runs = Map.get(verifier_config, :verification_count, 1)

            # Ensure llm_outputs is always a list
            outputs = if is_list(llm_outputs), do: llm_outputs, else: [llm_outputs]

            # Process each output and run the verification once at the end
            outputs
            |> Enum.with_index(1)
            |> Enum.each(fn {llm_output, index} ->
              # 2. label all content
              labeled_content =
                [
                  {device_and_basic_meta_data, :input, :meta_data},
                  {chapter_info, :input, :chapter_info},
                  {previous_content, :input, :previous_content},
                  {parties_statements, :input, :parties_statements},
                  {llm_output, :output, :llm_output}
                ]
                |> Enum.filter(fn {content, _type, _label} -> content != nil end)

              # 3. Detect entities in all inputs and outputs
              {input_pattern_entities, output_pattern_entities} =
                SymbolicEntityConstructor.detect_all_patterns(labeled_content)

              # 4. Get and combine raw content of input and output
              {combined_input_content, combined_output_content} =
                SymbolicEntityConstructor.get_combined_content(labeled_content)

              # 5. Update the VerificationStateManager with the detected entities and content
              VerificationStateManager.add_input_entities(input_pattern_entities)
              VerificationStateManager.add_output_entities(output_pattern_entities)
              VerificationStateManager.add_input_combined_content(combined_input_content)
              VerificationStateManager.add_output_combined_content(combined_output_content)

              # Only prepare next run if we have more outputs to process
              if index < length(outputs) do
                VerificationStateManager.prepare_next_run()
              end
            end)

            VerificationStateManager.reset_run_count()
            results = HybridVerificationEngine.start_verification(pid, :auto, verifier_config)
            # 5. Return the result
            case results do
              {:ok, ordered_results} -> {:ok, :auto_results, ordered_results}
              {:error, reason} -> {:error, reason}
              {:error, reason, scores} -> {:error, reason, scores, llm_outputs}
              _ -> {:ok}
            end
          rescue
            e ->
              Logger.error("Error during verification: #{inspect(e)}")
              Logger.error("#{Exception.format(:error, e, __STACKTRACE__)}")
              {:error, "Verification failed: #{inspect(e)}", llm_outputs}
          end

        {:error, reason} ->
          Logger.error("Failed to start VerificationStateManager: #{inspect(reason)}")
          {:error, reason}
      end
    else
      Logger.error("VerificationSupervisor is not running. Cannot proceed with verification.")
      # Return a fallback value or raise a more specific error
      {:error, :supervisor_not_available}
    end
  end

  def post_process_textarea_content(
        device_and_basic_meta_data,
        chapter_info,
        previous_content,
        parties_statements,
        textarea_content,
        verifier_config
      ) do
    # 1. Initialize the Agents of the VerificationStateManager
    if Process.whereis(PostProcessing.VerificationSupervisor) do
      case DynamicSupervisor.start_child(
             VerificationSupervisor,
             {VerificationStateManager, [llm_output: textarea_content, max_runs: 1]}
           ) do
        {:ok, pid} ->
          try do
            # 2. label all content
            labeled_content =
              [
                {device_and_basic_meta_data, :input, :meta_data},
                {chapter_info, :input, :chapter_info},
                {previous_content, :input, :previous_content},
                {parties_statements, :input, :parties_statements},
                {textarea_content, :output, :textarea_content}
              ]
              |> Enum.filter(fn {content, _type, _label} -> content != nil end)

            # 3. Detect entities in all inputs and outputs, construct verifiable symbolic entity objects with the SymbolicEntityConstructor
            {input_pattern_entities, output_pattern_entities} =
              SymbolicEntityConstructor.detect_all_patterns(labeled_content)

            # 4. Get and combine raw content of input and output
            {combined_input_content, combined_output_content} =
              SymbolicEntityConstructor.get_combined_content(labeled_content)

            # # 5. Get and combine content suitable for statement extraction
            # {input_statement_content, output_statement_content} =
            #   SymbolicEntityConstructor.get_combined_statement_content(labeled_content)

            # IO.inspect(input_statement_content, label: "Combined Input Content")
            # IO.inspect(output_statement_content, label: "Combined Output Content")

            # 5. Update the VerificationStateManager with the detected entities and content
            VerificationStateManager.add_input_entities(input_pattern_entities)
            VerificationStateManager.add_output_entities(output_pattern_entities)
            VerificationStateManager.add_input_combined_content(combined_input_content)
            VerificationStateManager.add_output_combined_content(combined_output_content)

            # 4. Start the verification process
            # Pass the pid, but SymbolicVerificationEngine won't use it directly for entity retrieval
            result = HybridVerificationEngine.start_verification(pid, :manual, verifier_config)

            # StatementVerificationEngine.test_comparison()

            # 5. Return the result
            case result do
              {:ok, scores, processed_content} -> {:ok, scores, processed_content}
              {:error, reason} -> {:error, reason}
              {:error, reason, scores} -> {:error, reason, scores, textarea_content}
              _ -> IO.inspect(result, label: "Result")
            end
          rescue
            e ->
              Logger.error("Error during verification: #{inspect(e)}")
              Logger.error("#{Exception.format(:error, e, __STACKTRACE__)}")
              {:error, "Verification failed: #{inspect(e)}", textarea_content}
          end

        {:error, reason} ->
          Logger.error("Failed to start VerificationStateManager: #{inspect(reason)}")
          {:error, reason}
      end
    else
      Logger.error("VerificationSupervisor is not running. Cannot proceed with verification.")
      # Return a fallback value or raise a more specific error
      {:error, :supervisor_not_available}
    end
  end
end
