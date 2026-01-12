defmodule PreProcessing.Tableaux do
  alias PreProcessing.UniverseState

  # Convert condition id into term
  def to_cond(id) do
    {:cond, id}
  end

  # Create a set term from name and map
  def to_set(name, set) when is_map(set) do
    {:set, String.to_atom(name), set}
  end

  # Negate a concrete set using the universe
  def neg({:set, name, set}) when is_map(set) do
    universe = UniverseState.get_set("c_all")
    complement = MapSet.difference(universe || MapSet.new(), set)
    neg_name = String.to_atom("¬#{name}")
    {:set, neg_name, complement}
  end

  # Negate a condition id
  def neg({:cond, id}) do
    {:neg, {:cond, id}}
  end

  # Double negation elimination
  def neg({:neg, x}), do: x

  def neg(x), do: {:neg, x}

  # Conjunction with basic distributive handling
  def conj(x, y) do
    result =
      case {x, y} do
        {{:bracket, inner}, other} ->
          {:conj, {:bracket, apply_distributive(inner)}, other}

        {other, {:bracket, inner}} ->
          {:conj, other, {:bracket, apply_distributive(inner)}}

        {{:set, name1, set1}, {:set, name2, set2}} when is_map(set1) and is_map(set2) ->
          new_name = combine_names(:conj, name1, name2)
          {:set, new_name, MapSet.intersection(set1, set2)}

        _ ->
          {:conj, x, y}
      end

    apply_distributive(result)
  end

  # Disjunction with basic distributive handling
  def disj(x, y) do
    result =
      case {x, y} do
        {{:bracket, inner}, other} ->
          {:disj, {:bracket, apply_distributive(inner)}, other}

        {other, {:bracket, inner}} ->
          {:disj, other, {:bracket, apply_distributive(inner)}}

        {{:set, name1, set1}, {:set, name2, set2}} when is_map(set1) and is_map(set2) ->
          new_name = combine_names(:disj, name1, name2)
          {:set, new_name, MapSet.union(set1, set2)}

        _ ->
          {:disj, x, y}
      end

    apply_distributive(result)
  end

  def impl(x, y) do
    disj(neg(x), y)
  end

  def iff(x, y) do
    conj(impl(x, y), impl(y, x))
  end

  def bot(x) do
    {:bot, x}
  end

  def top(x) do
    {:top, x}
  end

  def for_all(var, domain, formula) do
    {:for_all, var, domain, formula}
  end

  def exists(var, domain, formula) do
    {:exists, var, domain, formula}
  end

  def bracket(x) do
    {:bracket, x}
  end

  # Distribute conjunction over disjunction
  def distribute({:conj, x, {:disj, y, z}}) do
    {:disj, {:conj, x, y}, {:conj, x, z}}
  end

  def distribute({:conj, {:disj, x, y}, z}) do
    {:disj, {:conj, x, z}, {:conj, y, z}}
  end

  #### Functions

  # Comparison functions
  def lt(x, y), do: {:fun, :lt, [x, y]}
  def gt(x, y), do: {:fun, :gt, [x, y]}
  def leq(x, y), do: {:fun, :leq, [x, y]}
  def geq(x, y), do: {:fun, :geq, [x, y]}
  def eq(x, y), do: {:fun, :eq, [x, y]}
  def neq(x, y), do: {:fun, :neq, [x, y]}

  def apply_fun(name, args), do: {:fun, name, args}

  # Element membership checks and propagation through logical constructors
  def element(x, set) do
    case {x, set} do
      {{:cond, id}, {:set, _name, set_content}} when is_map(set_content) ->
        if MapSet.member?(set_content, id) do
          {:set, :empty, MapSet.new([id])}
        else
          {:set, :empty, MapSet.new()}
        end

      {x, {:conj, set1, set2}} ->
        conj(element(x, set1), element(x, set2))

      {x, {:disj, set1, set2}} ->
        disj(element(x, set1), element(x, set2))

      {x, {:neg, set}} ->
        neg(element(x, set))

      _ ->
        {:set, :empty, MapSet.new()}
    end
  end

  # Represent subset as a function term
  def subset(set1, set2) do
    {:fun, :subset, [set1, set2]}
  end

  # Evaluate simple set expressions when possible
  defp evaluate_set(expr) do
    case expr do
      {:set, _name, set} when is_map(set) ->
        {:ok, set}

      {:neg, {:set, _name, set}} when is_map(set) ->
        universe = UniverseState.get_set("c_all")
        {:ok, MapSet.difference(universe || MapSet.new(), set)}

      _ ->
        :error
    end
  end

  # Extract single element id from a term
  defp elem_from_term({:cond, id}), do: id
  defp elem_from_term(_), do: nil

  # Build a subset check with a condition id
  def cond_in_set(id, set) do
    {:fun, :subset, [{:cond, id}, set]}
  end

  # Extract elements from a term into a list
  defp extract_elements(term) do
    case term do
      {:set, _name, set} when is_map(set) -> MapSet.to_list(set)
      {:cond, id} -> [id]
      _ -> []
    end
  end

  #### Helper functions

  # Combine names for sets with readable operators
  defp combine_names(op, name1, name2) do
    n1 = if is_atom(name1), do: Atom.to_string(name1), else: to_string(name1)
    n2 = if is_atom(name2), do: Atom.to_string(name2), else: to_string(name2)

    n1 = String.trim(n1, "()")
    n2 = String.trim(n2, "()")

    n1_needs_brackets = String.contains?(n1, ["∨", "∧"])
    n2_needs_brackets = String.contains?(n2, ["∨", "∧"])

    n1 = if n1_needs_brackets, do: "(#{n1})", else: n1
    n2 = if n2_needs_brackets, do: "(#{n2})", else: n2

    operator =
      case op do
        :conj -> "∧"
        :disj -> "∨"
        _ -> "•"
      end

    result = "#{n1} #{operator} #{n2}"
    String.to_atom(result)
  end

  # Substitute a variable in a formula (simple cases)
  def substitute(formula, var, value) do
    case formula do
      {:cond, a} -> {:cond, a}
      {:neg, f} -> {:neg, substitute(f, var, value)}
      {:conj, f1, f2} -> {:conj, substitute(f1, var, value), substitute(f2, var, value)}
      {:disj, f1, f2} -> {:disj, substitute(f1, var, value), substitute(f2, var, value)}
      other -> other
    end
  end

  # Apply distributive transformations and simplify set expressions
  def apply_distributive(formula) do
    case formula do
      {:disj, {:set, name1, set1}, {:set, name2, set2}} when is_map(set1) and is_map(set2) ->
        {:set, combine_names(:disj, name1, name2), MapSet.union(set1, set2)}

      {:conj, {:set, name1, set1}, {:set, name2, set2}} when is_map(set1) and is_map(set2) ->
        {:set, combine_names(:conj, name1, name2), MapSet.intersection(set1, set2)}

      {:conj, x, y} = term ->
        case {apply_distributive(x), apply_distributive(y)} do
          {{:set, name1, set1}, {:set, name2, set2}} when is_map(set1) and is_map(set2) ->
            universe1 = UniverseState.get_set(Atom.to_string(name1))
            universe2 = UniverseState.get_set(Atom.to_string(name2))
            intersection = MapSet.intersection(set1, set2)

            valid_intersection =
              if universe1 && universe2 do
                MapSet.intersection(intersection, MapSet.intersection(universe1, universe2))
              else
                intersection
              end

            {:set, name1, valid_intersection}

          {{:disj, x1, x2}, {:disj, y1, y2}} ->
            {:disj,
             {:disj, apply_distributive({:conj, x1, y1}), apply_distributive({:conj, x1, y2})},
             {:disj, apply_distributive({:conj, x2, y1}), apply_distributive({:conj, x2, y2})}}

          {{:disj, x1, x2}, y_dist} ->
            {:disj, apply_distributive({:conj, x1, y_dist}),
             apply_distributive({:conj, x2, y_dist})}

          {x_dist, {:disj, y1, y2}} ->
            {:disj, apply_distributive({:conj, x_dist, y1}),
             apply_distributive({:conj, x_dist, y2})}

          {x_dist, y_dist} ->
            {:conj, x_dist, y_dist}
        end

      {:disj, x, y} ->
        {:disj, apply_distributive(x), apply_distributive(y)}

      {:neg, x} ->
        {:neg, apply_distributive(x)}

      {:bracket, x} ->
        apply_distributive(x)

      {:fun, :subset, [{:cond, id}, set]} ->
        {:fun, :subset, [{:cond, id}, apply_distributive(set)]}

      other ->
        other
    end
  end

  # Convert terms to readable headers
  def to_hd(term) do
    case term do
      {:set, name, _set} when is_atom(name) ->
        "#{name}"

      {:set, {:neg, name}, _set} ->
        "¬#{to_hd(name)}"

      {:set, name, _set} when is_binary(name) ->
        name

      {:set, {:conj, n1, n2}, _set} ->
        combine_names(:conj, n1, n2)

      {:set, {:disj, n1, n2}, _set} ->
        combine_names(:disj, n1, n2)

      {:cond, id} ->
        "#{id}"

      {:neg, x} ->
        "¬#{to_hd(x)}"

      {:conj, x, y} ->
        combine_names(:conj, x, y)

      {:disj, x, y} ->
        combine_names(:disj, x, y)

      {:bracket, x} ->
        "(#{to_hd(x)})"

      {:compare, op, x, y} ->
        symbol =
          case op do
            :lt -> "<"
            :gt -> ">"
            :leq -> "≤"
            :geq -> "≥"
            :eq -> "="
            :neq -> "≠"
          end

        "#{to_hd(x)} #{symbol} #{to_hd(y)}"

      {:fun, name, args} when is_list(args) ->
        args_str = Enum.map_join(args, ", ", &to_hd/1)
        "#{name}(#{args_str})"

      {:fun, op, [x, y]} when op in [:lt, :gt, :leq, :geq, :eq, :neq] ->
        symbol =
          case op do
            :lt -> "<"
            :gt -> ">"
            :leq -> "≤"
            :geq -> "≥"
            :eq -> "="
            :neq -> "≠"
          end

        "#{to_hd(x)} #{symbol} #{to_hd(y)}"

      {:fun, :subset, [x, y]} ->
        "#{to_hd(x)} ⊆ #{to_hd(y)}"

      x when is_atom(x) ->
        "#{x}"

      x when is_binary(x) ->
        x

      _ ->
        "#{inspect(term)}"
    end
  end

  #### Macros for ease of use

  defmacro ~~~x do
    quote do
      {:neg, unquote(x)}
    end
  end

  defmacro left &&& right do
    quote do
      conj(unquote(left), unquote(right))
    end
  end

  defmacro left ||| right do
    quote do
      disj(unquote(left), unquote(right))
    end
  end

  defmacro left ~> right do
    quote do
      impl(unquote(left), unquote(right))
    end
  end

  defmacro left <~> right do
    quote do
      iff(unquote(left), unquote(right))
    end
  end

  # Macros for quantified formulas
  defmacro all(var, domain, do: body) do
    quote do
      for_all(unquote(var), unquote(domain), unquote(body))
    end
  end

  defmacro exist(var, domain, do: body) do
    quote do
      exists(unquote(var), unquote(domain), unquote(body))
    end
  end
end
