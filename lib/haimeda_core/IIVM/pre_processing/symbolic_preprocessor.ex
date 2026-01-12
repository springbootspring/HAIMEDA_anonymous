defmodule PreProcessing.SymbolicPreProcessor do
  @chapter_typedoc """
  Main chapter_type for proving conditions on user input, running the symbolic reasoning AI engine with the conditions.
  """

  alias PreProcessing.{
    ConditionProver,
    Logic
  }

  # Path to the ruleset file used for chapter types and conditions
  @path_ruleset Path.join([__DIR__, "../", "resources", "ruleset.json"])

  def verify_LLM_input(data, chapter_type) do
    # get conditions for detected chapter_type
    chapter_type_data = retrieve_chapter_type_contents(chapter_type)

    chapter_data =
      if chapter_type_data == nil do
        IO.puts(
          "Chapter type #{chapter_type} not found in ruleset. Using general chapter ruleset."
        )

        retrieve_chapter_type_contents("general_chapter")
      else
        chapter_type_data
      end

    case chapter_data do
      nil ->
        IO.puts(
          "chapter_type #{chapter_type} not found in ruleset. Check if ruleset file is present."
        )

        {:error, :no_conditions_for_chapter_type_found}

      chapter_data ->
        # Access core_conditions through the conditions map
        conditions = chapter_data["conditions"]
        core_conditions = if conditions, do: conditions["core_conditions"], else: nil
        meta_information = chapter_data["meta_information"]

        case core_conditions do
          nil ->
            IO.puts("No core conditions found for chapter type #{chapter_type}")
            {:error, :no_core_conditions}

          core_conditions ->
            core_condition_names = Map.keys(core_conditions)

            core_condition_ids =
              Enum.map(core_condition_names, fn name -> core_conditions[name]["ID"] end)

            evaluated_conditions =
              Enum.map(Enum.zip(core_condition_names, core_condition_ids), fn {name, id} ->
                ConditionProver.verify_condition(name, data, id)
              end)

            keywords = conditions["keywords"]
            antonyms = conditions["antonyms"]

            keyword_pairs = Enum.map(keywords, fn kw -> {kw["word"], kw["ID"]} end)
            antonym_pairs = Enum.map(antonyms, fn ant -> {ant["word"], ant["ID"]} end)

            evaluated_keywords =
              Enum.map(keyword_pairs, fn {word, id} ->
                ConditionProver.contains_word?(word, data, id)
              end)

            evaluated_antonyms =
              Enum.map(antonym_pairs, fn {word, id} ->
                ConditionProver.contains_word?(word, data, id)
              end)

            satisfied_cond_IDs =
              Enum.filter(
                evaluated_conditions ++ evaluated_keywords ++ evaluated_antonyms,
                fn id -> id != nil end
              )

            IO.inspect(satisfied_cond_IDs, label: "Satisfied Condition IDs")

            result =
              Logic.solve_conditions(conditions, meta_information, satisfied_cond_IDs, false)

            case result do
              {parsed_terms, feedback} when is_list(parsed_terms) and is_list(feedback) ->
                {:ok, {parsed_terms, feedback}}

              nil ->
                IO.puts("No terms found for chapter_type #{chapter_type}")
                {:error, :no_proved_terms_found}

              error ->
                IO.puts("Error processing conditions: #{inspect(error)}")
                {:error, :condition_processing_failed}
            end
        end
    end
  end

  def retrieve_chapter_type_contents(chapter_type_name) do
    # Add error handling for file reading
    try do
      File.read!(@path_ruleset)
      |> Jason.decode!()
      |> Map.get("chapter_types")
      |> Map.get(chapter_type_name)
    rescue
      e in File.Error ->
        IO.puts("Error reading ruleset file: #{inspect(e)}")
        IO.puts("Path attempted: #{@path_ruleset}")
        nil

      e ->
        IO.puts("Unexpected error: #{inspect(e)}")
        nil
    end
  end
end
