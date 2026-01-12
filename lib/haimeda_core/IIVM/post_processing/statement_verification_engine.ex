defmodule PostProcessing.StatementVerificationEngine do
  @moduledoc """
  Provides classification rules and functions for determining match types
  between statements using hybrid AI (symbolic rules + ML scores).
  """
  alias HaimedaCore.GatewayAPI, as: GW
  require Logger

  @classification_matrix %{
    exact_match: %{
      combined_score_min: 90,
      confidence_min: 90,
      required_conditions: [
        {:or,
         [
           # Perfect or near-perfect match
           {:and,
            [
              {:combined_score, :>=, 95},
              {:overlap_percent, :>=, 90}
            ]},
           # High domain understanding with good TFIDF
           {:and,
            [
              {:domain, :>=, 95},
              {:tfidf, :>=, 45}
            ]},
           # Good similarity metrics (relaxed euclidean threshold)
           {:and,
            [
              {:euclidean, :>=, 30},
              {:combined_score, :>=, 95}
            ]}
         ]}
      ]
    },
    strong_match: %{
      combined_score_min: 75,
      confidence_min: 75,
      required_conditions: [
        {:or,
         [
           # TFIDF threshold for strong match is around 50
           {:tfidf, :>=, 35},
           {:domain, :>=, 80},
           # Good keyword overlap with solid combined score
           {:and,
            [
              {:keyword_overlap, :>=, 70},
              {:combined_score, :>=, 80}
            ]},
           # Euclidean similarity less reliable but useful
           {:euclidean, :>=, 45}
         ]}
      ]
    },
    moderate_match: %{
      combined_score_min: 45,
      # Reduced from 50
      confidence_min: 40,
      required_conditions: [
        {:or,
         [
           {:tfidf, :>=, 20},
           # Domain understanding is key for moderate matches
           {:domain, :>=, 50},
           # Some keyword overlap
           {:keyword_overlap, :>=, 20},
           {:and,
            [
              {:combined_score, :>=, 50},
              {:confidence, :>=, 50}
            ]}
         ]}
      ]
    },
    weak_match: %{
      combined_score_min: 25,
      confidence_min: 0,
      required_conditions: []
    },
    no_match: %{
      combined_score_min: 0,
      confidence_min: 0,
      required_conditions: []
    }
  }

  # Rules that can override classification based on custom conditions
  def override_rules do
    [
      {:keyword_high_similarity_override, &keyword_has_high_similarity/1, :strong_match}

      # Domain expertise rule for technical content
      # {:domain_expertise_override,
      #  fn result ->
      #    # Add nil check to prevent KeyError
      #    result != nil &&
      #      Map.has_key?(result, :metrics) &&
      #      is_map(result.metrics) &&
      #      Map.has_key?(result.metrics, :domain) &&
      #      result.metrics.domain >= 85 &&
      #      result.combined_score >= 25
      #  end, :moderate_match}
    ]
  end

  defp keyword_has_high_similarity(nil), do: false

  defp keyword_has_high_similarity(result) do
    if result.overlap_percent == 100 && is_list(result.keywords.common) do
      Enum.any?(result.keywords.common, fn keyword ->
        keyword_str = if is_list(keyword), do: List.to_string(keyword), else: to_string(keyword)

        case Regex.run(~r/\((\d+\.\d+)\)$/, keyword_str) do
          [_, score_str] ->
            {score, _} = Float.parse(score_str)
            score >= 0.95

          _ ->
            false
        end
      end)
    else
      false
    end
  end

  @doc """
  Compares all input statements against all output statements and finds the best matches.
  Returns updated input and output entities with status, representations and detected_in fields updated.
  """
  def compare_all_statements(
        input_statements,
        output_statements,
        match_min \\ :weak_match,
        verbose_scores \\ false
      ) do
    # First check if either list is empty
    cond do
      input_statements == [] && output_statements == [] ->
        # Both lists are empty, nothing to compare
        {[], []}

      input_statements == [] ->
        # No input statements, mark all output statements as not detected
        updated_output_statements =
          Enum.map(output_statements, fn stmt ->
            Map.merge(stmt, %{
              status: :not_detected,
              representations: [],
              detected_in: nil
            })
          end)

        {[], updated_output_statements}

      output_statements == [] ->
        # No output statements, mark all input statements as not detected
        updated_input_statements =
          Enum.map(input_statements, fn stmt ->
            Map.merge(stmt, %{
              status: :not_detected,
              representations: [],
              detected_in: nil
            })
          end)

        {updated_input_statements, []}

      true ->
        # Both lists contain statements, proceed with comparison
        # Get match rank threshold for the specified match_min level
        min_match_rank = get_match_rank(match_min)

        # Extract all entities for batch processing
        input_entities = Enum.map(input_statements, fn stmt -> stmt.entity end)
        output_entities = Enum.map(output_statements, fn stmt -> stmt.entity end)

        # Process all comparisons in batch
        batch_results = compare_statements_batch(input_entities, output_entities)

        # If batch processing failed completely (empty results), return the statements unchanged
        if batch_results == [] do
          Logger.warning(
            "Statement comparison failed after retries - returning unmodified statements"
          )

          return_unmodified_statements(input_statements, output_statements)
        else
          # IO.inspect(batch_results, label: "Batch Results")
          # Build a lookup map for quick access to results
          results_lookup =
            build_comparison_results_lookup(batch_results, input_statements, output_statements)

          # IO.inspect(results_lookup, label: "Results Lookup")
          # Generate all pairwise comparison results using the lookup
          comparison_results =
            Enum.flat_map(input_statements, fn input_stmt ->
              Enum.map(output_statements, fn output_stmt ->
                # Get the detailed comparison result from our lookup
                lookup_key = {input_stmt.id, output_stmt.id}
                comparison_result = Map.get(results_lookup, lookup_key)

                # Get the match classification - add safe handling for nil results
                {match_type, confidence} =
                  if comparison_result == nil do
                    {:no_match, 0}
                  else
                    classify_match(comparison_result)
                  end

                # Return comprehensive result information
                %{
                  input_id: input_stmt.id,
                  input_entity: input_stmt,
                  output_id: output_stmt.id,
                  output_entity: output_stmt,
                  # Provide default if nil
                  result: comparison_result || %{combined_score: 0},
                  match_type: match_type,
                  confidence: confidence,
                  match_rank: get_match_rank(match_type)
                }
              end)
            end)

          # Group results by input ID
          results_by_input = Enum.group_by(comparison_results, fn r -> r.input_id end)

          # Update input statements with match information
          updated_input_statements =
            Enum.map(input_statements, fn input_stmt ->
              # Get all comparisons for this input statement
              stmt_comparisons = results_by_input[input_stmt.id] || []

              # Filter matches that meet the minimum match threshold
              valid_matches =
                stmt_comparisons
                |> Enum.filter(fn comp -> comp.match_rank >= min_match_rank end)
                |> Enum.sort_by(fn comp -> {comp.match_rank, comp.confidence} end, :desc)

              if Enum.empty?(valid_matches) do
                # No valid matches found
                Map.merge(input_stmt, %{
                  status: :not_detected,
                  representations: [],
                  detected_in: nil
                })
              else
                # Found valid matches
                # Extract locations of detected matches
                detected_locations =
                  valid_matches
                  |> Enum.map(fn match -> match.output_entity.location end)
                  |> Enum.uniq()

                # Format the detected_in field
                detected_in =
                  if length(detected_locations) == 1,
                    do: hd(detected_locations),
                    else: detected_locations

                # Create representations for each match
                representations =
                  Enum.map(valid_matches, fn match ->
                    if verbose_scores do
                      # Include all scores when verbose_scores is true
                      %{
                        entity: match.output_entity.entity,
                        matchtype: match.match_type,
                        scores: %{
                          combined_score: match.result.combined_score,
                          confidence: match.confidence,
                          basic_score: match.result.basic_score,
                          tfidf: match.result.metrics.tfidf,
                          euclidean: match.result.metrics.euclidean,
                          manhattan: match.result.metrics.manhattan,
                          domain: match.result.metrics.domain,
                          overlap_percent: match.result.overlap_percent
                        }
                      }
                    else
                      # Include only basic information when verbose_scores is false
                      %{
                        entity: match.output_entity.entity,
                        matchtype: match.match_type,
                        combined_score: match.result.combined_score
                      }
                    end
                  end)

                # Update the input statement with match information
                Map.merge(input_stmt, %{
                  status: :detected,
                  representations: representations,
                  detected_in: detected_in
                })
              end
            end)

          # Group results by output ID
          results_by_output = Enum.group_by(comparison_results, fn r -> r.output_id end)

          # Update output statements with match information
          updated_output_statements =
            Enum.map(output_statements, fn output_stmt ->
              # Get all comparisons for this output statement
              stmt_comparisons = results_by_output[output_stmt.id] || []

              # Filter matches that meet the minimum match threshold
              valid_matches =
                stmt_comparisons
                |> Enum.filter(fn comp -> comp.match_rank >= min_match_rank end)
                |> Enum.sort_by(fn comp -> {comp.match_rank, comp.confidence} end, :desc)

              if Enum.empty?(valid_matches) do
                # No valid matches found
                Map.merge(output_stmt, %{
                  status: :not_detected,
                  representations: [],
                  detected_in: nil
                })
              else
                # Found valid matches
                # Extract locations of detected matches
                detected_locations =
                  valid_matches
                  |> Enum.map(fn match -> match.input_entity.location end)
                  |> Enum.uniq()

                # Format the detected_in field
                detected_in =
                  if length(detected_locations) == 1,
                    do: hd(detected_locations),
                    else: detected_locations

                # Create representations for each match
                representations =
                  Enum.map(valid_matches, fn match ->
                    if verbose_scores do
                      # Include all scores when verbose_scores is true
                      %{
                        entity: match.input_entity.entity,
                        matchtype: match.match_type,
                        scores: %{
                          combined_score: match.result.combined_score,
                          confidence: match.confidence,
                          basic_score: match.result.basic_score,
                          tfidf: match.result.metrics.tfidf,
                          euclidean: match.result.metrics.euclidean,
                          manhattan: match.result.metrics.manhattan,
                          domain: match.result.metrics.domain,
                          overlap_percent: match.result.overlap_percent
                        }
                      }
                    else
                      # Include only basic information when verbose_scores is false
                      %{
                        entity: match.input_entity.entity,
                        matchtype: match.match_type,
                        combined_score: match.result.combined_score
                      }
                    end
                  end)

                # Update the output statement with match information
                Map.merge(output_stmt, %{
                  status: :detected,
                  representations: representations,
                  detected_in: detected_in
                })
              end
            end)

          {updated_input_statements, updated_output_statements}
        end
    end
  end

  # Helper function to return unmodified statements
  defp return_unmodified_statements(input_statements, output_statements) do
    # Add status fields to indicate processing was not performed
    updated_input_statements =
      Enum.map(input_statements, fn stmt ->
        Map.merge(stmt, %{
          status: :not_processed,
          representations: [],
          detected_in: nil
        })
      end)

    updated_output_statements =
      Enum.map(output_statements, fn stmt ->
        Map.merge(stmt, %{
          status: :not_processed,
          representations: [],
          detected_in: nil
        })
      end)

    {updated_input_statements, updated_output_statements}
  end

  # Process the batch results returned from Python into a consistent Elixir structure
  defp process_batch_results(results) do
    string_results = convert_charlists(results)

    Enum.map(string_results, fn result ->
      statement1 =
        if is_binary(result["statement1"]),
          do: result["statement1"],
          else: convert_to_string(result["statement1"])

      statement2 =
        if is_binary(result["statement2"]),
          do: result["statement2"],
          else: convert_to_string(result["statement2"])

      metrics = %{
        tfidf: get_in(result, ["metrics", "tfidf"]) || Map.get(result, "tfidf_similarity", 0),
        euclidean:
          get_in(result, ["metrics", "euclidean"]) || Map.get(result, "euclidean_similarity", 0),
        manhattan:
          get_in(result, ["metrics", "manhattan"]) || Map.get(result, "manhattan_similarity", 0),
        domain: get_in(result, ["metrics", "domain"]) || Map.get(result, "domain_similarity", 0)
      }

      keywords1 = get_keywords(result, "statement1", "keywords1")
      keywords2 = get_keywords(result, "statement2", "keywords2")
      common_keywords = get_keywords(result, "common", "common_keywords")

      processed_result = %{
        basic_score: Map.get(result, "basic_score", 0),
        combined_score: Map.get(result, "combined_score", 0),
        confidence: Map.get(result, "confidence", 0),
        interpretation: get_string_value(result, "interpretation", "unknown"),
        overlap_percent:
          Map.get(result, "overlap_percent") || Map.get(result, "overlap_percent", 0),
        metrics: metrics,
        keywords: %{
          statement1: keywords1,
          statement2: keywords2,
          common: common_keywords
        }
      }

      %{
        statement1: statement1,
        statement2: statement2,
        result: processed_result
      }
    end)
  end

  # Get and normalize keyword fields from Python results
  defp get_keywords(result, nested_key, flat_key) do
    keywords =
      cond do
        is_map(result["keywords"]) && Map.has_key?(result["keywords"], nested_key) ->
          result["keywords"][nested_key]

        Map.has_key?(result, flat_key) ->
          result[flat_key]

        true ->
          []
      end

    format_python_keywords(keywords)
  end

  # Convert resiliently charlists and lists to strings
  defp get_string_value(map, key, default) do
    case Map.get(map, key) do
      nil ->
        default

      value when is_binary(value) ->
        value

      value when is_list(value) ->
        if List.ascii_printable?(value) do
          List.to_string(value)
        else
          to_string(value)
        end

      value ->
        to_string(value)
    end
  end

  # Convert lists to strings, attempting UTF-8 codepoint handling when needed
  defp convert_to_string(value) when is_list(value) do
    if List.ascii_printable?(value) do
      List.to_string(value)
    else
      try_convert_charlist(value)
    end
  end

  defp convert_to_string(value) when is_binary(value), do: value
  defp convert_to_string(value), do: to_string(value)

  # Attempt to convert tricky charlists to UTF-8 string
  defp try_convert_charlist(value) when is_list(value) do
    try do
      value |> Enum.map(fn c -> <<c::utf8>> end) |> Enum.join("")
    rescue
      _ -> inspect(value)
    end
  end

  # Recursively convert charlists to strings where appropriate
  defp convert_charlists(item) do
    cond do
      is_list(item) and List.ascii_printable?(item) ->
        List.to_string(item)

      is_list(item) and Enum.all?(item, fn x -> is_integer(x) and x >= 0 and x <= 0x10FFFF end) ->
        try_convert_charlist(item)

      is_list(item) ->
        Enum.map(item, &convert_charlists/1)

      is_map(item) ->
        Map.new(item, fn {k, v} -> {convert_charlists(k), convert_charlists(v)} end)

      true ->
        item
    end
  end

  # Format keyword entries coming from Python into Elixir strings
  defp format_python_keywords(""), do: []
  defp format_python_keywords(nil), do: []
  defp format_python_keywords(keywords) when not is_list(keywords), do: []

  defp format_python_keywords(keywords) do
    Enum.map(keywords, fn keyword ->
      cond do
        is_binary(keyword) ->
          keyword

        is_list(keyword) and List.ascii_printable?(keyword) ->
          List.to_string(keyword)

        is_list(keyword) and
            Enum.all?(keyword, fn x -> is_integer(x) and x >= 0 and x <= 0x10FFFF end) ->
          try_convert_charlist(keyword)

        is_list(keyword) ->
          inspect(keyword)

        true ->
          to_string(keyword)
      end
    end)
  end

  # Build a lookup of comparison results keyed by {input_id, output_id}
  defp build_comparison_results_lookup(batch_results, input_statements, output_statements) do
    input_map =
      Enum.reduce(input_statements, %{}, fn stmt, acc ->
        Map.put(acc, stmt.entity, stmt.id)
      end)

    output_map =
      Enum.reduce(output_statements, %{}, fn stmt, acc ->
        Map.put(acc, stmt.entity, stmt.id)
      end)

    Enum.reduce(batch_results, %{}, fn result, acc ->
      s1 = Map.get(result, :statement1) || Map.get(result, "statement1", "")
      s2 = Map.get(result, :statement2) || Map.get(result, "statement2", "")

      input_id = Map.get(input_map, s1)
      output_id = Map.get(output_map, s2)

      if input_id && output_id do
        result_data = Map.get(result, :result) || result
        Map.put(acc, {input_id, output_id}, result_data)
      else
        acc
      end
    end)
  end

  # Batch comparison function that sends all statements at once to Python
  defp compare_statements_batch(input_statements, output_statements) do
    if GW.test_connection(:statement_worker_pool) do
      total_pairs = length(input_statements) * length(output_statements)

      # IO.puts(
      #   "Processing batch comparison of #{length(input_statements)} input statements against #{length(output_statements)} output statements (#{total_pairs} total pairs)..."
      # )

      # Prepare statement pairs
      statement_pairs = for i <- input_statements, o <- output_statements, do: {i, o}

      # Calculate appropriate timeout - increase for large batches
      adaptive_timeout = max(300_000, min(1_200_000, total_pairs * 5000))

      # IO.puts(
      #   "Using timeout of #{round(adaptive_timeout / 1000)} seconds for #{total_pairs} statement pairs"
      # )

      # Try up to 3 times before giving up
      do_compare_with_retry(statement_pairs, adaptive_timeout, 3)
    else
      Logger.error("Python connection failed for batch comparison")
      # Return empty results on connection failure
      []
    end
  end

  # New helper function that implements retry logic
  defp do_compare_with_retry(statement_pairs, timeout, retries_left) do
    try do
      # Start timer
      start_time = System.monotonic_time(:millisecond)

      # Call Python with reload: false to avoid reloading every time
      case GW.call(
             :statement_worker_pool,
             :process_batch,
             [statement_pairs],
             %{restart: true, reload: false},
             timeout
           ) do
        {:ok, results} ->
          # Calculate elapsed time
          elapsed_ms = System.monotonic_time(:millisecond) - start_time
          IO.puts("Batch processing completed in #{elapsed_ms / 1000} seconds")

          # Process results
          processed_results = process_batch_results(results)

          # Release Python resources and then terminate the connection by sending an exit signal
          Task.start(fn -> teardown_and_terminate() end)

          processed_results

        {:error, reason} ->
          if retries_left > 1 do
            # Log the retry attempt
            Logger.warning(
              "Batch comparison attempt failed: #{inspect(reason)}. Retries left: #{retries_left - 1}"
            )

            # Wait a bit before retrying (exponential backoff)
            backoff_ms = (4 - retries_left) * 2000
            Process.sleep(backoff_ms)

            # Retry with one less retry count
            do_compare_with_retry(statement_pairs, timeout, retries_left - 1)
          else
            # All retries exhausted
            Logger.error("Batch comparison failed after multiple attempts: #{inspect(reason)}")
            # Cleanup Python process and restart
            Task.start(fn -> teardown_and_terminate() end)
            # Return empty results after all retries fail
            []
          end
      end
    catch
      :exit, {:timeout, _} ->
        if retries_left > 1 do
          Logger.warning(
            "Timeout occurred during batch comparison. Retries left: #{retries_left - 1}"
          )

          # Wait a bit before retrying (exponential backoff)
          backoff_ms = (4 - retries_left) * 2000
          Process.sleep(backoff_ms)

          # Try again with increased timeout
          increased_timeout = round(timeout * 1.5)
          do_compare_with_retry(statement_pairs, increased_timeout, retries_left - 1)
        else
          Logger.error("Timeout occurred during batch comparison after multiple attempts")
          # Restart Python process to clean up resources after timeout
          Task.start(fn -> teardown_and_terminate() end)
          # Return empty results after all retries fail
          []
        end

      kind, error ->
        if retries_left > 1 do
          Logger.warning(
            "Error during batch comparison: #{inspect({kind, error})}. Retries left: #{retries_left - 1}"
          )

          # Wait a bit before retrying (exponential backoff)
          backoff_ms = (4 - retries_left) * 2000
          Process.sleep(backoff_ms)

          # Try again
          do_compare_with_retry(statement_pairs, timeout, retries_left - 1)
        else
          Logger.error(
            "Error during batch comparison after multiple attempts: #{inspect({kind, error})}"
          )

          # Clean up resources
          spawn(fn -> GW.restart_genserver(file: :statement_worker_pool) end)
          # Return empty results after all retries fail
          []
        end
    end
  end

  def teardown_and_terminate() do
    IO.puts("Releasing Python worker pool resources...")
    # First release Python resources
    GW.call(:statement_worker_pool, :release_resources, [], %{}, 5000)

    # Then get the GenServer pid to send it an exit signal
    case Process.whereis(HaimedaCore.GatewayAPI) do
      nil ->
        IO.puts("GatewayAPI GenServer not found")

      gateway_pid ->
        # Send a message to tell the GenServer to shut down the Python process
        IO.puts("Sending graceful termination signal to Python connection...")
        send(gateway_pid, :terminate_python)
        IO.puts("Python termination signal sent")
    end
  end

  @doc """
  Classifies the match between two statements based on comparison results.
  Returns a tuple with the match type and a confidence score.
  """
  def classify_match(comparison_result) do
    # First check for nil result
    if comparison_result == nil do
      {:no_match, 0}
    else
      # Check for override rules
      case check_override_rules(comparison_result) do
        nil ->
          # No override, use the classification matrix
          classify_with_matrix(comparison_result)

        match_type ->
          {match_type, calculate_confidence_for_match(match_type, comparison_result)}
      end
    end
  end

  @doc """
  Determines if a comparison result indicates a match (any level above no_match).
  """
  def is_match?(comparison_result) do
    {match_type, _confidence} = classify_match(comparison_result)
    match_type != :no_match
  end

  @doc """
  Compares two statement comparison results and returns the better match.
  """
  def compare_matches(result1, result2) do
    {match_type1, confidence1} = classify_match(result1)
    {match_type2, confidence2} = classify_match(result2)

    match_rank1 = get_match_rank(match_type1)
    match_rank2 = get_match_rank(match_type2)

    cond do
      match_rank1 > match_rank2 -> {result1, match_type1, confidence1}
      match_rank2 > match_rank1 -> {result2, match_type2, confidence2}
      confidence1 >= confidence2 -> {result1, match_type1, confidence1}
      true -> {result2, match_type2, confidence2}
    end
  end

  # Private helper functions

  defp classify_with_matrix(result) do
    # Add nil check - return no match if result is nil
    if result == nil do
      {:no_match, 0}
    else
      # Extract all possible match types from the classification matrix
      all_possible_matches =
        @classification_matrix
        |> Enum.filter(fn {_match_type, criteria} ->
          meets_criteria?(result, criteria)
        end)
        |> Enum.sort_by(
          fn {match_type, _criteria} -> get_match_rank(match_type) end,
          :desc
        )

      case all_possible_matches do
        # No matches found
        [] ->
          {:no_match, 0}

        # Found at least one match - take the highest ranked one
        [{match_type, _criteria} | _] ->
          confidence = calculate_confidence_for_match(match_type, result)
          {match_type, confidence}
      end
    end
  end

  # Helper function to calculate confidence based on score
  defp calculate_confidence_for_score(match_type, result) do
    # Calculate confidence as a percentage of how far above the threshold the score is
    base_threshold = @classification_matrix[match_type].combined_score_min
    next_threshold = get_next_threshold(match_type)
    score_range = next_threshold - base_threshold

    # How much above threshold?
    score_delta = result.combined_score - base_threshold

    # Calculate confidence (min 80%, max 100%)
    confidence = min(100, 80 + score_delta / score_range * 20)
    round(confidence)
  end

  defp meets_criteria?(nil, _criteria), do: false

  defp meets_criteria?(result, criteria) do
    combined_score = result.combined_score
    confidence = result.confidence

    # Check basic score thresholds
    basic_criteria_met =
      combined_score >= criteria.combined_score_min &&
        confidence >= criteria.confidence_min

    # Check additional required conditions
    conditions_met =
      if Enum.empty?(criteria.required_conditions) do
        # If no conditions are specified, consider them met
        true
      else
        Enum.all?(criteria.required_conditions, fn condition ->
          evaluation = evaluate_condition(condition, result)
          evaluation
        end)
      end

    # # For debugging high-score cases that don't match
    # if combined_score > 80 && !basic_criteria_met do
    #   IO.puts(
    #     "High score didn't meet basic criteria: score=#{combined_score}, confidence=#{confidence}, min_required=(#{criteria.combined_score_min}, #{criteria.confidence_min})"
    #   )
    # end

    # if combined_score > 80 && basic_criteria_met && !conditions_met do
    #   IO.puts(
    #     "High score met basic criteria but failed conditions check: #{inspect(result.metrics)}"
    #   )
    # end

    result = basic_criteria_met && conditions_met

    # For extreme cases, log the classification result
    # if combined_score > 95 do
    #   IO.puts("Classification result for score #{combined_score}: #{result}")
    # end

    result
  end

  defp evaluate_condition({:or, conditions}, result) do
    # Debug high score OR conditions
    if result.combined_score > 90 do
      results = Enum.map(conditions, fn c -> {c, evaluate_condition(c, result)} end)
      # IO.puts("OR condition results for score #{result.combined_score}: #{inspect(results)}")
    end

    Enum.any?(conditions, fn condition ->
      evaluate_condition(condition, result)
    end)
  end

  defp evaluate_condition({:and, conditions}, result) do
    # Debug high score AND conditions
    if result.combined_score > 90 do
      results = Enum.map(conditions, fn c -> {c, evaluate_condition(c, result)} end)
      # IO.puts("AND condition results for score #{result.combined_score}: #{inspect(results)}")
    end

    Enum.all?(conditions, fn condition ->
      evaluate_condition(condition, result)
    end)
  end

  defp evaluate_condition({:any_metric_above, threshold}, result) do
    metrics = [
      result.metrics.tfidf,
      result.metrics.euclidean,
      result.metrics.manhattan,
      result.metrics.domain,
      result.overlap_percent
    ]

    Enum.any?(metrics, fn metric -> metric >= threshold end)
  end

  defp evaluate_condition({metric, operator, threshold}, result) do
    value = get_metric_value(metric, result)
    apply_operator(value, operator, threshold)
  end

  defp get_metric_value(:tfidf, result), do: result.metrics.tfidf
  defp get_metric_value(:euclidean, result), do: result.metrics.euclidean
  defp get_metric_value(:manhattan, result), do: result.metrics.manhattan
  defp get_metric_value(:domain, result), do: result.metrics.domain
  defp get_metric_value(:keyword_overlap, result), do: result.overlap_percent || 0
  defp get_metric_value(:overlap_percent, result), do: result.overlap_percent || 0
  defp get_metric_value(:combined_score, result), do: result.combined_score
  defp get_metric_value(:confidence, result), do: result.confidence || 0
  defp get_metric_value(_, _), do: 0

  defp apply_operator(value, :>=, threshold), do: value >= threshold
  defp apply_operator(value, :>, threshold), do: value > threshold
  defp apply_operator(value, :<=, threshold), do: value <= threshold
  defp apply_operator(value, :<, threshold), do: value < threshold
  defp apply_operator(value, :==, threshold), do: value == threshold

  # Handle nil results in override rules
  defp check_override_rules(nil), do: nil

  defp check_override_rules(result) do
    Enum.find_value(override_rules(), fn {_rule_name, condition_fn, match_type} ->
      if condition_fn.(result), do: match_type, else: nil
    end)
  end

  # Handle nil results in confidence calculation
  defp calculate_confidence_for_match(_match_type, nil), do: 0

  defp calculate_confidence_for_match(match_type, result) do
    base_criteria = @classification_matrix[match_type]

    # How much above the threshold are we?
    score_delta = result.combined_score - base_criteria.combined_score_min

    # Convert to a 0-100 scale for this match type
    next_threshold = get_next_threshold(match_type)
    score_range = next_threshold - base_criteria.combined_score_min

    if score_range <= 0 do
      # For exact match where there's no higher category
      min(100, result.confidence)
    else
      # For other categories, scale by how far above threshold
      scaled_confidence = min(100, base_criteria.confidence_min + score_delta / score_range * 30)
      max(result.confidence * 0.8, scaled_confidence)
    end
    |> round()
  end

  defp get_next_threshold(:exact_match), do: 100

  defp get_next_threshold(:strong_match),
    do: @classification_matrix.exact_match.combined_score_min

  defp get_next_threshold(:moderate_match),
    do: @classification_matrix.strong_match.combined_score_min

  defp get_next_threshold(:weak_match),
    do: @classification_matrix.moderate_match.combined_score_min

  defp get_next_threshold(:no_match), do: @classification_matrix.weak_match.combined_score_min

  defp apply_confidence_adjustments(match_type, confidence, result) do
    cond do
      # Near threshold with high confidence - promote
      is_borderline_high?(match_type, result) && confidence >= 95 ->
        promote_match(match_type)

      # Near threshold with low confidence - demote
      is_borderline_low?(match_type, result) && confidence < 70 ->
        demote_match(match_type)

      true ->
        match_type
    end
  end

  # Handle nil results in borderline checks
  defp is_borderline_high?(_match_type, nil), do: false

  defp is_borderline_high?(match_type, result) do
    next_type = promote_match(match_type)
    next_threshold = @classification_matrix[next_type][:combined_score_min]

    result.combined_score >= next_threshold - 5
  end

  defp is_borderline_low?(_match_type, nil), do: false

  defp is_borderline_low?(match_type, result) do
    threshold = @classification_matrix[match_type][:combined_score_min]

    result.combined_score <= threshold + 5
  end

  defp promote_match(:no_match), do: :weak_match
  defp promote_match(:weak_match), do: :moderate_match
  defp promote_match(:moderate_match), do: :strong_match
  defp promote_match(:strong_match), do: :exact_match
  defp promote_match(:exact_match), do: :exact_match

  defp demote_match(:exact_match), do: :strong_match
  defp demote_match(:strong_match), do: :moderate_match
  defp demote_match(:moderate_match), do: :weak_match
  defp demote_match(:weak_match), do: :no_match
  defp demote_match(:no_match), do: :no_match

  defp get_match_rank(:exact_match), do: 4
  defp get_match_rank(:strong_match), do: 3
  defp get_match_rank(:moderate_match), do: 2
  defp get_match_rank(:weak_match), do: 1
  defp get_match_rank(:no_match), do: 0

  @doc """
  Extracts keywords using spaCy for better results.
  Language defaults to "de" (German).
  """
  def extract_keywords_with_spacy(text, language \\ "de") do
    if GW.test_connection(:statement_scoring) do
      case GW.call(:statement_scoring, :extract_keywords_spacy, [text, language], nil, 30_000) do
        {:ok, keywords} ->
          {:ok, format_keywords(keywords)}

        {:error, reason} ->
          {:error, "SpaCy keyword extraction failed: #{inspect(reason)}"}
      end
    else
      {:error, "Python connection failed"}
    end
  end

  @doc """
  Gets alternative similarity scores between two statements using multiple methods.
  Returns a map with different similarity measures.
  """
  def get_alternative_scores(statement1, statement2) do
    if GW.test_connection(:statement_scoring) do
      case GW.call(
             :statement_scoring,
             :get_alternative_similarity_scores,
             [statement1, statement2],
             %{reload: true},
             60_000
           ) do
        {:ok, scores} ->
          # Convert to a more friendly Elixir map
          scores_map =
            scores
            |> Enum.map(fn
              {key, value} when is_binary(key) -> {key, value}
              {key, value} -> {to_string(key), value}
            end)
            |> Map.new()

          {:ok, scores_map}

        {:error, reason} ->
          {:error, "Alternative scoring failed: #{inspect(reason)}"}
      end
    else
      {:error, "Python connection failed"}
    end
  end

  # Helper function to convert character lists to readable strings
  defp format_keywords(keywords) do
    Enum.map(keywords, fn keyword ->
      if is_list(keyword) do
        List.to_string(keyword)
      else
        keyword
      end
    end)
  end

  defp format_keyword_list(keywords) when is_list(keywords) and length(keywords) > 0 do
    keywords
    |> Enum.map(fn kw -> "  • #{kw}" end)
    |> Enum.join("\n")
  end

  defp format_keyword_list(_), do: "  None found"
end
