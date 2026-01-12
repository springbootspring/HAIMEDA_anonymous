defmodule PreProcessing.Logic do
  alias PreProcessing.{Tableaux, TableauxSolver, UniverseState}
  require Tableaux
  import Tableaux
  import TableauxSolver, only: [solve: 1, solve: 2]

  # Remove all solve helper functions

  # Use TableauxSolver.solve directly:
  # Examples:
  # - TableauxSolver.solve(term, debug: print_debug)  # returns {boolean, MapSet}
  # - TableauxSolver.solve({:fun, :extract_cond, [term]}, debug: print_debug)  # returns [String]
  # - elem(TableauxSolver.solve(term, debug: print_debug), 0)  # get just boolean result

  @moduledoc """
  Satisfy the correctness of the decision made by a LLM using a Tableaux prover.

  Example inputs:

    Example core condition:

      "has_example_input": {
            "ID": "c1",
            "type": "binary",
            "required": true,
            "score": 8,
            "penalty": 5,
            "feedback": "Input must contain example text to match"
          }

    Example higher-level condition:

          "minimum_score": {
            "ID": "at1",
            "type": "minimum",
            "eval_operation": "combine",
            "eval_on": ["attribute", "satisfaction"],
            "required": true,
            "attribute": "score",
            "dimensions": ["core_conditions", "keywords"],
            "value": 15,
            "feedback": "At least one input requirement must be met."
          }

    Example satisfied_conditions_IDs (core conditions):

          ["c1", "c2", "c4", "k1", "a4"]

    Example program workflow:

      -

  """

  @doc """
  Converts conditions to logical formula and checks satisfiability
  """

  def solve_conditions(conditions, meta_information, sat_condition_IDs, print_debug) do
    # Start or reset the UniverseState GenServer
    {:ok, _pid} = UniverseState.start_link()

    proof_order = meta_information["proof_order"]
    # dimensions = meta_information["dimensions"]
    base_sets = meta_information["base_sets"]
    abbreviations = meta_information["abbreviations"]
    functions = meta_information["functions"]

    # Initialize base sets – start with c_all

    c_all =
      Enum.reduce(proof_order, %{}, fn condition_category, acc ->
        Map.put(acc, abbreviations[condition_category], MapSet.new())
      end)

    c_sat = MapSet.new(sat_condition_IDs)

    # Fill c_all sets with condition IDs from each category
    c_all =
      Enum.reduce(conditions, c_all, fn {category, content}, acc ->
        set_key = abbreviations[category]

        case content do
          conditions when is_map(conditions) ->
            # Handle map-type conditions (like core_conditions, meta_conditions, etc.)
            condition_ids =
              conditions
              |> Map.values()
              |> Enum.map(& &1["ID"])
              |> MapSet.new()

            Map.put(acc, set_key, condition_ids)

          conditions when is_list(conditions) ->
            # Handle list-type conditions (keywords, antonyms)
            condition_ids =
              conditions
              |> Enum.map(& &1["ID"])
              |> MapSet.new()

            Map.put(acc, set_key, condition_ids)

          _ ->
            acc
        end
      end)

    pre_checked = meta_information["pre_checked"]
    # shortcuts = meta_information["ID_abbreviations"]

    c_eval =
      Enum.reduce(pre_checked, MapSet.new(), fn dimension, acc ->
        abbr = abbreviations[dimension]
        dimension_ids = c_all[abbreviations[dimension]]

        # Filter IDs by their prefix and check if they're in c_sat
        unsatisfied =
          dimension_ids
          |> Enum.filter(fn id ->
            # Check if ID starts with the abbreviation (e.g., "c1", "k2", "a3")
            String.starts_with?(id, abbr)
          end)
          |> MapSet.new()

        MapSet.union(acc, unsatisfied)
      end)

    c_all = Map.put(c_all, "c_sat", c_sat)
    c_all = Map.put(c_all, "c_eval", c_eval)

    # possible point to trigger functions with "on_event" : "condition_satisfied"

    attribute_keys =
      Enum.reduce(base_sets["attributes"], %{}, fn attr, acc ->
        Map.put(acc, attr, MapSet.new())
      end)

    filled_attributes =
      Enum.reduce(proof_order, attribute_keys, fn condition_category, sets_acc ->
        case Map.get(conditions, condition_category) do
          nil ->
            sets_acc

          category_conditions when is_map(category_conditions) ->
            Enum.reduce(category_conditions, sets_acc, fn {_name, condition}, inner_acc ->
              Enum.reduce(base_sets["attributes"], inner_acc, fn attr, attr_acc ->
                if Map.get(condition, attr) != nil and Map.get(condition, attr) != false do
                  Map.update(attr_acc, attr, MapSet.new([condition["ID"]]), fn set ->
                    MapSet.put(set, condition["ID"])
                  end)
                else
                  attr_acc
                end
              end)
            end)

          category_conditions when is_list(category_conditions) ->
            # Handle list-type conditions (keywords, antonyms)
            Enum.reduce(category_conditions, sets_acc, fn condition, inner_acc ->
              Enum.reduce(base_sets["attributes"], inner_acc, fn attr, attr_acc ->
                if Map.get(condition, attr) != nil and Map.get(condition, attr) != false do
                  Map.update(attr_acc, attr, MapSet.new([condition["ID"]]), fn set ->
                    MapSet.put(set, condition["ID"])
                  end)
                else
                  attr_acc
                end
              end)
            end)
        end
      end)

    attributes = Map.merge(attribute_keys, filled_attributes)

    should_sat =
      Enum.reduce(proof_order, MapSet.new(), fn condition_category, set ->
        case Map.get(conditions, condition_category) do
          nil ->
            set

          category_conditions when is_map(category_conditions) ->
            Enum.reduce(category_conditions, set, fn {_name, condition}, inner_acc ->
              if Map.get(condition, "results_in") == "satisfaction" do
                MapSet.put(inner_acc, condition["ID"])
              else
                inner_acc
              end
            end)

          category_conditions when is_list(category_conditions) ->
            # Handle list-type conditions (keywords, antonyms)
            Enum.reduce(category_conditions, set, fn condition, inner_acc ->
              if Map.get(condition, "results_in") == "satisfaction" do
                MapSet.put(inner_acc, condition["ID"])
              else
                inner_acc
              end
            end)
        end
      end)

    # Create map with all MapSets
    all_sets = %{}
    all_sets = Map.merge(all_sets, c_all)
    all_sets = Map.merge(all_sets, attributes)
    all_sets = Map.put(all_sets, "should_sat", should_sat)

    all_sets =
      Map.put(
        all_sets,
        "c_all",
        Enum.reduce(proof_order, MapSet.new(), fn condition_category, acc ->
          key = abbreviations[condition_category]
          MapSet.union(acc, all_sets[key])
        end)
      )

    # Store initial universe state
    UniverseState.update_sets(all_sets)

    # Only print when debug is enabled
    if print_debug do
      IO.inspect(UniverseState.get_all_sets(), label: "All sets")
    end

    # Check conditions based on proof order and generate provable terms
    {terms, parsed_terms, feedback} =
      Enum.reduce(proof_order, {[], [], []}, fn condition_category,
                                                {outer_terms, outer_parsed, feedback_acc} ->
        case Map.get(conditions, condition_category) do
          nil ->
            {outer_terms, outer_parsed, feedback_acc}

          category_conditions when is_map(category_conditions) ->
            acc_result =
              Enum.reduce(
                category_conditions,
                {outer_terms, outer_parsed, feedback_acc},
                fn {cond_name, condition}, {terms, parsed, feedback} ->
                  acc_sets = UniverseState.get_all_sets()
                  cond_type = Map.get(condition, "type")
                  cond_id = Map.get(condition, "ID")

                  if print_debug do
                    IO.inspect(cond_id, label: "Evaluating Condition ID")
                  end

                  # for higher-level conditions, that involve actions on other conditions
                  {condition_clause, parsed_condition_clause} =
                    if Map.get(condition, "eval_function") != nil do
                      eval_function = Map.get(condition, "eval_function")
                      eval_on = Map.get(condition, "eval_on")

                      {dimensions_clause, parsed_dimensions_clause} =
                        case Map.get(condition, "eval_dimensions") do
                          [single_dim] ->
                            # For single dimension, just return its abbreviation
                            {{:set, String.to_atom(abbreviations[single_dim]),
                              acc_sets[abbreviations[single_dim]]}, abbreviations[single_dim]}

                          multiple_dims when is_list(multiple_dims) ->
                            # Build combined set from multiple dimensions
                            {combined_set, dims_str} =
                              multiple_dims
                              |> Enum.map(fn dim ->
                                abbr = abbreviations[dim]
                                set = acc_sets[abbr]
                                {{:set, String.to_atom(abbr), set}, abbr}
                              end)
                              |> Enum.reduce(fn {set1, name1}, {set2, name2} ->
                                {disj(set1, set2), "#{name1} ∪ #{name2}"}
                              end)

                            {combined_set, "(#{dims_str})"}

                          _ ->
                            {nil, nil}
                        end

                      {eval_on_clause, parsed_eval_on_clause} =
                        case eval_on do
                          "positive_condition" ->
                            # all proved conditions, not including "falsy" ones:
                            # 1. Are in c_sat and should be satisfied (in should_sat)
                            # 2. Are not in c_sat but should also no be satisfied (not in should_sat)
                            {cond_clause, parsed_cond_clause} =
                              {disj(
                                 conj(
                                   {:set, String.to_atom("c_sat"), acc_sets["c_sat"]},
                                   {:set, String.to_atom("should_sat"), acc_sets["should_sat"]}
                                 ),
                                 conj(
                                   neg({:set, String.to_atom("c_sat"), acc_sets["c_sat"]}),
                                   neg(
                                     {:set, String.to_atom("should_sat"), acc_sets["should_sat"]}
                                   )
                                 )
                               ), "(c_sat ∩ should_sat) ∪ (¬c_sat ∩ ¬should_sat)"}

                            # extract condition_IDs
                            {{:fun, :extract_cond, [conj(dimensions_clause, cond_clause)]},
                             "#{parsed_dimensions_clause} ∩ (#{parsed_cond_clause})"}

                          "negative_condition" ->
                            # Find conditions that:
                            # 1. Are in c_sat but should not be satisfied (not in should_sat)
                            # 2. Are not in c_sat but should be satisfied (in should_sat)
                            {cond_clause, parsed_cond_clause} =
                              {disj(
                                 # First part: c_sat ∧ ¬should_sat
                                 # This finds elements that are satisfied but shouldn't be
                                 conj(
                                   {:set, String.to_atom("c_sat"), acc_sets["c_sat"]},
                                   neg(
                                     {:set, String.to_atom("should_sat"), acc_sets["should_sat"]}
                                   )
                                 ),
                                 # Second part: c_unsat ∧ should_sat
                                 # This finds elements that aren't satisfied but should be
                                 conj(
                                   neg({:set, String.to_atom("c_sat"), acc_sets["c_sat"]}),
                                   {:set, String.to_atom("should_sat"), acc_sets["should_sat"]}
                                 )
                               ), "(c_sat ∩ ¬should_sat) ∪ (¬c_sat ∩ should_sat)"}

                            {{:fun, :extract_cond, [conj(dimensions_clause, cond_clause)]},
                             "#{parsed_dimensions_clause} ∩ (#{parsed_cond_clause})"}

                          "attribute" ->
                            # has additional eval_param: the attribute
                            attribute_key = Map.get(condition, "eval_param")
                            has_attribute_set = attributes[attribute_key]

                            # Only print when debug is enabled
                            if print_debug do
                              IO.inspect(has_attribute_set, label: "Has attribute set")
                            end

                            # needs brackets?
                            {attr_cond, parsed_attr_cond} =
                              case attribute_key do
                                "score" ->
                                  {disj(
                                     conj(
                                       conj(
                                         {:set, String.to_atom("c_sat"), acc_sets["c_sat"]},
                                         {:set, String.to_atom("should_sat"),
                                          acc_sets["should_sat"]}
                                       ),
                                       {:set, String.to_atom("score"), acc_sets["score"]}
                                     ),
                                     conj(
                                       conj(
                                         neg({:set, String.to_atom("c_sat"), acc_sets["c_sat"]}),
                                         neg(
                                           {:set, String.to_atom("should_sat"),
                                            acc_sets["should_sat"]}
                                         )
                                       ),
                                       {:set, String.to_atom("score"), acc_sets["score"]}
                                     )
                                   ),
                                   "(c_sat ∩ should_sat ∩ score) ∪ (¬c_sat ∩ ¬should_sat ∩ score)"}

                                "penalty" ->
                                  {disj(
                                     conj(
                                       conj(
                                         {:set, String.to_atom("c_sat"), acc_sets["c_sat"]},
                                         neg(
                                           {:set, String.to_atom("should_sat"),
                                            acc_sets["should_sat"]}
                                         )
                                       ),
                                       {:set, String.to_atom("penalty"), acc_sets["penalty"]}
                                     ),
                                     conj(
                                       conj(
                                         neg({:set, String.to_atom("c_sat"), acc_sets["c_sat"]}),
                                         {:set, String.to_atom("should_sat"),
                                          acc_sets["should_sat"]}
                                       ),
                                       {:set, String.to_atom("penalty"), acc_sets["penalty"]}
                                     )
                                   ),
                                   "(c_sat ∩ ¬should_sat ∩ penalty) ∪ (¬c_sat ∩ should_sat ∩ penalty)"}

                                "required" ->
                                  {
                                    conj(
                                      {:set, String.to_atom("c_eval"), acc_sets["c_eval"]},
                                      {:set, String.to_atom("required"), acc_sets["required"]}
                                    ),
                                    "(c_eval ∩ required)"
                                  }
                              end

                            {before_extraction, parsed_before_extraction} =
                              {conj(dimensions_clause, attr_cond),
                               "#{parsed_dimensions_clause} ∩ (#{parsed_attr_cond})"}

                            if print_debug do
                              IO.inspect(before_extraction, label: "Before extraction")

                              IO.inspect(solve(before_extraction),
                                label: "Before extraction solved"
                              )

                              IO.puts("\n")
                            end

                            # Get matching condition IDs directly from solver
                            matching_condition_ids =
                              solve({:fun, :extract_cond, [before_extraction]})

                            if print_debug do
                              IO.inspect(matching_condition_ids, label: "matching_condition_ids")

                              IO.inspect(
                                extract_attribute_values(
                                  conditions,
                                  matching_condition_ids,
                                  attribute_key
                                ),
                                label: "Extracted #{attribute_key} values"
                              )
                            end

                            # Extract attribute values from matching conditions
                            extracted_attributes =
                              extract_attribute_values(
                                conditions,
                                matching_condition_ids,
                                attribute_key
                              )

                            # Now use the extracted attributes in the formula
                            {{:attributes, [extracted_attributes, before_extraction]},
                             "extract_#{attribute_key}(#{parsed_before_extraction})"}
                        end

                      # precondition: all conditions of dimensions have to be evaluated already (be in c_eval)
                      ## don't add precondition to condition_clause as it will change final result!
                      {pre_cond, parsed_pre_cond} =
                        {{:fun, :subset,
                          [
                            dimensions_clause,
                            {:set, String.to_atom("c_eval"), acc_sets["c_eval"]}
                          ]}, "#{parsed_dimensions_clause} ⊆ c_eval"}

                      if print_debug do
                        IO.inspect(parsed_pre_cond, label: "\nParsed precondition")

                        IO.inspect(TableauxSolver.solve(pre_cond, debug: print_debug),
                          label: "\nPrecondition solved"
                        )
                      end

                      if elem(TableauxSolver.solve(pre_cond, debug: print_debug), 0) do
                        # only gets result of solver

                        # form condition based on type and eval_function
                        {type_condition, parsed_type_condition} =
                          case eval_function do
                            "sum" ->
                              # sum on all conditions or attribute values
                              {{:fun, :sum, eval_on_clause}, "sum(#{parsed_eval_on_clause})"}

                            "forall" ->
                              # compare pairwise all conditions or attribute values against a value
                              {{:fun, :forall, eval_on_clause},
                               "∀c ∈ (#{parsed_eval_on_clause}) . c"}

                            "subset" ->
                              # check if conditions with specific attribute (eval_param) are a subset of eval_on conditions
                              # e.g. check if conditions with attribute "required" are a subset of "positive_conditions"
                              eval_param = Map.get(condition, "eval_param")
                              eval_param_conditions = acc_sets[eval_param]

                              {eval_param_conditions, parsed_eval_param_conditions} =
                                {conj(
                                   {:set, String.to_atom("c_eval"), acc_sets["c_eval"]},
                                   {:set, String.to_atom(eval_param), eval_param_conditions}
                                 ), "(c_eval ∩ #{eval_param})"}

                              {{:fun, :subset, [eval_param_conditions, eval_on_clause]},
                               "#{parsed_eval_param_conditions} ⊆ #{parsed_eval_on_clause}"}
                          end

                        cond_value = condition["value"]

                        {type_operation, parsed_type_operation} =
                          case cond_type do
                            "minimum" ->
                              {{:fun, :geq, [type_condition, cond_value]},
                               "#{parsed_type_condition} ≥ #{cond_value}"}

                            "maximum" ->
                              {{:fun, :leq, [type_condition, cond_value]},
                               "#{parsed_type_condition} ≤ #{cond_value}"}

                            "equal" ->
                              {{:fun, :eq, [type_condition, cond_value]},
                               "#{parsed_type_condition} = #{cond_value}"}

                            "range" ->
                              # Use pattern matching to extract range bounds
                              [min_val, max_val] = cond_value

                              {{:conj, {:fun, :geq, [type_condition, min_val]},
                                {:fun, :leq, [type_condition, max_val]}},
                               "#{parsed_type_condition} ∈ [#{min_val}, #{max_val}]"}
                          end

                        if print_debug do
                          IO.inspect(type_operation, label: "\nType operation")
                          IO.inspect(parsed_type_operation, label: "\nParsed type operation")

                          IO.inspect(solve(type_operation, debug: print_debug),
                            label: "\nType operation solved"
                          )

                          IO.puts("\n")
                        end

                        {type_operation, parsed_type_operation}
                      else
                        if print_debug do
                          IO.puts(
                            "Condition #{cond_id} waiting for evaluation of conditions of depending dimensions."
                          )
                        end

                        {neg(to_cond(cond_id)), "¬#{cond_id}"}
                      end
                    else
                      {pre_cond, parsed_pre_cond} =
                        {
                          disj(
                            # First part: check that {cond_id} ∈ (c_sat ∧ should_sat)
                            subset(
                              {:cond, cond_id},
                              conj(
                                {:set, String.to_atom("c_sat"), acc_sets["c_sat"]},
                                {:set, String.to_atom("should_sat"), acc_sets["should_sat"]}
                              )
                            ),
                            # Second part: check that {cond_id} ∈ (¬c_sat ∧ ¬should_sat) )
                            subset(
                              {:cond, cond_id},
                              conj(
                                neg({:set, String.to_atom("c_sat"), acc_sets["c_sat"]}),
                                neg({:set, String.to_atom("should_sat"), acc_sets["should_sat"]})
                              )
                            )
                          ),
                          "#{cond_id} ∈ (c_sat ∩ should_sat) ∪ #{cond_id} ∈ (¬c_sat ∩ ¬should_sat)"
                        }

                      {pre_cond, parsed_pre_cond}
                    end

                  ## execution of term satisfiability checking, and updating sets:

                  {updated_term, updated_parsed_term} =
                    case TableauxSolver.solve(condition_clause, debug: print_debug) do
                      {true, result_set} ->
                        result_value =
                          case MapSet.to_list(result_set) |> List.first() do
                            x when is_number(x) -> " [res: #{x}]"
                            _ -> ""
                          end

                        case Map.get(condition, "results_in") do
                          "satisfaction" ->
                            if print_debug do
                              IO.puts(
                                "Condition #{cond_id} satisfied. [evals_to: sat, intended: sat]\n"
                              )
                            end

                            UniverseState.update_set(
                              "c_sat",
                              MapSet.put(acc_sets["c_sat"], cond_id)
                            )

                            UniverseState.update_set(
                              "c_eval",
                              MapSet.put(acc_sets["c_eval"], cond_id)
                            )

                            {terms ++ [%{cond_id => condition_clause}],
                             parsed ++
                               [
                                 "#{cond_name} [sat]#{result_value}: #{parsed_condition_clause}"
                               ]}

                          "dissatisfaction" ->
                            if print_debug do
                              IO.puts(
                                "Condition #{cond_id} not satisfied. [evals_to: sat, intended: unsat]\n"
                              )
                            end

                            UniverseState.update_set(
                              "c_eval",
                              MapSet.put(acc_sets["c_eval"], cond_id)
                            )

                            {terms ++ [%{cond_id => condition_clause}],
                             parsed ++
                               [
                                 "#{cond_name} [unsat]#{result_value}: #{parsed_condition_clause}"
                               ]}
                        end

                      {false, result_set} ->
                        result_value =
                          case MapSet.to_list(result_set) |> List.first() do
                            value when is_number(value) -> "[res: #{value}]"
                            _ -> ""
                          end

                        case Map.get(condition, "results_in") do
                          "satisfaction" ->
                            if print_debug do
                              IO.puts(
                                "Condition #{cond_id} not satisfied. [evals_to: unsat, intended: sat]\n"
                              )
                            end

                            UniverseState.update_set(
                              "c_eval",
                              MapSet.put(acc_sets["c_eval"], cond_id)
                            )

                            {terms ++ [%{cond_id => condition_clause}],
                             parsed ++
                               [
                                 "#{cond_name} [unsat]#{result_value}: #{parsed_condition_clause}"
                               ]}

                          "dissatisfaction" ->
                            if print_debug do
                              IO.puts(
                                "Condition #{cond_id} satisfied. [evals_to: unsat, intended: unsat]\n"
                              )
                            end

                            UniverseState.update_set(
                              "c_sat",
                              MapSet.put(acc_sets["c_sat"], cond_id)
                            )

                            UniverseState.update_set(
                              "c_eval",
                              MapSet.put(acc_sets["c_eval"], cond_id)
                            )

                            {terms ++ [%{cond_id => condition_clause}],
                             parsed ++
                               [
                                 "#{cond_name} [sat]#{result_value}: #{parsed_condition_clause}"
                               ]}
                        end
                    end

                  {term_with_triggered_action, parsed_term_with_triggered_action,
                   updated_feedback} =
                    if condition["triggered_action"] != nil do
                      action = condition["triggered_action"]

                      if action["function"] == "feedback" do
                        triggered_function_args = action["args"]
                        triggered_on = action["on_event"]

                        case triggered_on do
                          "satisfaction" ->
                            # Only collect feedback if condition is satisfied
                            if TableauxSolver.solve(condition_clause, debug: print_debug)
                               |> elem(0) do
                              {condition_clause, parsed_condition_clause,
                               feedback ++ triggered_function_args}
                            else
                              {condition_clause, parsed_condition_clause, feedback}
                            end

                          "dissatisfaction" ->
                            # Only collect feedback if condition is not satisfied
                            {result, _} =
                              TableauxSolver.solve(condition_clause, debug: print_debug)

                            if not result do
                              {condition_clause, parsed_condition_clause,
                               feedback ++ triggered_function_args}
                            else
                              {condition_clause, parsed_condition_clause, feedback}
                            end
                        end
                      else
                        # Handle other function types with existing execute_dynamic_function
                        triggered_function = action["function"]
                        triggered_function_args = action["args"]
                        triggered_on = action["on_event"]

                        function_info = meta_information["functions"][triggered_function]
                        function_string = function_info["function"]

                        case triggered_on do
                          "satisfaction" ->
                            # Only execute if condition is satisfied
                            if TableauxSolver.solve(condition_clause, debug: print_debug)
                               |> elem(0) do
                              _ =
                                execute_dynamic_function(function_string, triggered_function_args)
                            end

                          "dissatisfaction" ->
                            # Only execute if condition is not satisfied
                            {result, _} =
                              TableauxSolver.solve(condition_clause, debug: print_debug)

                            if not result do
                              _ =
                                execute_dynamic_function(function_string, triggered_function_args)
                            end
                        end

                        {condition_clause, parsed_condition_clause, feedback}
                      end
                    else
                      {condition_clause, parsed_condition_clause, feedback}
                    end

                  {updated_term, updated_parsed_term, updated_feedback}
                end
              )

            acc_result

          category_conditions when is_list(category_conditions) ->
            # Handle list-type conditions
            {outer_terms, outer_parsed, feedback_acc}
        end
      end)

    # Cleanup
    Process.exit(Process.whereis(UniverseState), :normal)

    # Return both parsed terms and collected feedback
    {parsed_terms, feedback}
  end

  defp execute_dynamic_function(function_string, args) do
    try do
      # Split module and function
      [module_string, function_name] = String.split(function_string, ".", parts: 2)

      # Convert strings to atoms/modules
      module = String.to_existing_atom("Elixir.#{module_string}")
      function = String.to_atom(String.replace(function_name, "(&1)", ""))

      # Special handling for feedback function with color
      if function_string == "IO.puts(&1)" and is_list(args) and length(args) == 2 do
        [message, color] = args

        ansi_color =
          case color do
            "red" -> IO.ANSI.red()
            "yellow" -> IO.ANSI.yellow()
            "green" -> IO.ANSI.green()
            "blue" -> IO.ANSI.blue()
            "magenta" -> IO.ANSI.magenta()
            "cyan" -> IO.ANSI.cyan()
            # default color
            _ -> IO.ANSI.white()
          end

        IO.puts("#{ansi_color}#{message}#{IO.ANSI.reset()}")
        {:ok, true}
      else
        # Apply the function dynamically for other cases
        apply(module, function, args)
        {:ok, true}
      end
    rescue
      e ->
        IO.puts("Error executing function #{function_string}: #{inspect(e)}")
        {:error, e}
    end
  end

  defp conditions_to_formula(conditions, satisfied_conditions_IDs) do
    # Convert list of conditions to a single conjunctive formula and assign to Maps (set membership)

    required_set = MapSet.new()
    satisfied_set = MapSet.new()

    Enum.each(conditions, fn condition ->
      case condition["required"] do
        true -> required_set = MapSet.put(required_set, condition["ID"])
        false -> nil
      end
    end)

    Enum.each(satisfied_conditions_IDs, fn ID ->
      satisfied_set = MapSet.put(satisfied_set, ID)
    end)

    conditions
    |> Enum.map(&condition_to_term/1)
    |> Enum.reduce(&Tableaux.conj(&1, &2))

    # caluculate score on all conditions (satisfied, and not satisfied)
  end

  defp condition_to_term(%{condition: name, satisfied: value}) do
    {:atom, String.to_atom("#{name}_#{value}")}
  end

  defp extract_attribute_values(conditions, matching_ids, attribute_key) do
    conditions
    |> Map.values()
    |> Enum.flat_map(fn
      conditions when is_map(conditions) -> Map.values(conditions)
      conditions when is_list(conditions) -> conditions
      _ -> []
    end)
    |> Enum.filter(fn
      %{"ID" => id} -> id in matching_ids
      _ -> false
    end)
    |> Enum.map(& &1[attribute_key])
    |> Enum.reject(&is_nil/1)
  end
end
