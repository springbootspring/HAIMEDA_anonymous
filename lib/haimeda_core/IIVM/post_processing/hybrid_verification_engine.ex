defmodule PostProcessing.HybridVerificationEngine do
  alias PostProcessing.{
    OutputCorrectionController,
    VerificationStateManager,
    StatementVerificationEngine
  }

  alias HaimedaCore.GeneralHelperFunctions, as: GHF

  require Logger

  def start_verification(pid, mode, verifier_config) do
    result =
      case mode do
        :auto ->
          # Start the verification process in auto mode
          start_verification_auto(verifier_config)

        :manual ->
          # Start the verification process in manual mode
          start_verification_manual(verifier_config)
      end
  end

  def start_verification_auto(verifier_config) do
    verification_count = Map.get(verifier_config, :verification_count, 1)
    Logger.info("Starting auto verification with #{verification_count} runs.")

    # Collect results from each verification run
    results =
      Enum.map(1..verification_count, fn run_number ->
        Logger.info("Starting verification run #{run_number} of #{verification_count}")

        # Start the verification process for the current run
        result = start_verification_manual(verifier_config)
        VerificationStateManager.prepare_next_run()

        # Store the run result (will be processed by order_runs later)
        {run_number, result}
      end)

    # Order the results by score and return a structured map
    ordered_results = order_runs(results)
    IO.inspect(ordered_results, label: "ORDERED RESULTS")

    {:ok, ordered_results}
  end

  def start_verification_manual(verifier_config) do
    Logger.info("Starting verification.")

    try do
      input_entities = VerificationStateManager.get_input_entities_of_current_run()
      output_entities = VerificationStateManager.get_output_entities_of_current_run()

      # Early return if no input entities or output entities are found
      cond do
        input_entities == [] ->
          Logger.error("No input entities found for verification")
          {:error, :no_input_entities}

        output_entities == [] ->
          Logger.error("No output entities found for verification")
          {:error, :no_output_entities}

        true ->
          # Continue with verification since both input and output entities exist
          # Remove double occurrences of entities of them same type
          unique_input_entities = make_entities_unique(input_entities)
          unique_output_entities = make_entities_unique(output_entities)

          # replace the entities in the state manager with the unique ones
          VerificationStateManager.replace_input_entities(unique_input_entities)
          VerificationStateManager.replace_output_entities(unique_output_entities)

          # IO.puts("\n=== Unique Input Entities ===")
          # unique_input_entities |> IO.inspect(pretty: true, limit: :infinity, width: 80)

          # IO.puts("\n=== Unique Output Entities ===")
          # unique_output_entities |> IO.inspect(pretty: true, limit: :infinity, width: 80)

          IO.puts("number of unique input entities: #{length(unique_input_entities)}")
          IO.puts("number of unique output entities: #{length(unique_output_entities)}")

          verification_result =
            check_for_missing_entities(
              unique_input_entities,
              unique_output_entities,
              verifier_config
            )

          case verification_result do
            {:ok, current_run_scores} ->
              # result = VerificationStateManager.get_current_response()
              # process with output correction controller, and issue updated content

              result = OutputCorrectionController.correct_output()

              case result do
                {:ok, updated_content} ->
                  {:ok, current_run_scores, updated_content}

                {:error, reason} ->
                  {:error, reason, current_run_scores}
              end

            {:error, reason} ->
              {:error, reason}
          end
      end
    rescue
      e ->
        Logger.error("Error in HybridVerificationEngine: #{inspect(e)}")
        Logger.error("#{Exception.format(:error, e, __STACKTRACE__)}")
        {:error, "Verification engine error: #{inspect(e)}"}
    end
  end

  def check_for_missing_entities(input_entities, output_entities, verifier_config) do
    # Safely extract verification_degree from verifier_config
    verification_degree =
      cond do
        is_map(verifier_config) ->
          Map.get(verifier_config, :verification_degree, :moderate_match)

        is_tuple(verifier_config) ->
          elem(verifier_config, 0)

        true ->
          # Default fallback
          :moderate_match
      end

    # filter type-based
    date_entities_input = Enum.filter(input_entities, fn entity -> entity.type == :date end)
    number_entities_input = Enum.filter(input_entities, fn entity -> entity.type == :number end)

    identifier_entities_input =
      Enum.filter(input_entities, fn entity -> entity.type == :identifier end)

    phrase_entities_input = Enum.filter(input_entities, fn entity -> entity.type == :phrase end)

    statement_entities_input =
      Enum.filter(input_entities, fn entity -> entity.type == :statement end)

    date_entities_output =
      Enum.filter(output_entities, fn entity -> entity.type == :date end)

    number_entities_output =
      Enum.filter(output_entities, fn entity -> entity.type == :number end)

    identifier_entities_output =
      Enum.filter(output_entities, fn entity -> entity.type == :identifier end)

    phrase_entities_output =
      Enum.filter(output_entities, fn entity -> entity.type == :phrase end)

    statement_entities_output =
      Enum.filter(output_entities, fn entity -> entity.type == :statement end)

    {checked_date_input_entities, checked_date_output_entities} =
      check_contained_simple(date_entities_input, date_entities_output)

    {checked_number_input_entities, checked_number_output_entities} =
      check_contained_simple(number_entities_input, number_entities_output)

    {checked_identifier_input_entities, checked_identifier_output_entities} =
      check_contained_simple(identifier_entities_input, identifier_entities_output)

    {checked_phrase_input_entities, checked_phrase_output_entities} =
      check_contained_regex(phrase_entities_input, phrase_entities_output)

    # {checked_statement_input_entities, checked_statement_output_entities} =
    #   {statement_entities_input, statement_entities_output}

    {checked_statement_input_entities, checked_statement_output_entities} =
      if GHF.get_disable_hybrid_postprocessing_setting() do
        IO.puts("Hybrid postprocessing is disabled, skipping statement verification.")
        {statement_entities_input, statement_entities_output}
      else
        check_contained_statements(
          statement_entities_input,
          statement_entities_output,
          verification_degree
        )
      end

    if GHF.get_verbose_output_setting() do
      IO.inspect(checked_statement_input_entities, label: "Checked Statement Input Entities")
      IO.inspect(checked_statement_output_entities, label: "Checked Statement Output Entities")
    end

    checked_input_entites =
      checked_date_input_entities ++
        checked_number_input_entities ++
        checked_identifier_input_entities ++
        checked_phrase_input_entities ++
        checked_statement_input_entities

    checked_output_entities =
      checked_date_output_entities ++
        checked_number_output_entities ++
        checked_identifier_output_entities ++
        checked_phrase_output_entities ++
        checked_statement_output_entities

    VerificationStateManager.replace_input_entities(checked_input_entites)
    VerificationStateManager.replace_output_entities(checked_output_entities)

    missing_entities_map = %{
      date: Enum.filter(checked_date_input_entities, &(&1.status == :not_detected)),
      number: Enum.filter(checked_number_input_entities, &(&1.status == :not_detected)),
      identifier: Enum.filter(checked_identifier_input_entities, &(&1.status == :not_detected)),
      phrase: Enum.filter(checked_phrase_input_entities, &(&1.status == :not_detected)),
      statement: Enum.filter(checked_statement_input_entities, &(&1.status == :not_detected))
    }

    false_entities_map = %{
      date: Enum.filter(checked_date_output_entities, &(&1.status == :not_detected)),
      number: Enum.filter(checked_number_output_entities, &(&1.status == :not_detected)),
      identifier: Enum.filter(checked_identifier_output_entities, &(&1.status == :not_detected)),
      phrase: Enum.filter(checked_phrase_output_entities, &(&1.status == :not_detected)),
      statement: Enum.filter(checked_statement_output_entities, &(&1.status == :not_detected))
    }

    VerificationStateManager.set_current_run_missing_and_false_entities(
      missing_entities_map,
      false_entities_map
    )

    missing_and_false_entities =
      VerificationStateManager.get_current_run_missing_and_false_entities()

    # function for counting the number of missing entities in both lists
    {count_input_date_entities, count_output_date_entities, count_missing_date_entities,
     count_false_date_entities} =
      count_missing_entities(checked_date_input_entities, checked_date_output_entities)

    {count_input_number_entities, count_output_number_entities, count_missing_number_entities,
     count_false_number_entities} =
      count_missing_entities(checked_number_input_entities, checked_number_output_entities)

    {count_input_identifier_entities, count_output_identifier_entities,
     count_missing_identifier_entities,
     count_false_identifier_entities} =
      count_missing_entities(
        checked_identifier_input_entities,
        checked_identifier_output_entities
      )

    {count_input_phrase_entities, count_output_phrase_entities, count_missing_phrase_entities,
     count_false_phrase_entities} =
      count_missing_entities(checked_phrase_input_entities, checked_phrase_output_entities)

    {count_input_statement_entities, count_output_statement_entities,
     count_missing_statement_entities,
     count_false_statement_entities} =
      count_missing_entities(checked_statement_input_entities, checked_statement_output_entities)

    # create map of missing entities for input and output
    count_missing_entities_map = %{
      date: {count_missing_date_entities, count_false_date_entities},
      number: {count_missing_number_entities, count_false_number_entities},
      identifier: {count_missing_identifier_entities, count_false_identifier_entities},
      phrase: {count_missing_phrase_entities, count_false_phrase_entities},
      statement: {count_missing_statement_entities, count_false_statement_entities}
    }

    count_entities_map = %{
      date: {count_input_date_entities, count_output_date_entities},
      number: {count_input_number_entities, count_output_number_entities},
      identifier: {count_input_identifier_entities, count_output_identifier_entities},
      phrase: {count_input_phrase_entities, count_output_phrase_entities},
      statement: {count_input_statement_entities, count_output_statement_entities}
    }

    {score_total, score_weighted} =
      calculate_scores(count_missing_entities_map, count_entities_map)

    current_run_scores =
      VerificationStateManager.get_current_run_scores()

    if GHF.get_verbose_output_setting() do
      IO.inspect(current_run_scores, label: "Current Run Scores")
    end

    {:ok, current_run_scores}
  end

  def check_contained_statements(
        input_statements,
        output_statements,
        verification_degree,
        verbose_scores \\ true
      ) do
    try do
      # Call the StatementVerificationEngine to compare all statements with our parameters
      {checked_input_statement_entities, checked_output_statement_entities} =
        StatementVerificationEngine.compare_all_statements(
          input_statements,
          output_statements,
          verification_degree,
          verbose_scores
        )

      {checked_input_statement_entities, checked_output_statement_entities}
    rescue
      error ->
        IO.puts("Error in statement comparison: #{inspect(error)}")

        Logger.error(
          "Statement verification error: #{Exception.format(:error, error, __STACKTRACE__)}"
        )

        {
          Enum.map(
            input_statements,
            &Map.merge(&1, %{
              status: :not_detected,
              representations: [],
              detected_in: nil
            })
          ),
          Enum.map(
            output_statements,
            &Map.merge(&1, %{
              status: :not_detected,
              representations: [],
              detected_in: nil
            })
          )
        }
    end
  end

  def calculate_scores(count_missing_entities_map, count_entities_map) do
    num_input_entities = VerificationStateManager.get_value(:entity_registry, :num_input_entities)

    num_output_entities =
      VerificationStateManager.get_value(:entity_registry, :num_output_entities)

    missing_input_count =
      Enum.reduce(count_missing_entities_map, 0, fn {_type, {input_count, _}}, acc ->
        acc + input_count
      end)

    false_output_count =
      Enum.reduce(count_missing_entities_map, 0, fn {_type, {_, output_count}}, acc ->
        acc + output_count
      end)

    score_total_input_percent =
      if num_input_entities != 0,
        do: 100 * (1 - missing_input_count / num_input_entities),
        else: 100

    score_total_output_percent =
      if num_output_entities != 0,
        do: 100 * (1 - false_output_count / num_output_entities),
        else: 100

    score_total_percent = (score_total_input_percent + score_total_output_percent) / 2

    weights = %{
      date: 0.5,
      identifier: 0.5,
      number: 0.4,
      phrase: 0.2,
      statement: 0.2
    }

    input_weighted_score =
      calculate_weighted_coverage_score(
        count_missing_entities_map,
        count_entities_map,
        weights,
        :input
      )

    output_weighted_score =
      calculate_weighted_coverage_score(
        count_missing_entities_map,
        count_entities_map,
        weights,
        :output
      )

    combined_weighted_score = (input_weighted_score + output_weighted_score) / 2

    VerificationStateManager.replace_current_run_scores(%{
      input_coverage_percentage: score_total_input_percent,
      output_coverage_percentage: score_total_output_percent,
      overall_coverage_percentage: score_total_percent,
      input_weighted_content_score: input_weighted_score,
      output_weighted_content_score: output_weighted_score,
      overall_weighted_content_score: combined_weighted_score
    })

    {score_total_percent, combined_weighted_score}
  end

  defp calculate_weighted_coverage_score(
         count_missing,
         count_total,
         weights,
         entity_source
       ) do
    # select types that actually exist
    types =
      weights
      |> Enum.filter(fn {type, _w} ->
        {in_tot, out_tot} = count_total[type]
        tot = if entity_source == :input, do: in_tot, else: out_tot
        tot > 0
      end)
      |> Enum.map(&elem(&1, 0))

    if types == [] do
      10.0
    else
      total_w = Enum.reduce(types, 0.0, &(&2 + weights[&1]))

      sum_score =
        Enum.reduce(types, 0.0, fn type, acc ->
          {in_tot, out_tot} = count_total[type]
          {in_mis, out_mis} = count_missing[type]
          tot = if entity_source == :input, do: in_tot, else: out_tot
          mis = if entity_source == :input, do: in_mis, else: out_mis
          matched = tot - mis
          acc + matched / tot * weights[type]
        end)

      Float.round(sum_score / total_w * 10, 3)
    end
  end

  def check_contained_simple(input_entities, output_entities) do
    # Process input entities - check if they appear in output entities
    updated_input_entities =
      Enum.map(input_entities, fn input_entity ->
        # Convert all input entity representations to lowercase
        input_representations = Enum.map(input_entity.representations, &String.downcase/1)

        # Check if this input entity is contained in any output entity
        detected_result =
          Enum.reduce_while(output_entities, {false, nil}, fn output_entity, _acc ->
            # Convert all output entity representations to lowercase
            output_representations = Enum.map(output_entity.representations, &String.downcase/1)

            # Check if any input representation is contained in any output representation
            is_detected =
              Enum.any?(input_representations, fn input_rep ->
                Enum.any?(output_representations, fn output_rep ->
                  String.contains?(output_rep, input_rep)
                end)
              end)

            if is_detected do
              {:halt, {true, output_entity.location}}
            else
              {:cont, {false, nil}}
            end
          end)

        # Update the status and detected_in fields of the input entity
        {is_detected, detected_location} = detected_result

        Map.put(input_entity, :status, if(is_detected, do: :detected, else: :not_detected))
        |> Map.put(:detected_in, detected_location)
      end)

    updated_output_entities =
      Enum.map(output_entities, fn output_entity ->
        # Convert all output entity representations to lowercase
        output_representations = Enum.map(output_entity.representations, &String.downcase/1)

        # Check if this output entity is contained in any input entity
        detected_result =
          Enum.reduce_while(input_entities, {false, nil}, fn input_entity, _acc ->
            # Convert all input entity representations to lowercase
            input_representations = Enum.map(input_entity.representations, &String.downcase/1)

            # Check if any output representation is contained in any input representation
            is_detected =
              Enum.any?(output_representations, fn output_rep ->
                Enum.any?(input_representations, fn input_rep ->
                  String.contains?(input_rep, output_rep)
                end)
              end)

            if is_detected do
              {:halt, {true, input_entity.location}}
            else
              {:cont, {false, nil}}
            end
          end)

        # Update the status and detected_in fields of the output entity
        {is_detected, detected_location} = detected_result

        Map.put(output_entity, :status, if(is_detected, do: :detected, else: :not_detected))
        |> Map.put(:detected_in, detected_location)
      end)

    {updated_input_entities, updated_output_entities}
  end

  def check_contained_regex(input_entities, output_entities) do
    input_content = VerificationStateManager.get_value(:entity_registry, :input_combined_content)

    output_content =
      VerificationStateManager.get_value(:entity_registry, :current_run_output_combined_content)

    # Process input entities - check if their regex patterns match in output content
    updated_input_entities =
      Enum.map(input_entities, fn input_entity ->
        # Check if any regex of this input entity matches any part of the output content
        is_detected =
          Enum.any?(input_entity.representations, fn regex_pattern ->
            case Regex.compile(regex_pattern) do
              {:ok, regex} ->
                Enum.any?(output_content, fn content_string ->
                  Regex.match?(regex, content_string)
                end)

              {:error, _} ->
                false
            end
          end)

        # Update the status of the input entity
        Map.put(input_entity, :status, if(is_detected, do: :detected, else: :not_detected))
        |> Map.put(:detected_in, if(is_detected, do: :output_content, else: nil))
      end)

    # Process output entities - check if their regex patterns match in input content
    updated_output_entities =
      Enum.map(output_entities, fn output_entity ->
        # Check if any regex of this output entity matches any part of the input content
        is_detected =
          Enum.any?(output_entity.representations, fn regex_pattern ->
            case Regex.compile(regex_pattern) do
              {:ok, regex} ->
                Enum.any?(input_content, fn content_string ->
                  Regex.match?(regex, content_string)
                end)

              {:error, _} ->
                false
            end
          end)

        # Update the status of the output entity
        Map.put(output_entity, :status, if(is_detected, do: :detected, else: :not_detected))
        |> Map.put(:detected_in, if(is_detected, do: :input_content, else: nil))
      end)

    {updated_input_entities, updated_output_entities}
  end

  def count_missing_entities(input_entities, output_entities) do
    # count total number of entities in input and output
    total_input_count = length(input_entities)
    total_output_count = length(output_entities)

    # Count input entities with status :not_detected
    missing_input_count =
      input_entities
      |> Enum.count(fn entity -> entity.status == :not_detected end)

    # Count output entities with status :not_detected
    missing_output_count =
      output_entities
      |> Enum.count(fn entity -> entity.status == :not_detected end)

    # Return the counts as a tuple
    {total_input_count, total_output_count, missing_input_count, missing_output_count}
  end

  def make_entities_unique(entities) do
    # Group entities by their type
    entities_by_type = Enum.group_by(entities, fn entity -> entity.type end)

    # For each type, filter out entities with overlapping representations
    unique_entities =
      entities_by_type
      |> Enum.map(fn {_type, type_entities} -> filter_overlapping_entities(type_entities) end)
      |> List.flatten()

    unique_entities
  end

  # Filter entities of the same type, removing those with overlapping representations
  defp filter_overlapping_entities([]), do: []
  defp filter_overlapping_entities([entity]), do: [entity]

  defp filter_overlapping_entities(entities) do
    Enum.reduce(entities, [], fn entity, acc ->
      # Check if current entity has overlapping representations with any in accumulator
      has_overlap =
        Enum.any?(acc, fn existing ->
          has_overlapping_representations?(entity, existing)
        end)

      # Only add entity if it has no overlapping representations
      if has_overlap do
        acc
      else
        [entity | acc]
      end
    end)
  end

  # Check if two entities have any overlapping representations
  defp has_overlapping_representations?(entity1, entity2) do
    # Get the representations of both entities
    reps1 = MapSet.new(entity1.representations)
    reps2 = MapSet.new(entity2.representations)

    # Check if there's any overlap between the two sets
    !MapSet.disjoint?(reps1, reps2)
  end

  def order_runs(run_results) do
    # Filter only successful results
    successful_results =
      Enum.filter(run_results, fn {_run_number, result} ->
        case result do
          {:ok, _scores, _content} -> true
          _ -> false
        end
      end)

    # Sort by weighted score, then by coverage percentage for tie-breaking
    sorted_results =
      Enum.sort_by(successful_results, fn {_run_number, {:ok, scores, _content}} ->
        # Return a tuple for multi-level sorting (both descending)
        {
          -1 * Map.get(scores, :overall_weighted_content_score, 0),
          -1 * Map.get(scores, :overall_coverage_percentage, 0)
        }
      end)

    # Convert to a map with rank as key
    sorted_results
    |> Enum.with_index(1)
    |> Enum.map(fn {{run_number, {:ok, scores, content}}, rank} ->
      {rank, {scores, content, run_number}}
    end)
    |> Enum.into(%{})
  end
end
