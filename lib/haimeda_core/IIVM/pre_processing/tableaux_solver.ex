defmodule PreProcessing.TableauxSolver do
  alias PreProcessing.{Tableaux, UniverseState}
  require Tableaux
  import Tableaux, except: [subset: 2]

  @type result :: {boolean(), MapSet.t()} | [String.t()]

  # Add a type parameter to control return format
  def solve(formula, opts \\ [])

  # Handle extract_cond: return list of IDs
  def solve({:fun, :extract_cond, [term]} = formula, opts) when is_list(opts) do
    debug = Keyword.get(opts, :debug, false)
    {_result, set} = solve_term(term, debug)

    # Convert set elements to list of IDs
    set
    |> MapSet.to_list()
    |> Enum.map(fn
      {:cond, id} -> id
      id when is_binary(id) -> id
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  # Update sum handler to handle attributes
  def solve({:fun, :sum, term}, opts) do
    debug = if is_list(opts), do: Keyword.get(opts, :debug, false), else: false

    case term do
      # Handle attribute values directly
      {:attributes, [values, _full_term]} when is_list(values) ->
        if debug do
          IO.puts("Summing attribute values: #{inspect(values)}")
        end

        sum = Enum.sum(values)
        {sum, MapSet.new([sum])}

      # Handle regular terms (existing behavior)
      _ ->
        case solve(term, debug: debug) do
          list when is_list(list) ->
            result = length(list)
            {result, MapSet.new(list)}

          {_bool, set} ->
            result = MapSet.size(set)
            {result, set}
        end
    end
  end

  # Update comparison handler to exclude forall terms
  def solve({:fun, op, [x, y]}, opts)
      when op in [:lt, :gt, :leq, :geq, :eq, :neq] and
             not (elem(x, 0) == :fun and elem(x, 1) == :forall) do
    debug = if is_list(opts), do: Keyword.get(opts, :debug, false), else: false

    # Get result from first term, preserving boolean values
    {x_value, _} =
      case solve(x, debug: debug) do
        # Preserve boolean values
        {bool, _} when is_boolean(bool) -> {bool, MapSet.new([bool])}
        {num, set} when is_number(num) -> {num, set}
        num when is_number(num) -> {num, MapSet.new([num])}
        # Default to false instead of 0 for unrecognized terms
        _ -> {false, MapSet.new()}
      end

    # Preserve literal boolean values
    y_value =
      cond do
        is_boolean(y) -> y
        is_number(y) -> y
        # Default to false instead of 0
        true -> false
      end

    if debug do
      IO.puts("Comparing #{inspect(x_value)} #{op} #{inspect(y_value)}")
    end

    # Use the compare_values helper which already handles boolean comparisons
    result = compare_values(op, x_value, y_value)
    # Return the boolean result in the set
    {result, MapSet.new([result])}
  end

  # Handle forall terms at solve level first
  def solve({:fun, :forall, term}, opts) do
    debug = if is_list(opts), do: Keyword.get(opts, :debug, false), else: false
    solve_term({:fun, :forall, term}, debug)
  end

  # Handle feedback function
  def solve({:fun, :feedback, [msg]}, opts) do
    debug = Keyword.get(opts, :debug, false)
    if debug, do: IO.puts("\nFeedback: #{msg}\n")
    {true, MapSet.new()}
  end

  # Update solve function to handle triggered_action negation
  def solve({:callback, condition_clause, callback}, opts) do
    debug = Keyword.get(opts, :debug, false)
    {result, set} = solve_term(condition_clause, debug)

    if debug do
      IO.puts("Callback result: #{result}")
    end

    {result, set}
  end

  # Preserve old boolean debug parameter for backwards compatibility
  def solve(formula, debug) when is_boolean(debug) do
    solve(formula, debug: debug)
  end

  # Default case - returns {boolean, MapSet} tuple
  def solve(formula, opts) when is_list(opts) do
    debug = Keyword.get(opts, :debug, false)
    solve_term(formula, debug)
  end

  def solve(formula, debug) when is_boolean(debug) do
    solve(formula, debug: debug)
  end

  # Base cases for direct sets
  defp solve_term({:set, _name, set}, _debug) when is_map(set) do
    {true, set}
  end

  # Handle bracketed expressions with priority
  defp solve_term({:bracket, expr}, debug) do
    solve_term(expr, debug)
  end

  # Handle attribute values at solve_term level
  defp solve_term({:fun, :sum, {:attributes, [values, _]} = term}, debug) do
    if debug do
      IO.puts("Solving attribute sum for values: #{inspect(values)}")
    end

    sum = Enum.sum(values)
    {sum, MapSet.new([sum])}
  end

  # Handle range check to always preserve value
  defp solve_term({:conj, {:fun, :geq, [val, min]}, {:fun, :leq, [val, max]}}, debug) do
    # Get value and ensure it's numeric
    {value, _} = solve_term(val, debug)
    value = if is_number(value), do: value, else: 0

    if debug do
      IO.puts("Range check: #{value} in [#{min}, #{max}]")
    end

    result = value >= min and value <= max

    if debug do
      IO.puts("Range result: #{result} (value: #{value})")
    end

    # Always include the value in result set
    {result, MapSet.new([value])}
  end

  # Handle conjunctions
  defp solve_term({:conj, x, y}, debug) do
    {x_result, x_set} = solve_term(x, debug)
    {y_result, y_set} = solve_term(y, debug)

    result_set = MapSet.intersection(x_set, y_set)
    {x_result and y_result and not MapSet.equal?(result_set, MapSet.new()), result_set}
  end

  # Handle disjunctions
  defp solve_term({:disj, x, y}, debug) do
    {x_result, x_set} = solve_term(x, debug)
    {y_result, y_set} = solve_term(y, debug)

    result_set = MapSet.union(x_set, y_set)
    {x_result or y_result, result_set}
  end

  # Handle negations
  defp solve_term({:neg, {:set, name, set}}, debug) do
    universe = UniverseState.get_set("c_all")
    complement = MapSet.difference(universe || MapSet.new(), set)
    {true, complement}
  end

  # Update logic for handling negation results
  defp solve_term({:neg, term}, debug) do
    {result, set} = solve_term(term, debug)
    universe = UniverseState.get_set("c_all")
    comp_set = MapSet.difference(universe || MapSet.new(), set)
    # Only negate the boolean part
    {not result, comp_set}
  end

  # Handle subset operations
  defp solve_term({:fun, :subset, [set1, set2]}, debug) do
    {r1, s1} = solve_term(set1, debug)
    {r2, s2} = solve_term(set2, debug)

    is_subset = MapSet.subset?(s1, s2)

    if debug do
      IO.puts("is_subset check: #{inspect(s1)} ⊆ #{inspect(s2)} = #{is_subset}")
    end

    {is_subset, if(is_subset, do: s1, else: MapSet.new())}
  end

  # Update extract_cond handler to match new return type
  defp solve_term({:fun, :extract_cond, [term]}, debug) do
    # Keep internal handling consistent
    {result, set} = solve_term(term, debug)
    {result, set}
  end

  # Handle conditions
  defp solve_term({:cond, id}, _debug) do
    {true, MapSet.new([id])}
  end

  # Add specific handler for forall terms
  defp solve_term({:fun, :forall, {:attributes, [values, _set]} = term}, debug) do
    if debug do
      IO.puts("\nForall direct evaluation:")
      IO.puts("  Values: #{inspect(values)}")
    end

    # Return values directly
    {values, MapSet.new(values)}
  end

  # Add handler for forall comparison operations
  defp solve_term({:fun, op, [{:fun, :forall, _} = forall_term, expected]}, debug)
       when op in [:lt, :gt, :leq, :geq, :eq, :neq] do
    {values, _set} = solve_term(forall_term, debug)

    if debug do
      IO.puts("\nForall comparison:")
      IO.puts("  Values: #{inspect(values)}")
      IO.puts("  Operation: #{op}")
      IO.puts("  Expected: #{inspect(expected)}")
    end

    # Handle list of values - ensure it's not empty
    result =
      if Enum.empty?(values) do
        # If no values, forall is vacuously true
        true
      else
        # Only true if all elements satisfy the condition
        Enum.all?(values, fn v -> compare_values(op, v, expected) end)
      end

    if debug do
      IO.puts("  Result: #{result}")
    end

    {result, MapSet.new([expected])}
  end

  # Add forall helper function for extract_cond scenarios
  defp solve_term({:fun, :forall, {:fun, :extract_cond, [term]}}, debug) do
    # Get the list of condition IDs
    condition_ids = solve({:fun, :extract_cond, [term]}, debug: debug)

    if debug do
      IO.puts("\nForall with extract_cond:")
      IO.puts("  Extracted IDs: #{inspect(condition_ids)}")
    end

    # If list is empty, forall is vacuously true
    result = Enum.empty?(condition_ids) || Enum.all?(condition_ids, fn _ -> true end)

    # Return values directly - each is true by default
    {condition_ids, MapSet.new(condition_ids)}
  end

  # Add debug parameter to all comparison handlers
  defp solve_term({:fun, op, [x, y]}, debug) when op in [:lt, :gt, :leq, :geq, :eq, :neq] do
    # Get values while passing debug flag
    {x_value, x_set} = solve_term(x, debug)

    # Handle literal boolean values differently
    y_value =
      cond do
        # Preserve boolean literals
        is_boolean(y) -> y
        is_number(y) -> y
        true -> solve_term(y, debug) |> elem(0)
      end

    if debug do
      IO.puts("Comparing values: #{inspect(x_value)} #{op} #{inspect(y_value)}")
    end

    result = compare_values(op, x_value, y_value)
    # Always return the boolean result
    {result, MapSet.new([result])}
  end

  # Default case for unmatched terms
  defp solve_term(term, debug) do
    if debug do
      IO.puts("Unhandled term: #{inspect(term)}")
    end

    {false, MapSet.new()}
  end

  # Comparison helpers: handle boolean and numeric comparisons
  defp compare_values(op, x, y) do
    if is_boolean(x) or is_boolean(y) do
      x_bool = !!x
      y_bool = !!y

      case op do
        :eq -> x_bool == y_bool
        :neq -> x_bool != y_bool
        :lt -> not x_bool and y_bool
        :gt -> x_bool and not y_bool
        :leq -> not x_bool or y_bool
        :geq -> x_bool or not y_bool
      end
    else
      case op do
        :eq -> x == y
        :neq -> x != y
        :lt -> x < y
        :gt -> x > y
        :leq -> x <= y
        :geq -> x >= y
      end
    end
  end

  # Range comparison helper
  defp compare_values(:range, value, [min_val, max_val]) do
    value >= min_val and value <= max_val
  end

  # Numeric-only comparison fallback
  defp compare_values(op, x, y) when is_number(x) and is_number(y) do
    case op do
      :eq -> x == y
      :neq -> x != y
      :lt -> x < y
      :gt -> x > y
      :leq -> x <= y
      :geq -> x >= y
    end
  end

  # Default comparison fallback
  defp compare_values(_op, _x, _y) do
    false
  end

  # Normalize simple values for comparisons
  defp normalize_value(value) when is_boolean(value), do: if(value, do: 1, else: 0)

  defp normalize_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {num, _} -> num
      :error -> 0
    end
  end

  defp normalize_value(value) when is_number(value), do: value
  defp normalize_value(_), do: 0

  # Normalize options into keyword list
  defp normalize_opts(opts) do
    cond do
      is_list(opts) -> opts
      is_boolean(opts) -> [debug: opts]
      true -> [debug: false]
    end
  end
end
